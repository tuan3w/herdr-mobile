import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/services/web_bridge.dart';

import 'support/fake_fs.dart';
import 'support/custom_tab.dart';
import 'support/raw_http.dart';

const _root = '/home/dev/site';

class _Site {
  _Site(this.fs, this.host, this.info);

  final FakeFs fs;
  final WebBridgeHost host;
  final WebBridgeInfo info;

  /// The cookie the entry URL hands out, as the browser would keep it.
  Future<String> signIn() async {
    final entry = await rawRequest(
      info.port,
      target: '/__herdr/open?t=${info.token}&to=${Uri.encodeQueryComponent('/index.html')}',
    );
    return cookieFrom(entry);
  }

  Future<RawReply> get(String target, {Map<String, String> headers = const {}, String? host}) async =>
      rawRequest(info.port, target: target, host: host, headers: {'Cookie': await signIn(), ...headers});
}

Future<_Site> _open({FakeFs? fs, WebRead? read, Duration idle = const Duration(minutes: 10)}) async {
  final fake = fs ?? FakeFs();
  fake.addFile('$_root/index.html', '<h1>home</h1>');
  fake.addFile('$_root/style.css', 'body{}');
  fake.addFile('$_root/sub/index.html', '<h1>sub</h1>');
  fake.addFile('$_root/data/My Chart.json', '{"a":1}');
  fake.addFile('/home/dev/secret.txt', 'confidential-bytes');
  final host = WebBridgeHost(
    stat: fake.stat,
    read: read ?? fake.read,
    dial: (h, p) => throw StateError('a static site never dials'),
    idle: idle,
  );
  final info = await host.open(const StaticSite(_root, machineName: 'build-box'));
  addTearDown(host.close);
  return _Site(fake, host, info);
}

void main() {
  group('who may ask', () {
    test('a request without the cookie is refused and never reaches the machine', () async {
      final site = await _open();
      final r = await rawRequest(site.info.port, target: '/index.html');
      expect(r.status, 403);
      expect(site.fs.calls, isEmpty);
    });

    test('the entry URL sets the cookie and sends the browser on, to a path of this listener only', () async {
      final site = await _open();
      final home = 'http://localhost:${site.info.port}';
      final ok = await rawRequest(site.info.port, target: '/__herdr/open?t=${site.info.token}&to=%2Fsub%2F');
      expect(ok.status, 200);
      expect(sendsTo(ok), '$home/sub/');
      expect(ok.headers['set-cookie'], contains('herdr_${site.info.port}=${site.info.token}'));
      expect(ok.headers['set-cookie'], allOf(contains('HttpOnly'), contains('SameSite=Strict')));
      // A dark phone does not flash a white page on the way.
      expect(ok.text, contains('<meta name="color-scheme" content="light dark">'));

      // Another site is never a destination, however it is spelled: a browser
      // drops tabs and newlines from a URL, so `/<tab>/evil` reads as `//evil`.
      for (final to in [
        '%2F%2Fevil.example',
        '%2F%5Cevil.example',
        'https%3A%2F%2Fevil.example',
        '',
        '%2F%09%2Fevil.example',
        '%2F%0A%2Fevil.example',
        '%2F%0D%2Fevil.example',
        '%2F%20%2Fevil.example',
        '%2F%7F%2Fevil.example',
        '%2F%C3%A9',
      ]) {
        final r = await rawRequest(site.info.port, target: '/__herdr/open?t=${site.info.token}&to=$to');
        expect(r.status, 200, reason: to);
        expect(sendsTo(r), '$home/', reason: to);
      }

      final wrong = await rawRequest(site.info.port, target: '/__herdr/open?t=${'0' * 32}&to=%2F');
      expect(wrong.status, 403);
      expect(wrong.headers.containsKey('set-cookie'), isFalse);
      expect(site.fs.calls, isEmpty);
    });

    test('opened in a Custom Tab, the entry URL ends on the page, not the listener\'s refusal', () async {
      final site = await _open();
      final visit = await openInCustomTab(
        Uri.parse('http://localhost:${site.info.port}/__herdr/open?t=${site.info.token}&to=%2Findex.html'),
      );
      expect(visit.page.status, 200, reason: visit.page.text);
      expect(visit.page.text, '<h1>home</h1>');
    });

    test('tapping Continue on the entry page ends on the page too', () async {
      final site = await _open();
      final visit = await openInCustomTab(
        Uri.parse('http://localhost:${site.info.port}/__herdr/open?t=${site.info.token}&to=%2Findex.html'),
        clickContinue: true,
      );
      expect(visit.page.status, 200, reason: visit.page.text);
      expect(visit.page.text, '<h1>home</h1>');
    });

    test('a second visit, the cookie already set, opens the page straight from the entry URL', () async {
      final site = await _open();
      final entry = Uri.parse('http://localhost:${site.info.port}/__herdr/open?t=${site.info.token}&to=%2Findex.html');
      final CookieJar jar = {};
      await openInCustomTab(entry, jar: jar);
      expect(jar, isNotEmpty);
      final again = await openInCustomTab(entry, jar: jar);
      expect(again.page.status, 200, reason: again.page.text);
      expect(again.page.text, '<h1>home</h1>');
      expect(again.steps, hasLength(2), reason: '${again.steps}');
    });

    test('a foreign Host header is refused even with the cookie (DNS rebinding)', () async {
      final site = await _open();
      final cookie = await site.signIn();
      final r = await rawRequest(
        site.info.port,
        target: '/index.html',
        host: 'evil.example:${site.info.port}',
        headers: {'Cookie': cookie},
      );
      expect(r.status, 403);
      expect(site.fs.calls, isEmpty);
      final ip = await rawRequest(
        site.info.port,
        target: '/index.html',
        host: '127.0.0.1:${site.info.port}',
        headers: {'Cookie': cookie},
      );
      expect(ip.status, 200);
    });

    test('only GET and HEAD', () async {
      final site = await _open();
      expect((await site.get('/index.html', headers: {})).status, 200);
      final cookie = await site.signIn();
      final post = await rawRequest(site.info.port, method: 'POST', target: '/index.html', headers: {'Cookie': cookie, 'Content-Length': '0'});
      expect(post.status, 405);
    });
  });

  group('what may be asked of the machine', () {
    test('no spelling of a path leaves the folder, and the machine is never asked about one that does', () async {
      final site = await _open();
      final cookie = await site.signIn();
      site.fs.calls.clear();
      final attacks = [
        '/..%2f..%2fsecret.txt',
        '/%2e%2e/%2e%2e/secret.txt',
        '/../../secret.txt',
        '/a%00b',
        r'/a\..\..\x',
        '/sub/..%2f..%2f..%2fsecret.txt',
        '/%252e%252e/secret.txt',
        '//secret.txt',
      ];
      for (final a in attacks) {
        final r = await rawRequest(site.info.port, target: a, headers: {'Cookie': cookie});
        expect(r.status, anyOf(400, 403, 404), reason: a);
        expect(r.text, isNot(contains('confidential-bytes')), reason: a);
      }
      for (final call in site.fs.calls) {
        expect(call, contains(' $_root'), reason: 'asked about $call');
      }
    });

    test('a percent-encoded name is decoded once and served', () async {
      final site = await _open();
      final r = await site.get('/data/My%20Chart.json');
      expect(r.status, 200);
      expect(r.text, '{"a":1}');
      expect(r.headers['content-type'], 'application/json; charset=utf-8');
    });
  });

  group('what a page in a home folder must not read', () {
    test('no name with a leading dot is served, however it is spelled, and the machine is not asked', () async {
      final site = await _open();
      site.fs
        ..addFile('$_root/.env', 'API_KEY=hunter2')
        ..addFile('$_root/.ssh/id_ed25519', 'PRIVATE-KEY')
        ..addFile('$_root/sub/.git/config', 'url = git@example.com:x.git')
        ..addFile('$_root/a/.hidden/x.html', 'hidden');
      final cookie = await site.signIn();
      site.fs.calls.clear();
      for (final target in [
        '/.env',
        '/%2eenv',
        '/%2Eenv',
        '/.ssh/id_ed25519',
        '/sub/.git/config',
        '/sub/.git/',
        '/%2e%2e/.env',
        '/sub/%2e%2e/.git/config',
        '/..%2f.env',
        '/a/.hidden/x.html',
        '/a/%2ehidden/x.html',
        '/.env?x=1',
      ]) {
        final r = await rawRequest(site.info.port, target: target, headers: {'Cookie': cookie, 'Accept': 'text/html'});
        expect(r.status, 404, reason: target);
        expect(r.text, allOf(isNot(contains('hunter2')), isNot(contains('PRIVATE-KEY'))), reason: target);
      }
      expect(site.fs.calls, isEmpty, reason: 'refused before asking the machine');

      // `/%2e%2e` alone never reaches the handler as a dot segment: Uri collapses
      // it to the folder itself, which is the site's own page, not what is above.
      site.fs.calls.clear();
      final up = await site.get('/%2e%2e');
      expect(up.text, '<h1>home</h1>');
      expect(site.fs.calls.every((c) => c.contains(' $_root')), isTrue);
      // A normal file next to them is still served.
      expect((await site.get('/style.css')).status, 200);
    });

    test('a site whose own folder starts with a dot still opens: only what a request names is checked', () async {
      final fs = FakeFs()..addFile('/home/dev/.site/index.html', '<h1>dotted</h1>');
      final host = WebBridgeHost(stat: fs.stat, read: fs.read, dial: (h, p) => throw StateError('no'));
      addTearDown(host.close);
      final info = await host.open(const StaticSite('/home/dev/.site', machineName: 'build-box'));
      final cookie = cookieFrom(await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=%2F'));
      final r = await rawRequest(info.port, target: '/index.html', headers: {'Cookie': cookie});
      expect(r.text, '<h1>dotted</h1>');
    });
  });

  group('a request that is not valid text', () {
    test('an invalid escape is a refusal or a 404, never a failure, and the listener keeps serving', () async {
      final site = await _open();
      final cookie = await site.signIn();

      // No token: 403, whatever the escape in the token is.
      for (final t in ['%ff', '%', '%zz', '%c0%af']) {
        final r = await rawRequest(site.info.port, target: '/__herdr/open?t=$t&to=%2F');
        expect(r.status, 403, reason: t);
        expect(r.headers.containsKey('set-cookie'), isFalse, reason: t);
      }
      // A good token with a destination that cannot be read goes to the root.
      for (final to in ['%ff', '%', '%zz']) {
        final r = await rawRequest(site.info.port, target: '/__herdr/open?t=${site.info.token}&to=$to');
        expect(r.status, 200, reason: to);
        expect(sendsTo(r), 'http://localhost:${site.info.port}/', reason: to);
      }
      // In the path: no cookie is a 403, with the cookie a 404.
      expect((await rawRequest(site.info.port, target: '/%ff')).status, 403);
      final path = await rawRequest(site.info.port, target: '/%ff/x.html', headers: {'Cookie': cookie});
      expect(path.status, 404);
      expect(path.timedOut, isFalse);

      expect((await site.get('/index.html')).text, '<h1>home</h1>');
    });
  });

  group('serving files', () {
    test('a folder serves its index.html, and without the trailing slash it is sent there', () async {
      final site = await _open();
      final r = await site.get('/sub/');
      expect(r.text, '<h1>sub</h1>');
      final bare = await site.get('/sub?x=1');
      expect(bare.status, 301);
      expect(bare.headers['location'], '/sub/?x=1');
    });

    test('Range answers 206 with the bytes asked for, 416 past the end', () async {
      final site = await _open();
      final body = Uint8List.fromList(List.generate(1000, (i) => i % 251));
      site.fs.addFile('$_root/a.wav', body);
      final mid = await site.get('/a.wav', headers: {'Range': 'bytes=100-199'});
      expect(mid.status, 206);
      expect(mid.headers['content-range'], 'bytes 100-199/1000');
      expect(mid.body, body.sublist(100, 200));
      final tail = await site.get('/a.wav', headers: {'Range': 'bytes=-10'});
      expect(tail.body, body.sublist(990));
      final open = await site.get('/a.wav', headers: {'Range': 'bytes=995-'});
      expect(open.body, body.sublist(995));
      final past = await site.get('/a.wav', headers: {'Range': 'bytes=2000-'});
      expect(past.status, 416);
      expect(past.headers['content-range'], 'bytes */1000');
    });

    test('a Range with an absurd number is not a crash: it is ignored', () async {
      final site = await _open();
      final r = await site.get('/style.css', headers: {'Range': 'bytes=99999999999999999999-'});
      expect(r.status, 200);
      expect(r.text, 'body{}');
    });

    test('an open-ended Range gets one piece and a 206, so a player that left does not cost the whole file', () async {
      final site = await _open();
      final big = Uint8List.fromList(List.generate(webBridgeOpenRange * 2 + 4321, (i) => (i * 13) % 256));
      site.fs.addFile('$_root/movie.mp4', big);
      final first = await site.get('/movie.mp4', headers: {'Range': 'bytes=0-'});
      expect(first.status, 206);
      expect(first.headers['content-range'], 'bytes 0-${webBridgeOpenRange - 1}/${big.length}');
      expect(first.body, big.sublist(0, webBridgeOpenRange));
      final next = await site.get('/movie.mp4', headers: {'Range': 'bytes=$webBridgeOpenRange-'});
      expect(next.body, big.sublist(webBridgeOpenRange, webBridgeOpenRange * 2));
      final last = await site.get('/movie.mp4', headers: {'Range': 'bytes=${webBridgeOpenRange * 2}-'});
      expect(last.headers['content-range'], 'bytes ${webBridgeOpenRange * 2}-${big.length - 1}/${big.length}');
      expect(last.body, big.sublist(webBridgeOpenRange * 2));
      // A closed range is the player's own choice and is honoured.
      final closed = await site.get('/movie.mp4', headers: {'Range': 'bytes=0-${webBridgeOpenRange + 99}'});
      expect(closed.body.length, webBridgeOpenRange + 100);
      // A plain request stays whole.
      final plain = await site.get('/movie.mp4');
      expect(plain.status, 200);
      expect(plain.body, big);
    });

    test('a file the browser already has is answered 304 without reading it', () async {
      final site = await _open();
      final first = await site.get('/style.css');
      final stamp = first.headers['last-modified']!;
      site.fs.calls.clear();
      final again = await site.get('/style.css', headers: {'If-Modified-Since': stamp});
      expect(again.status, 304);
      expect(site.fs.calls.where((c) => c.startsWith('read')), isEmpty);
      final changed = await site.get('/style.css', headers: {'If-Modified-Since': _longAgo});
      expect(changed.status, 200);
    });

    test('a file bigger than one piece arrives whole, read in pieces', () async {
      final site = await _open();
      final big = Uint8List.fromList(List.generate(webBridgePiece * 2 + 777, (i) => (i * 7) % 256));
      site.fs.addFile('$_root/big.bin', big);
      site.fs.calls.clear();
      final r = await site.get('/big.bin');
      expect(r.body, big);
      final reads = site.fs.calls.where((c) => c.startsWith('read')).toList();
      expect(reads.length, 3);
      expect(site.fs.maxInFlight, lessThanOrEqualTo(webBridgeReadWindow));
    });

    test('a file that shrinks while it is served ends the connection instead of hanging', () async {
      final fs = FakeFs();
      final big = Uint8List(webBridgePiece * 3);
      var reads = 0;
      final site = await _open(
        fs: fs,
        read: (path, offset, length) async {
          if (path.endsWith('big.bin') && ++reads == 2) return Uint8List(10);
          return fs.read(path, offset, length);
        },
      );
      fs.addFile('$_root/big.bin', big);
      final r = await site.get('/big.bin');
      expect(r.timedOut, isFalse, reason: 'the connection must be closed, not left waiting');
      expect(r.closedEarly, isTrue);
      expect(r.body.length, lessThan(big.length));
    });
  });

  group('a single-page app', () {
    test('its own routes get index.html, but only for a page navigation', () async {
      final site = await _open();
      final nav = await site.get('/about', headers: {'Accept': 'text/html,application/xhtml+xml'});
      expect(nav.status, 200);
      expect(nav.text, '<h1>home</h1>');
      expect((await site.get('/about', headers: {'Accept': '*/*'})).status, 404);
      expect((await site.get('/missing.js', headers: {'Accept': 'text/html'})).status, 404);
    });

    test('with no index.html a missing route is a 404 that says where it looked', () async {
      final fs = FakeFs()..addFile('$_root/other.html', 'x');
      final host = WebBridgeHost(stat: fs.stat, read: fs.read, dial: (h, p) => throw StateError('no'));
      addTearDown(host.close);
      final info = await host.open(const StaticSite(_root, machineName: '<b>build</b>'));
      final cookie = cookieFrom(await rawRequest(info.port, target: '/__herdr/open?t=${info.token}&to=%2F'));
      final r = await rawRequest(info.port, target: '/about?x=<i>', headers: {'Cookie': cookie, 'Accept': 'text/html'});
      expect(r.status, 404);
      expect(r.text, allOf(contains('/about'), contains(_root), contains('&lt;b&gt;build&lt;/b&gt;')));
      expect(r.text, isNot(contains('<b>build</b>')));
    });
  });

  group('when the machine fails', () {
    test('permission is a 403 with the reason, a dropped connection a 502 that names the machine', () async {
      final fs = FakeFs();
      final site = await _open(fs: fs);
      fs.deny.add('$_root/style.css');
      final denied = await site.get('/style.css');
      expect(denied.status, 403);
      expect(denied.text, contains('Permission denied'));
      fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'Connection lost');
      final down = await site.get('/index.html');
      expect(down.status, 502);
      expect(down.text, contains("Couldn't reach build-box"));
    });
  });

  group('lifetime', () {
    test('the same site is one listener with one port and token', () async {
      final site = await _open();
      final again = await site.host.open(const StaticSite(_root, machineName: 'build-box'));
      expect(again, site.info);
      final other = await site.host.open(const StaticSite('$_root/sub', machineName: 'build-box'));
      expect(other.port, isNot(site.info.port));
      expect(other.token, isNot(site.info.token));
    });

    test('an idle listener stops, and the next open brings back the same port and token', () async {
      final site = await _open(idle: const Duration(milliseconds: 150));
      final cookie = await site.signIn();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      await expectLater(rawRequest(site.info.port, headers: {'Cookie': cookie}), throwsA(anything));
      final back = await site.host.open(const StaticSite(_root, machineName: 'build-box'));
      expect(back, site.info);
      // The cookie the tab already holds still opens it.
      final r = await rawRequest(back.port, target: '/index.html', headers: {'Cookie': cookie});
      expect(r.text, '<h1>home</h1>');
    });

    test('a listener that comes back on another port starts over with a new token', () async {
      final site = await _open(idle: const Duration(milliseconds: 150));
      final cookie = await site.signIn();
      await Future<void>.delayed(const Duration(milliseconds: 450));
      expect(site.host.livePorts, isEmpty);
      // Something else takes the port while the listener sleeps.
      final thief = await ServerSocket.bind(InternetAddress.loopbackIPv4, site.info.port);
      addTearDown(thief.close);
      final back = await site.host.open(const StaticSite(_root, machineName: 'build-box'));
      expect(back.port, isNot(site.info.port));
      expect(back.token, isNot(site.info.token));
      // The cookie of the old tab does not open the new listener.
      final r = await rawRequest(back.port, target: '/index.html', headers: {'Cookie': cookie});
      expect(r.status, 403);
    });

    test('a listener in use does not stop under a request in flight', () async {
      const idle = Duration(milliseconds: 400);
      final reading = Completer<void>();
      final release = Completer<void>();
      final fs = FakeFs();
      final site = await _open(
        fs: fs,
        idle: idle,
        read: (path, offset, length) async {
          if (path.endsWith('index.html')) {
            if (!reading.isCompleted) reading.complete();
            await release.future; // the machine answers when the test says, not after a delay
          }
          return fs.read(path, offset, length);
        },
      );
      // The cookie is the token itself (what the entry URL sets): no round trip
      // before the request, so nothing but the open can have armed the idle timer.
      final cookie = 'herdr_${site.info.port}=${site.info.token}';
      final asked = rawRequest(site.info.port, target: '/index.html', headers: {'Cookie': cookie});
      await reading.future.timeout(const Duration(seconds: 10));
      // Several idle times pass with the request in flight (a longer wait only makes the check stricter).
      await Future<void>.delayed(idle * 3);
      expect(site.host.livePorts, {site.info.port}, reason: 'the listener stopped under a request in flight');
      release.complete();
      final r = await asked;
      expect(r.status, 200);
      expect(utf8.decode(r.body), '<h1>home</h1>');
    });
  });

  group('a request that repeats a header', () {
    // A header name can only be in a Map once, so a second line is written
    // into the value, as it goes out on the wire.
    test('is answered like any other request, not with a 502', () async {
      final site = await _open();
      final cookie = await site.signIn();

      // Cookie lines are one list: the cookie on the second line opens it, none at all is a 403.
      final ok = await rawRequest(site.info.port, target: '/style.css', headers: {'Cookie': 'theme=dark\r\nCookie: $cookie'});
      expect(ok.status, 200);
      expect(ok.text, 'body{}');
      final none = await rawRequest(site.info.port, target: '/style.css', headers: {'Cookie': 'theme=dark\r\nCookie: a=b'});
      expect(none.status, 403);

      // Two ranges say nothing clear: the whole file is sent.
      final ranges = await site.get('/style.css', headers: {'Range': 'bytes=0-1\r\nRange: bytes=2-3'});
      expect(ranges.status, 200);
      expect(ranges.text, 'body{}');
    });
  });
}

const _longAgo = 'Thu, 01 Jan 2004 00:00:00 GMT';
