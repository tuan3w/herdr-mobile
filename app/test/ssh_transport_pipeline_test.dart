import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/host/wire.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart' show hostServeCommand;
import 'package:herdr_mobile/data/services/ssh_transport.dart';

import 'support/fake_host.dart';

// The cold start of the board over the agent helper: the host's HELLO, the
// `herdr.mux` OPEN and the first request leave together, so the first answer
// comes two round trips sooner than greet, open, wait for ready, request. The
// machine here is scripted (FakeHost); a bridge session answers for the machine
// whose mux cannot be had.

/// The bridge command's channel: answers the one request written to it.
class _BridgeSession implements SSHSession {
  _BridgeSession() {
    _stdin.stream.listen((bytes) {
      for (final line in utf8.decode(bytes).split('\n')) {
        if (line.trim().isEmpty) continue;
        final request = jsonDecode(line) as Map;
        _stdout.add(
          Uint8List.fromList(
            utf8.encode(
              '${jsonEncode({
                'id': request['id'],
                'result': {'type': 'pong', 'via': 'bridge'},
              })}\n',
            ),
          ),
        );
      }
    });
  }

  final _stdout = StreamController<Uint8List>();
  final _stdin = StreamController<Uint8List>();
  final _done = Completer<void>();

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  StreamSink<Uint8List> get stdin => _stdin.sink;

  @override
  Future<void> get done => _done.future;

  @override
  int? get exitCode => null;

  @override
  void close() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements SSHClient {
  _Client(this.bridges);

  final List<_BridgeSession> bridges;
  var _closed = false;
  final _done = Completer<void>();

  @override
  bool get isClosed => _closed;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> ping() async {}

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    final s = _BridgeSession();
    bridges.add(s);
    return s;
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The machine: what each `serve` start and each install gets.
class _Machine {
  /// A `serve` start: [onServe] decides what that host does (the test holds the
  /// host and plays it).
  final serves = <FakeHost>[];
  var installs = 0;
  final bridges = <_BridgeSession>[];

  /// Whether the installer succeeds.
  var installOk = true;

  /// What the n-th `serve` does once opened, by index.
  void Function(FakeHost host, int index)? onServe;

  Future<HostProcess> open(String command) async {
    final host = FakeHost();
    if (command == hostServeCommand()) {
      serves.add(host);
      onServe?.call(host, serves.length - 1);
      return host;
    }
    installs++;
    scheduleMicrotask(() {
      if (installOk) host.sendBytes(utf8.encode('{"ok":true}\n'));
      host.exit(installOk ? 0 : 1);
    });
    return host;
  }
}

SshTransport _transport(_Machine m, {Duration requestTimeout = const Duration(seconds: 20)}) => SshTransport(
  profile: const MachineProfile(id: 'm', label: 'm', host: 'h', username: 'u'),
  secrets: const MachineSecrets(),
  onPinHostKey: (_) {},
  requestTimeout: requestTimeout,
  connectClient: (_) async => _Client(m.bridges),
  openHostProcess: m.open,
);

/// A healthy host played by the test: it holds everything back until [release]
/// (its HELLO, herdr's ready, every answer), the way a host that is a round
/// trip away has said nothing yet when the client's frames are already out.
class _Healthy {
  _Healthy(this.host) {
    host.onFrame = (f) {
      if (f.kind != FrameKind.open && f.kind != FrameKind.msg) return;
      if (released) {
        _handle(f);
      } else {
        _held.add(f);
      }
    };
  }

  final FakeHost host;
  var released = false;
  final _held = <Frame>[];

  int stream(String method) => host.opens.firstWhere((o) => o['method'] == method)['stream']! as int;

  void release() {
    released = true;
    host.greet();
    for (final f in _held) {
      _handle(f);
    }
    _held.clear();
  }

  void _handle(Frame f) {
    if (f.kind == FrameKind.open) {
      final open = jsonDecode(utf8.decode(f.payload)) as Map;
      if (open['method'] == 'mux') {
        host.sendReady(f.stream);
      } else {
        host.sendJson(FrameKind.msg, f.stream, {
          'id': 'sub',
          'result': {'type': 'subscription_started'},
        });
      }
    } else {
      final request = jsonDecode(utf8.decode(f.payload)) as Map;
      host.answer(f.stream, request['id'] as String, {'type': 'pong', 'via': 'host'});
    }
  }
}

void main() {
  late _Machine machine;
  late SshTransport t;
  // The scripts of the hosts `serve` started, in order.
  late List<_Healthy> scripts;
  setUp(() {
    machine = _Machine();
    scripts = [];
  });
  tearDown(() => t.close());

  void healthy(FakeHost h, int i) => scripts.add(_Healthy(h));

  test('the HELLO, the mux OPEN and the first request are all written before the host says anything', () async {
    machine.onServe = healthy;
    t = _transport(machine);

    final answer = t.request('ping');
    await until(() => machine.serves.isNotEmpty && machine.serves.first.received.length >= 3, what: 'three frames');
    final h = machine.serves.single;

    // Nothing from the host yet (its HELLO is held back): all three are out.
    final mux = h.opens.single['stream']! as int;
    expect(h.opens.single['svc'], 'herdr');
    expect(h.opens.single['method'], 'mux');
    expect(h.requestsOn(mux).single['method'], 'ping');
    expect(h.received.map((f) => f.kind), [FrameKind.hello, FrameKind.open, FrameKind.msg]);
    expect(scripts.single.released, isFalse);

    // The host's side, in the order it speaks: HELLO, ready, the answer.
    scripts.single.release();
    expect(await answer, {'type': 'pong', 'via': 'host'});
    expect(machine.serves, hasLength(1));
    expect(machine.installs, 0);
  });

  test('the events subscription opens on the same link before the HELLO too, asking the host to coalesce', () async {
    machine.onServe = healthy;
    t = _transport(machine);

    final events = <Map<String, dynamic>>[];
    final sub = t
        .events([
          {'type': 'pane.updated'},
        ])
        .listen(events.add);
    addTearDown(sub.cancel);
    final answer = t.request('ping');
    await until(() => machine.serves.isNotEmpty && machine.serves.first.opens.length == 2, what: 'both OPENs');
    final h = machine.serves.single;
    expect(h.opens.map((o) => o['method']).toSet(), {'mux', 'events'});
    final ev = h.opens.firstWhere((o) => o['method'] == 'events');
    expect((ev['args']! as Map)['coalesce_ms'], SshTransport.eventCoalesceMs);
    expect(SshTransport.eventCoalesceMs, 250);
    expect(h.received.where((f) => f.kind == FrameKind.hello), hasLength(1));

    scripts.single.release();
    expect((await answer)['via'], 'host');
    await until(() => events.isNotEmpty, what: 'the subscription ack');
    expect(events.first['event'], 'subscription_started');
    expect(machine.serves, hasLength(1));
  });

  test('callers that need the HELLO (the file backend) still wait for it', () async {
    machine.onServe = healthy;
    t = _transport(machine);

    HostLink? link;
    final got = t.hostLink().then((l) => link = l);
    await until(() => machine.serves.isNotEmpty && machine.serves.first.received.isNotEmpty, what: 'our HELLO');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(link, isNull);
    scripts.single.release();
    expect((await got).hello.version, '9.9.9');
  });

  group('the helper is not installed', () {
    test('the pipelined streams fail, the installer runs once, both streams reopen and the request succeeds', () async {
      machine.onServe = (h, i) {
        if (i > 0) {
          healthy(h, i);
          return;
        }
        // Our HELLO, OPENs and request reach it; it exits 65 without a word.
        scheduleMicrotask(() async {
          await until(() => h.opens.length == 2, what: 'both OPENs');
          h.writeStderr('herdr-mobile: agent helper is not installed\n');
          h.exit(65);
        });
      };
      t = _transport(machine);

      final events = <Map<String, dynamic>>[];
      final sub = t
          .events([
            {'type': 'pane.updated'},
          ])
          .listen(events.add, onError: (Object _) {});
      addTearDown(sub.cancel);
      final answer = t.request('ping');

      await until(() => machine.serves.length == 2 && machine.serves[1].opens.length == 2, what: 'the reopen');
      final h = machine.serves[1];
      // The request went out on the new link before its HELLO was released too.
      expect(h.kindsOn(0), [FrameKind.hello]);
      expect(h.requestsOn(scripts.single.stream('mux')).single['method'], 'ping');
      scripts.single.release();

      expect(await answer, {'type': 'pong', 'via': 'host'});
      await until(() => events.isNotEmpty, what: 'the subscription on the new link');
      expect(machine.installs, 1, reason: 'one install for both streams');
      expect(machine.serves, hasLength(2));
      expect(machine.bridges, isEmpty);
    });

    test('an install that fails is the unavailable verdict: this request uses the bridge, the next ones too', () async {
      machine.installOk = false;
      machine.onServe = (h, i) => scheduleMicrotask(() => h.exit(65));
      t = _transport(machine);

      expect((await t.request('ping'))['via'], 'bridge');
      expect((await t.request('ping'))['via'], 'bridge');
      expect(machine.installs, 1, reason: 'the verdict is remembered, no second install');
      expect(machine.serves, hasLength(1), reason: 'and no second serve');
      await expectLater(
        t.hostCall('keeper', 'probe'),
        throwsA(isA<HostException>().having((e) => e.code, 'code', anyOf('install_failed', 'unavailable'))),
      );
    });

    test('a second 65 after the install is the verdict too, with no third try', () async {
      machine.onServe = (h, i) => scheduleMicrotask(() => h.exit(65));
      t = _transport(machine);

      expect((await t.request('ping'))['via'], 'bridge');
      expect(machine.installs, 1);
      expect(machine.serves, hasLength(2));
      await expectLater(
        t.hostCall('keeper', 'probe'),
        throwsA(isA<HostException>().having((e) => e.code, 'code', 'unavailable')),
      );
      expect((await t.request('ping'))['via'], 'bridge');
      expect(machine.installs, 1);
      expect(machine.serves, hasLength(2));
    });
  });

  test('a host without herdr (END unavailable instead of ready): this request and the next use the bridge', () async {
    machine.onServe = (h, i) {
      scheduleMicrotask(() async {
        await until(() => h.opens.isNotEmpty, what: 'the OPEN');
        h.greet();
        h.sendJson(FrameKind.end, h.opens.single['stream']! as int, {
          'error': {'code': 'unavailable', 'message': 'no herdr socket at /x for session default', 'retryable': true},
        });
      });
    };
    t = _transport(machine);

    expect((await t.request('ping'))['via'], 'bridge');
    expect((await t.request('ping'))['via'], 'bridge');
    expect(machine.serves, hasLength(1));
    expect(machine.serves.single.opens, hasLength(1), reason: 'no second mux was opened inside the 30 s');
    expect(machine.installs, 0);
  });

  test(
    'a link lost before the HELLO is a retryable connection error, not a verdict; the next try starts again',
    () async {
      machine.onServe = (h, i) {
        if (i == 0) {
          scheduleMicrotask(() async {
            await until(() => h.opens.isNotEmpty, what: 'the OPEN');
            h.exit(null);
          });
        } else {
          healthy(h, i);
          scheduleMicrotask(() => scripts.last.release());
        }
      };
      t = _transport(machine);

      await expectLater(
        t.request('ping'),
        throwsA(isA<HerdrTransportException>().having((e) => e.message, 'message', contains('Connection lost'))),
      );
      expect(machine.installs, 0);
      expect(machine.bridges, isEmpty);

      expect((await t.request('ping'))['via'], 'host');
      expect(machine.serves, hasLength(2));
      expect(machine.installs, 0);
    },
  );
}
