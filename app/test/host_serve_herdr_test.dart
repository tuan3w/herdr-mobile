@TestOn('linux || mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/host/host_channels.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/mux_client.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';

import 'support/fake_herdr_socket.dart';
import 'support/process_host.dart';

// The herdr relay the app depends on, against the REAL `herdr-host serve` and a
// herdr socket played by the test: the board's requests (cut to what the app
// reads, deltas that rebuild the screen), the event stream, a herdr that is not
// there yet, and the app's own transport on top of all that. The Rust side is
// tested in rust/crates/host/tests (mux_golden, serve_herdr).
//
// Needs the binary: `cd rust && cargo build --release -p host`, or
// HERDR_HOST_BIN=/path/to/herdr-host.

File _binary() {
  final fromEnv = Platform.environment['HERDR_HOST_BIN'];
  if (fromEnv != null && fromEnv.isNotEmpty) return File(fromEnv);
  final root = File('test/host_serve_herdr_test.dart').absolute.parent.parent.parent.path;
  return File('$root/rust/target/release/herdr-host');
}

/// A [HostProcess] that counts what the host wrote.
class _Counting implements HostProcess {
  _Counting(this._inner);

  final HostProcess _inner;
  var bytesIn = 0;

  @override
  late final Stream<Uint8List> stdout = _inner.stdout.map((c) {
    bytesIn += c.length;
    return c;
  });

  @override
  Stream<Uint8List> get stderr => _inner.stderr;

  @override
  StreamSink<Uint8List> get stdin => _inner.stdin;

  @override
  Future<void> get done => _inner.done;

  @override
  int? get exitCode => _inner.exitCode;

  @override
  void close() => _inner.close();
}

void main() {
  final bin = _binary();
  final skip = bin.existsSync()
      ? false
      : 'build the host first: cd rust && cargo build --release -p host (or set HERDR_HOST_BIN)';
  late Directory home;
  late String socketPath;
  final started = <HostProcess>[];

  setUp(() {
    home = Directory.systemTemp.createTempSync('host_serve_herdr');
    socketPath = '${home.path}/xdg/herdr/herdr.sock';
  });

  tearDown(() {
    for (final p in started) {
      p.close();
    }
    started.clear();
    home.deleteSync(recursive: true);
  });

  Future<_Counting> serve() async {
    final p = _Counting(
      await ProcessHostProcess.start(
        bin.path,
        ['serve'],
        environment: {'HOME': home.path, 'XDG_CONFIG_HOME': '${home.path}/xdg', 'PATH': '/usr/bin:/bin'},
        workingDirectory: home.path,
      ),
    );
    started.add(p);
    return p;
  }

  Future<HostLink> connect(_Counting p) => HostLink.connect(p, version: appVersion);

  HostStream openMux(HostLink link) => link.open('herdr', 'mux', {
    'projections': muxProjections,
    'delta': {'min_chars': muxDeltaMin, 'max_rows': muxDeltaRows, 'keep': muxDeltaKeep, 'keep_chars': muxDeltaChars},
  }, true);

  test('the helper says which version it is and that herdr is there', () async {
    final herdr = await FakeHerdrSocket.bind(socketPath);
    addTearDown(herdr.close);
    final link = await connect(await serve());
    expect(link.hello.version, appVersion, reason: 'the binary reports the app version it was built for');
    expect(link.hello.home, home.path);
    expect(link.hello.has('herdr'), isTrue);
  }, skip: skip);

  test(
    'requests come back cut to what the app reads, and a repeated screen read rebuilds exactly from a delta',
    () async {
      final herdr = await FakeHerdrSocket.bind(socketPath);
      addTearDown(herdr.close);
      final p = await serve();
      final link = await connect(p);
      final mux = await MuxClient.connect(HostMuxChannel(openMux(link)));
      addTearDown(mux.close);

      expect((await mux.request('ping'))['type'], 'pong');

      final snapshot = (await mux.request('session.snapshot'))['snapshot']! as Map<String, dynamic>;
      final pane = (snapshot['panes']! as List).single as Map<String, dynamic>;
      expect(pane['pane_id'], 'w1:p1');
      expect(pane.containsKey('session_path'), isFalse, reason: 'a field the app does not read is cut on the host');
      expect(snapshot['workspaces'], isNotEmpty);

      final before = p.bytesIn;
      final first =
          (await mux.request('pane.read', {'pane_id': 'w1:p1', 'lines': 300}))['read']! as Map<String, dynamic>;
      final firstBytes = p.bytesIn - before;
      expect(first['text'], herdr.screen());
      expect((first as Map).containsKey('source'), isFalse);

      // The screen scrolls by three rows; the client holds the last answer, so the
      // host sends the rows that changed and the client puts the screen back together.
      herdr.scrolled = 3;
      final mid = p.bytesIn;
      final second =
          (await mux.request('pane.read', {'pane_id': 'w1:p1', 'lines': 300}))['read']! as Map<String, dynamic>;
      final secondBytes = p.bytesIn - mid;
      expect(second['text'], herdr.screen());
      expect(
        secondBytes * 5,
        lessThan(firstBytes),
        reason: 'a slid screen is a delta: $secondBytes bytes after $firstBytes',
      );

      // Unchanged: almost nothing.
      final again = p.bytesIn;
      expect(
        ((await mux.request('pane.read', {'pane_id': 'w1:p1', 'lines': 300}))['read']! as Map)['text'],
        herdr.screen(),
      );
      expect(p.bytesIn - again, lessThan(300));
    },
    skip: skip,
  );

  test('requests sent together each get their own answer', () async {
    final herdr = await FakeHerdrSocket.bind(socketPath);
    addTearDown(herdr.close);
    final link = await connect(await serve());
    final mux = await MuxClient.connect(HostMuxChannel(openMux(link)));
    addTearDown(mux.close);

    final answers = await Future.wait([for (var i = 0; i < 20; i++) mux.request('ping')]);

    expect(answers.every((a) => a['type'] == 'pong'), isTrue);
    expect(herdr.requests, hasLength(20));
  }, skip: skip);

  test('a request sent right behind our HELLO and the OPEN, before the host has answered, gets its answer', () async {
    final herdr = await FakeHerdrSocket.bind(socketPath);
    addTearDown(herdr.close);
    final link = HostLink.start(await serve(), version: appVersion);
    final mux = await MuxClient.connect(HostMuxChannel(openMux(link)), waitForReady: false);
    addTearDown(mux.close);

    // Written before the host's HELLO could have come back: the link has no HELLO yet.
    expect(() => link.hello, throwsStateError);
    final first = mux.request('ping');
    final snapshot = mux.request('session.snapshot');

    expect((await first)['type'], 'pong');
    expect(((await snapshot)['snapshot']! as Map)['panes'], hasLength(1));
    expect((await link.helloFuture).has('herdr'), isTrue);
    expect((await mux.request('ping'))['type'], 'pong');
  }, skip: skip);

  test(
    'pipelined behind a host that has no herdr, the request fails as MuxUnavailable (the bridge is the next step)',
    () async {
      final link = HostLink.start(await serve(), version: appVersion);
      final mux = await MuxClient.connect(HostMuxChannel(openMux(link)), waitForReady: false);
      addTearDown(mux.close);

      await expectLater(
        mux.request('ping'),
        throwsA(
          isA<MuxUnavailable>()
              .having((e) => e.linkLost, 'linkLost', isFalse)
              .having((e) => e.helperMissing, 'helperMissing', isFalse)
              .having((e) => e.message, 'message', contains('no herdr socket')),
        ),
      );
      expect(link.isOpen, isTrue, reason: 'the link is fine; only the mux could not start');
    },
    skip: skip,
  );

  test('an event stream acknowledges first, then delivers each event cut to what the app reads', () async {
    final herdr = await FakeHerdrSocket.bind(socketPath);
    addTearDown(herdr.close);
    final link = await connect(await serve());
    final s = link.open('herdr', 'events', {
      'subscriptions': [
        {'type': 'pane.updated'},
      ],
      'projection': eventProjection,
    }, true);
    final got = <Map<String, dynamic>>[];
    s.texts.listen((t) => got.add(jsonDecode(t) as Map<String, dynamic>));
    await until(() => got.isNotEmpty);
    expect(got.first['result'], {'type': 'subscription_started'});
    await until(() => herdr.subscriptions == 1);

    herdr.pushEvent({
      'event': 'pane_updated',
      'data': {
        'pane': {'pane_id': 'w1:p1', 'agent_status': 'blocked', 'session_path': '/secret'},
        'debug': 'x',
      },
    });
    herdr.pushEvent({
      'event': 'tab_closed',
      'data': {'tab_id': 'w1:t1'},
    });
    await until(() => got.length == 3);

    expect(got[1], {
      'event': 'pane_updated',
      'data': {
        'pane': {'pane_id': 'w1:p1', 'agent_status': 'blocked'},
      },
    });
    expect(got[2]['event'], 'tab_closed');
    expect(herdr.requests.single['method'], 'events.subscribe');

    // The client ends the subscription: herdr's connection goes.
    s.reset();
    await until(() => herdr.subscriptions == 0);
  }, skip: skip);

  test(
    'without herdr the mux is unavailable with the reason, and a herdr that starts later is used on the same link',
    () async {
      final link = await connect(await serve());
      expect(link.hello.has('herdr'), isFalse);
      expect(link.hello.services['herdr']!.reason, contains('no herdr socket at $socketPath'));

      await expectLater(
        MuxClient.connect(HostMuxChannel(openMux(link)), startupTimeout: const Duration(seconds: 5)),
        throwsA(
          isA<MuxUnavailable>()
              .having((e) => e.linkLost, 'linkLost', isFalse)
              .having((e) => e.message, 'message', contains('no herdr socket')),
        ),
      );

      final herdr = await FakeHerdrSocket.bind(socketPath);
      addTearDown(herdr.close);
      final mux = await MuxClient.connect(HostMuxChannel(openMux(link)));
      addTearDown(mux.close);
      expect((await mux.request('ping'))['type'], 'pong');
    },
    skip: skip,
  );

  test('the app\'s transport carries requests and events on the helper, with no other channel', () async {
    final herdr = await FakeHerdrSocket.bind(socketPath);
    addTearDown(herdr.close);
    final commands = <String>[];
    final transport = SshTransport(
      profile: const MachineProfile(id: 'm', label: 'm', host: 'h', username: 'u'),
      secrets: const MachineSecrets(),
      onPinHostKey: (_) {},
      openHostProcess: (command) async {
        commands.add(command);
        return serve();
      },
    );
    addTearDown(transport.close);

    expect((await transport.request('ping'))['type'], 'pong');
    final snapshot = (await transport.request('session.snapshot'))['snapshot']! as Map<String, dynamic>;
    expect(snapshot['panes'], hasLength(1));

    final events = <Map<String, dynamic>>[];
    final sub = transport
        .events([
          {'type': 'pane.updated'},
        ])
        .listen(events.add);
    addTearDown(sub.cancel);
    await until(() => events.isNotEmpty);
    expect(events.first, {'event': subscriptionStartedEvent});
    await until(() => herdr.subscriptions == 1);
    herdr.pushEvent({
      'event': 'pane_updated',
      'data': {
        'pane': {'pane_id': 'w1:p1', 'agent_status': 'done'},
      },
    });
    await until(() => events.length == 2);
    expect(((events.last['data'] as Map)['pane'] as Map)['agent_status'], 'done');

    expect(commands, hasLength(1), reason: 'one helper process serves the mux and the events');
    expect(commands.single, startsWith("sh -c '"), reason: 'started the way an SSH server would run it');
  }, skip: skip);
}

Future<void> until(bool Function() check, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for a condition');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
