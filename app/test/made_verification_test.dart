import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/host_ports.dart';
import 'package:herdr_mobile/data/repositories/made_verification.dart';

import 'support/fake_transport.dart';

// What the machine says about the things a session made, from a scripted host:
// ONE verify call for what the sheet shows, ports followed with a watch that
// sends only changes, and honest silence (unknown) whenever the machine cannot say.

void main() {
  late FakeTransport transport;
  late StreamController<Object?> watch;
  late List<List<Map<String, Object?>>> verified;
  var watching = 0;
  var cancelled = 0;

  /// What `made.verify` answers: files named `gone…` are not there, ports in [up] listen.
  Set<int> up = {};

  MadeVerification model() {
    final v = MadeVerification(HostPorts(transport));
    addTearDown(v.dispose);
    return v;
  }

  setUp(() {
    up = {};
    verified = [];
    watching = 0;
    cancelled = 0;
    watch = StreamController<Object?>();
    transport = FakeTransport()
      ..onHostCall = (service, method, args) async {
        expect('$service.$method', 'made.verify');
        final items = (args['items']! as List).cast<Map<String, Object?>>();
        verified.add(items);
        return {
          'results': [
            for (final item in items)
              if (item['path'] case final String path)
                {'id': item['id'], 'exists': !path.contains('gone')}
              else
                {'id': item['id'], 'listening': up.contains(item['port'])},
          ],
        };
      }
      ..onHostMessages = (service, method, args) {
        expect('$service.$method', 'ports.watch');
        watching++;
        watch = StreamController<Object?>(onCancel: () => cancelled++);
        return watch.stream;
      };
  });

  Map<String, Object?> listener(int port) => {'family': 4, 'addr': '127.0.0.1', 'port': port};

  test('asks about the ports and the files together, in one call, and says what the machine answered', () async {
    up = {5173};
    final v = model();

    await v.check(ports: [5173, 8000], paths: ['/work/a.html', '/work/gone.html', '~/b.md']);

    expect(verified, hasLength(1), reason: 'one made.verify for everything shown');
    expect(verified.single, hasLength(5));
    expect(v.listening, {5173: true, 8000: false});
    expect(v.isGone('/work/gone.html'), isTrue);
    expect(v.isGone('/work/a.html'), isFalse);
    expect(v.isGone('~/b.md'), isFalse);
    expect(v.isGone('/work/never-asked.html'), isFalse, reason: 'not asked is not gone');
  });

  test('does not ask twice about what it already knows, and asks only the rest when a tab adds rows', () async {
    final v = model();
    await v.check(ports: [5173], paths: ['/work/a.html']);
    await v.check(ports: [5173], paths: ['/work/a.html']);
    expect(verified, hasLength(1));

    await v.check(ports: [5173], paths: ['/work/a.html', '/work/c.html']);
    expect(verified, hasLength(2));
    expect(verified.last.single['path'], '/work/c.html');
  });

  test('a path the host cannot take (relative) is never sent', () async {
    final v = model();
    await v.check(paths: ['reports/a.html', '/work/a.html']);

    expect(verified.single.map((i) => i['path']), ['/work/a.html']);
  });

  test('follows the ports with one watch, which flips a port when the machine says it opened or closed', () async {
    up = {5173};
    final v = model();
    final changes = <Map<int, bool>>[];
    v.addListener(() => changes.add(Map.of(v.listening)));
    await v.check(ports: [5173, 8000]);
    expect(watching, 1);

    watch.add({
      'listeners': [listener(5173)],
    });
    await pumpEventQueue();
    expect(v.listening, {5173: true, 8000: false});

    watch.add({
      'opened': [listener(8000)],
      'closed': [listener(5173)],
    });
    await pumpEventQueue();
    expect(v.listening, {5173: false, 8000: true});

    await v.check(ports: [5173]);
    expect(watching, 1, reason: 'one watch for all ports, however often it is asked');
  });

  test('without the helper nothing is answered and nothing is asked again', () async {
    final v = MadeVerification(HostPorts(FakeTransport()));
    addTearDown(v.dispose);

    await v.check(ports: [5173], paths: ['/work/a.html']);

    expect(v.unsupported, isTrue);
    expect(v.listening, isEmpty, reason: 'unknown, not "stopped"');
    expect(v.isGone('/work/a.html'), isFalse, reason: 'unknown, not "gone"');
    await v.check(ports: [8000]);
  });

  test('a machine that cannot list ports still answers for files; the ports stay unknown', () async {
    transport.onHostCall = (service, method, args) async => {
      'results': [
        for (final item in (args['items']! as List).cast<Map<String, Object?>>())
          if (item.containsKey('path'))
            {'id': item['id'], 'exists': false}
          else
            {'id': item['id'], 'error': 'unavailable'},
      ],
    };
    final v = model();

    await v.check(ports: [5173], paths: ['/work/a.html']);

    expect(v.isGone('/work/a.html'), isTrue);
    expect(v.listening, isEmpty);
    expect(watching, 0, reason: 'nothing to follow when the machine cannot list');
  });

  test('a lost link leaves everything unknown and the next check asks again', () async {
    var fail = true;
    final answer = transport.onHostCall!;
    transport.onHostCall = (service, method, args) async {
      if (fail) throw const HostLinkLost('the connection dropped');
      return answer(service, method, args);
    };
    final v = model();

    await v.check(ports: [5173], paths: ['/work/gone.html']);
    expect(v.listening, isEmpty);
    expect(v.isGone('/work/gone.html'), isFalse);

    fail = false;
    await v.check(ports: [5173], paths: ['/work/gone.html']);
    expect(v.listening, {5173: false});
    expect(v.isGone('/work/gone.html'), isTrue);
  });

  test('when the watch dies the ports go back to unknown instead of keeping a stale answer', () async {
    up = {5173};
    final v = model();
    await v.check(ports: [5173]);
    expect(v.listening, {5173: true});

    watch.addError(const HostLinkLost('the connection dropped'));
    await eventually(() => v.listening.isEmpty);

    await v.check(ports: [5173]);
    expect(v.listening, {5173: true}, reason: 'asked again, followed again');
    expect(watching, 2);
  });

  test('the background and closing both end the host watch; coming back asks again', () async {
    up = {5173};
    final v = MadeVerification(HostPorts(transport));
    await v.check(ports: [5173]);
    expect(watching, 1);

    v.pause();
    expect(cancelled, 1);
    expect(v.listening, isEmpty, reason: 'nothing is confirmed while nobody is looking');

    await v.check(ports: [5173], paths: ['/work/a.html']);
    expect(verified, hasLength(1), reason: 'a sheet that redraws in the background asks nothing');
    expect(watching, 1);

    v.resume();
    await v.check(ports: [5173]);
    expect(watching, 2);
    expect(v.listening, {5173: true});

    v.dispose();
    expect(cancelled, 2);
  });

  test('a file that vanished or came back while the app was in the background is asked again on return', () async {
    // The host's answer changes between the two asks, as when a file is deleted or recreated meanwhile.
    var present = true;
    transport.onHostCall = (service, method, args) async {
      final items = (args['items']! as List).cast<Map<String, Object?>>();
      verified.add(items);
      return {
        'results': [
          for (final item in items) {'id': item['id'], 'exists': present},
        ],
      };
    };
    final v = model();
    await v.check(paths: ['/work/a.html']);
    expect(v.isGone('/work/a.html'), isFalse);

    v.pause();
    present = false;
    v.resume();
    await v.check(paths: ['/work/a.html']);
    expect(verified, hasLength(2), reason: 'the answer from before the background is not trusted');
    expect(v.isGone('/work/a.html'), isTrue, reason: 'deleted meanwhile');

    v.pause();
    present = true;
    v.resume();
    await v.check(paths: ['/work/a.html']);
    expect(verified, hasLength(3));
    expect(v.isGone('/work/a.html'), isFalse, reason: 'recreated meanwhile');
  });
}
