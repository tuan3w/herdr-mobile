import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/repositories/web_preview.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

RemoteStat _file(String path) => RemoteStat(path: path, kind: RemoteEntryKind.file, size: 10);

void main() {
  late FakeTransport transport;
  late WebPreview web;

  setUp(() {
    transport = FakeTransport()..fs = FakeFs();
    web = WebPreview(transport, machineName: 'build-box');
  });

  group('which links can be opened on the phone', () {
    test('plain http to the machine itself, nothing else', () {
      for (final url in [
        'http://localhost:3000',
        'http://127.0.0.1:8080/a?b=1',
        'http://0.0.0.0:5000',
        'http://[::1]:5173/',
        'http://localhost',
        'http://localhost:65535',
      ]) {
        expect(WebPreview.canPreview(url), isTrue, reason: url);
      }
      for (final url in [
        'https://localhost',
        'https://127.0.0.1:8443/',
        'http://example.com',
        'http://192.168.1.20:3000',
        'ftp://localhost/x',
        'http://localhost:0',
        'http://localhost:65536',
        'http://localhost:70000',
        'localhost:3000',
        '',
      ]) {
        expect(WebPreview.canPreview(url), isFalse, reason: url);
      }
    });

    test(
      'a name the machine would resolve elsewhere isn’t the machine: the row would say one thing and dial another',
      () async {
        // `*.local` reaches other devices on the machine's network; another 127.x
        // or `*.localhost` is not what `localhost:...` on the row reads as.
        for (final url in [
          'http://devbox.local:4000/ui',
          'http://svc.default.svc.cluster.local:8080',
          'http://127.0.0.5:3000',
          'http://127.1.2.3:3000',
          'http://evil.localhost:3000',
        ]) {
          expect(WebPreview.canPreview(url), isFalse, reason: url);
          await expectLater(web.forwardUrl(Uri.parse(url)), throwsA(isA<WebPreviewException>()), reason: url);
        }
        expect(transport.webBridges, isEmpty);
      },
    );

    test('a link that can’t be opened says so instead of asking the machine', () async {
      await expectLater(web.forwardUrl(Uri.parse('https://localhost:3000')), throwsA(isA<WebPreviewException>()));
      expect(transport.webBridges, isEmpty);
    });

    test('a port that doesn’t exist says so, not that the address is wrong', () async {
      for (final url in ['http://localhost:0', 'http://localhost:65536']) {
        await expectLater(
          web.forwardUrl(Uri.parse(url)),
          throwsA(isA<WebPreviewException>().having((e) => e.message, 'message', contains('port number isn’t valid'))),
          reason: url,
        );
      }
      await expectLater(
        web.forwardUrl(Uri.parse('http://example.com:3000')),
        throwsA(isA<WebPreviewException>().having((e) => e.message, 'message', isNot(contains('port number')))),
      );
      expect(transport.webBridges, isEmpty);
    });
  });

  group('a link on the machine', () {
    test('the entry URL is on localhost, carries the token, and keeps path, query and fragment', () async {
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/app/x%20y?tab=a%26b&n=1#top'));
      expect(url.scheme, 'http');
      expect(url.host, 'localhost');
      expect(url.port, transport.webInfo.entryPort);
      expect(url.path, '/__herdr/open');
      expect(url.queryParameters['t'], transport.webInfo.token);
      expect(url.queryParameters['to'], '/app/x%20y?tab=a%26b&n=1#top');
      expect(url.hasFragment, isFalse, reason: 'the page that sends the browser on would drop it');
      expect(transport.webBridges.single, isA<PortForward>().having((s) => s.port, 'port', 3000));
    });

    test('the entry URL goes to the entry listener, not to the port the dev server is reached on', () async {
      transport.webInfo = const WebBridgeInfo(port: 3000, token: '0123456789abcdef0123456789abcdef', entryPort: 51999);
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/app'));
      expect(
        url.port,
        51999,
        reason: 'a connection the browser keeps to port 3000 is the dev server’s, the token must not ride on it',
      );
      expect(url.queryParameters['to'], '/app');
    });

    test('an encoded fragment isn’t encoded twice', () async {
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/#a%20b'));
      expect(url.queryParameters['to'], '/#a%20b');
    });

    test('no port means 80, no path means the root', () async {
      final url = await web.forwardUrl(Uri.parse('http://localhost'));
      expect((transport.webBridges.single as PortForward).port, 80);
      expect(url.queryParameters['to'], '/');
      expect(url.hasFragment, isFalse);
    });

    test('every spelling of the machine itself is one listener', () async {
      for (final host in ['0.0.0.0', '[::]', '127.0.0.1', '[::1]', 'localhost', 'LOCALHOST']) {
        await web.forwardUrl(Uri.parse('http://$host:8080'));
      }
      expect(transport.webBridges.map((s) => s.key).toSet(), {'f|localhost|8080'});
    });

    test('a listener that couldn’t take the target port number tells the person once', () async {
      final notes = <String>[];
      transport.webInfo = const WebBridgeInfo(port: 51111, token: '0123456789abcdef0123456789abcdef');
      final url = await web.forwardUrl(Uri.parse('http://localhost:3000/x'), onNote: notes.add);
      expect(url.port, 51111, reason: 'the page still opens, on the port it got');
      expect(notes, ['Opened on port 51111: a page that expects localhost:3000 may not work.']);

      // The same number: nothing to say.
      notes.clear();
      transport.webInfo = const WebBridgeInfo(port: 3000, token: '0123456789abcdef0123456789abcdef');
      await web.forwardUrl(Uri.parse('http://localhost:3000'), onNote: notes.add);
      expect(notes, isEmpty);
    });

    test('machine name reaches the listener for its error pages', () async {
      await web.forwardUrl(Uri.parse('http://localhost:3000'));
      expect(transport.webBridges.single.machineName, 'build-box');
    });

    test('a refusal reads as a sentence about this phone', () async {
      transport.webFailure = const HerdrTransportException('the machine doesn’t allow port forwarding', fatal: true);
      await expectLater(
        web.forwardUrl(Uri.parse('http://localhost:3000')),
        throwsA(
          isA<WebPreviewException>().having(
            (e) => e.message,
            'message',
            "Couldn’t open on this phone: the machine doesn’t allow port forwarding.",
          ),
        ),
      );
      transport.webFailure = const HerdrTransportException('Can’t open a local port: SocketException.');
      await expectLater(
        web.forwardUrl(Uri.parse('http://localhost:3000')),
        throwsA(
          isA<WebPreviewException>().having(
            (e) => e.message,
            'message',
            "Couldn’t open on this phone: can’t open a local port: SocketException.",
          ),
        ),
      );
    });
  });

  group('an HTML file', () {
    test('serves the file’s own folder and opens the file in it', () async {
      final url = await web.staticUrl(_file('/home/dev/report/out/index.html'), fragment: 'sec 2');
      final spec = transport.webBridges.single as StaticSite;
      expect(spec.root, '/home/dev/report/out');
      expect(url.queryParameters['to'], '/index.html#sec%202');
      expect(url.host, 'localhost');
    });

    test('a name with spaces and non-ASCII letters survives both encodings', () async {
      final url = await web.staticUrl(_file('/work/My Chartü.html'));
      expect(url.queryParameters['to'], '/My%20Chart%C3%BC.html');
      expect(Uri.decodeComponent(url.queryParameters['to']!), '/My Chartü.html');
    });

    test('a file in the top folder serves the root', () async {
      await web.staticUrl(_file('/index.html'));
      expect((transport.webBridges.single as StaticSite).root, '/');
    });

    test('a machine without files says so, a path that isn’t absolute is refused', () async {
      transport.fs = null;
      await expectLater(
        web.staticUrl(_file('/a/b.html')),
        throwsA(
          isA<WebPreviewException>().having((e) => e.message, 'message', 'Files are not available on this machine.'),
        ),
      );
      transport.fs = FakeFs();
      await expectLater(web.staticUrl(_file('b.html')), throwsA(isA<WebPreviewException>()));
      expect(transport.webBridges, isEmpty);
    });
  });

  group('the pages a machine’s listeners show', () {
    test('a forward’s page reads as the machine has it, on the machine’s own port', () async {
      transport.webInfo = const WebBridgeInfo(port: 51111, token: '0123456789abcdef0123456789abcdef', entryPort: 51999);
      await web.forwardUrl(Uri.parse('http://localhost:3000/'));
      expect(web.ports, {51111, 51999});

      final page = web.machinePage(Uri.parse('http://localhost:51111/page2.html?q=1#b'))!;
      expect(page.address, 'http://localhost:3000/page2.html?q=1#b', reason: 'never the phone’s port or token');
      expect(page.label, 'localhost:3000/page2.html');
      expect(web.machinePage(Uri.parse('http://localhost:51111/'))!.label, 'localhost:3000');
    });

    test('a static site’s page is the file on the machine', () async {
      await web.staticUrl(_file('/home/dev/site/index.html'));
      final page = web.machinePage(Uri.parse('http://localhost:${transport.webInfo.port}/sub/My%20Page.html'))!;
      expect(page.address, '/home/dev/site/sub/My Page.html');
      expect(page.label, 'My Page.html');
    });

    test('an entry URL, another port and another name are no page of the machine', () async {
      await web.staticUrl(_file('/home/dev/site/index.html'));
      final port = transport.webInfo.port;
      expect(web.machinePage(Uri.parse('http://localhost:$port/__herdr/open?t=x&to=/')), isNull);
      expect(web.machinePage(Uri.parse('http://localhost:${port + 1}/')), isNull);
      expect(web.machinePage(Uri.parse('http://example.com:$port/')), isNull);
    });

    test('reopen asks for the listener again and enters at the same page with a fresh cookie', () async {
      transport.webInfo = const WebBridgeInfo(port: 51111, token: '0123456789abcdef0123456789abcdef', entryPort: 51999);
      await web.forwardUrl(Uri.parse('http://localhost:3000/'));
      final entry = await web.reopen(Uri.parse('http://localhost:51111/page2.html?q=1#b'));
      expect(transport.webBridges, hasLength(2));
      expect(transport.webBridges.last.key, 'f|localhost|3000');
      expect((entry.port, entry.path), (51999, '/__herdr/open'));
      expect(entry.queryParameters['to'], '/page2.html?q=1#b');
      await expectLater(web.reopen(Uri.parse('http://localhost:4000/')), throwsA(isA<WebPreviewException>()));
    });

    test('a listener that comes back on another port takes its old port with it', () async {
      transport.webInfo = const WebBridgeInfo(port: 51111, token: '0123456789abcdef0123456789abcdef', entryPort: 51999);
      await web.forwardUrl(Uri.parse('http://localhost:3000/'));
      transport.webInfo = const WebBridgeInfo(port: 52222, token: 'fedcba9876543210fedcba9876543210', entryPort: 53333);
      await web.forwardUrl(Uri.parse('http://localhost:3000/'));
      expect(web.ports, {52222, 53333}, reason: 'another app may hold 51111 now');
      expect(web.machinePage(Uri.parse('http://localhost:51111/')), isNull);
    });

    test('127.0.0.1 is no page of the machine: the listener’s cookie is for localhost', () async {
      transport.webInfo = const WebBridgeInfo(port: 51111, token: '0123456789abcdef0123456789abcdef', entryPort: 51999);
      await web.forwardUrl(Uri.parse('http://localhost:3000/'));
      expect(web.machinePage(Uri.parse('http://127.0.0.1:51111/')), isNull);
    });

    test('a failure keeps its reason alone for a place that says what failed', () {
      expect(
        const WebPreviewException("Couldn’t open on this phone: the machine doesn’t allow port forwarding.").reason,
        'The machine doesn’t allow port forwarding.',
      );
      expect(
        const WebPreviewException('Files are not available on this machine.').reason,
        'Files are not available on this machine.',
      );
    });
  });
}
