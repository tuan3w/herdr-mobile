import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart' show muxReadyLine;
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/isolate_transport.dart';
import 'package:herdr_mobile/data/services/link_liveness.dart';
import 'package:herdr_mobile/data/services/mux_client.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';

import 'support/fake_transport.dart';

const _s = Duration(seconds: 1);
Duration _sec(int n) => Duration(seconds: n);

/// A mux script that answers every request.
class _MuxChannel implements MuxChannel {
  _MuxChannel() {
    _lines.add(muxReadyLine);
  }

  final _lines = StreamController<String>();
  final _exit = Completer<int?>();
  final sent = <Map<String, dynamic>>[];

  /// While true the script reads requests and says nothing.
  var silent = false;

  int get beats => sent.where((m) => (m['id'] as String).startsWith('hb')).length;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  void send(String line) {
    final m = jsonDecode(line) as Map<String, dynamic>;
    sent.add(m);
    if (silent) return;
    _lines.add(jsonEncode({
      'id': m['id'],
      'result': {'type': 'pong', 'version': '1'},
    }));
  }

  @override
  Future<void> close() async {
    if (!_exit.isCompleted) _exit.complete(null);
    if (!_lines.isClosed) unawaited(_lines.close());
  }

  @override
  Future<int?> get exitCode => _exit.future;
}

/// An SSH client that refuses every channel (which leaves the connection up)
/// and counts the pings it is sent.
class _Client implements SSHClient {
  var pings = 0;
  var closed = false;
  final _done = Completer<void>();
  Completer<void>? holdPing;

  @override
  bool get isClosed => closed;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> ping() {
    pings++;
    return holdPing?.future ?? Future.value();
  }

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) =>
      Future.error(SSHChannelOpenError(1, 'no more sessions'));

  @override
  Future<void> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Rig {
  _Rig(this.async) {
    t = SshTransport(
      profile: const MachineProfile(id: 'm', label: 'm', host: 'h', username: 'u'),
      secrets: const MachineSecrets(),
      onPinHostKey: (_) {},
      connectClient: () async {
        final c = _Client();
        clients.add(c);
        return c;
      },
      openMuxChannel: (_) async {
        final c = _MuxChannel();
        muxes.add(c);
        return c;
      },
      livenessClock: () => async.elapsed,
    );
  }

  final FakeAsync async;
  late final SshTransport t;
  final clients = <_Client>[];
  final muxes = <_MuxChannel>[];

  /// Opens the SSH connection (a refused channel leaves it up).
  void connectLink() {
    t.openExec('x').then((_) {}, onError: (Object _) {});
    async.flushMicrotasks();
  }

  void startMux() {
    t.request('ping').then((_) {}, onError: (Object _) {});
    async.flushMicrotasks();
  }

  void elapse(Duration d) => async.elapse(d);
  _MuxChannel get mux => muxes.last;
  _Client get client => clients.last;
}

void _rig(String name, void Function(_Rig r) body) =>
    test(name, () => fakeAsync((async) {
          final r = _Rig(async);
          body(r);
          unawaited(r.t.close());
          async.flushMicrotasks();
        }));

/// Runs inside the worker isolate; remembers what the app told it.
class _BgProbe implements HerdrTransport {
  final backgrounds = <bool>[];

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    if (method == 'die') Isolate.exit();
    return {'background': [...backgrounds]};
  }

  @override
  void setBackground(bool background) => backgrounds.add(background);

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) =>
      const Stream.empty();

  @override
  void reset() {}

  @override
  Future<ExecChannel> openExec(String command) => throw UnsupportedError('exec');

  @override
  bool get supportsFiles => false;

  @override
  Future<RemoteStat> statFile(String path) => throw UnsupportedError('files');

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => throw UnsupportedError('files');

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) =>
      throw UnsupportedError('files');

  @override
  Future<String> realPath(String path) => throw UnsupportedError('files');

  @override
  Future<void> makeDirs(String path) => throw UnsupportedError('files');

  @override
  Future<void> removeFile(String path) => throw UnsupportedError('files');

  @override
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) => throw UnsupportedError('files');

  @override
  Future<void> close() async {}
}

HerdrTransport _buildProbe(Object? config, void Function(String) a, void Function(String) b) =>
    _BgProbe();

void main() {
  group('timings', () {
    test('the foreground keeps the numbers the app always had', () {
      const f = LivenessTiming.foreground;
      expect([f.muxInterval, f.muxTimeout, f.linkInterval, f.linkTimeout],
          [_sec(8), _sec(5), _sec(25), _sec(10)]);
    });

    test('the background is 120 s / 15 s for the mux and 150 s / 15 s for the link', () {
      const b = LivenessTiming.background;
      expect([b.muxInterval, b.muxTimeout, b.linkInterval, b.linkTimeout],
          [_sec(120), _sec(15), _sec(150), _sec(15)]);
      expect(LivenessTiming.of(background: true), same(b));
      expect(LivenessTiming.of(background: false), same(LivenessTiming.foreground));
    });
  });

  group('the mux heartbeat', () {
    _rig('beats every 8 s in the foreground, every 120 s after going to the background', (r) {
      r.startMux();
      r.elapse(_sec(17));
      expect(r.mux.beats, 2);

      r.t.setBackground(true);
      r.elapse(_sec(119));
      expect(r.mux.beats, 2, reason: 'nothing for 119 s');
      r.elapse(_s);
      expect(r.mux.beats, 3);
      r.elapse(_sec(240));
      expect(r.mux.beats, 5);
    });

    _rig('going back to the foreground beats once at once, then every 8 s', (r) {
      r.startMux();
      r.t.setBackground(true);
      r.elapse(_sec(30));
      final before = r.mux.beats;

      r.t.setBackground(false);
      r.async.flushMicrotasks();
      expect(r.mux.beats, before + 1, reason: 'one immediate heartbeat');

      r.elapse(_sec(7));
      expect(r.mux.beats, before + 1);
      r.elapse(_s);
      expect(r.mux.beats, before + 2, reason: 'then every 8 s');
    });

    _rig('a mux that stops answering in the background is judged by the 15 s timeout, and the connection is reset', (r) {
      r.connectLink();
      r.startMux();
      r.t.setBackground(true);
      r.mux.silent = true;

      r.elapse(_sec(120)); // the beat goes out
      expect(r.mux.beats, 1);
      r.elapse(_sec(14));
      expect(r.client.closed, isFalse, reason: 'the background allows 15 s for the answer');
      r.elapse(_s);
      r.async.flushMicrotasks();

      expect(r.client.closed, isTrue, reason: 'a silent mux means a dead link: reset');
    });

    _rig('changing sides twice does not leave two heartbeat timers', (r) {
      r.startMux();
      for (var i = 0; i < 5; i++) {
        r.t.setBackground(true);
        r.t.setBackground(false);
      }
      r.async.flushMicrotasks();
      final beatsNow = r.mux.beats;

      r.elapse(_sec(16));

      expect(r.mux.beats - beatsNow, 2, reason: 'one timer: a beat per 8 s');
    });

    _rig('setBackground is idempotent: repeating it neither beats nor re-arms', (r) {
      r.startMux();
      r.t.setBackground(true);
      r.elapse(_sec(100));
      r.t.setBackground(true);
      r.t.setBackground(true);

      r.elapse(_sec(20));

      expect(r.mux.beats, 1, reason: 'the 120 s beat of the first call, not pushed back');
    });

    _rig('the setting survives a reconnect', (r) {
      r.t.setBackground(true);
      r.startMux();
      r.elapse(_sec(119));
      expect(r.mux.beats, 0);
      r.elapse(_s);
      expect(r.mux.beats, 1);

      r.t.reset();
      r.async.flushMicrotasks();
      r.startMux();
      expect(r.muxes, hasLength(2));
      r.elapse(_sec(119));
      expect(r.mux.beats, 0, reason: 'the new mux starts in the background mode');
      r.elapse(_s);
      expect(r.mux.beats, 1);
    });

    _rig('a mux that finished starting after the switch takes the new timings', (r) {
      r.t.request('ping').then((_) {}, onError: (Object _) {});
      // The mux is still starting when the app goes to the background.
      r.t.setBackground(true);
      r.async.flushMicrotasks();

      r.elapse(_sec(119));
      expect(r.mux.beats, 0);
      r.elapse(_s);
      expect(r.mux.beats, 1);
    });
  });

  group('the SSH link watch', () {
    _rig('an idle link is pinged after 25 s in the foreground', (r) {
      r.connectLink();
      r.elapse(_sec(24));
      expect(r.client.pings, 0);
      r.elapse(_s);
      expect(r.client.pings, 1);
      r.elapse(_sec(25));
      expect(r.client.pings, 2);
    });

    _rig('in the background an idle link is pinged every 150 s', (r) {
      r.connectLink();
      r.t.setBackground(true);

      r.elapse(_sec(149));
      expect(r.client.pings, 0);
      r.elapse(_s);
      expect(r.client.pings, 1);
      r.elapse(_sec(150));
      expect(r.client.pings, 2);
    });

    _rig('switching to the background keeps the time the link has already been quiet', (r) {
      r.connectLink();
      r.elapse(_sec(20)); // 20 s quiet, ping due in 5 s

      r.t.setBackground(true);
      r.elapse(_sec(129));
      expect(r.client.pings, 0, reason: 'due at 150 s of quiet');
      r.elapse(_s);
      expect(r.client.pings, 1);
    });

    _rig('going back to the foreground tests a link that was quiet for longer at once', (r) {
      r.connectLink();
      r.t.setBackground(true);
      r.elapse(_sec(100));
      expect(r.client.pings, 0);

      r.t.setBackground(false);
      r.async.flushMicrotasks();

      expect(r.client.pings, 1, reason: 'quiet for 100 s, foreground limit 25 s');
      r.elapse(_sec(24));
      expect(r.client.pings, 1);
      r.elapse(_s);
      expect(r.client.pings, 2);
    });

    _rig('going back to the foreground does not ping a link that just spoke', (r) {
      r.connectLink();
      r.t.setBackground(true);
      r.elapse(_sec(150)); // pinged, answered: quiet clock restarts
      expect(r.client.pings, 1);
      r.elapse(_sec(3));

      r.t.setBackground(false);
      r.async.flushMicrotasks();

      expect(r.client.pings, 1, reason: 'only 3 s since the last proof of life');
      r.elapse(_sec(22));
      expect(r.client.pings, 2);
    });

    _rig('a ping nobody answers resets the connection after the timeout of the current mode', (r) {
      r.connectLink();
      r.client.holdPing = Completer<void>();
      r.t.setBackground(true);
      r.elapse(_sec(150));
      expect(r.client.pings, 1);
      expect(r.client.closed, isFalse);

      r.elapse(_sec(14));
      expect(r.client.closed, isFalse);
      r.elapse(_s);
      r.async.flushMicrotasks();
      expect(r.client.closed, isTrue, reason: 'silent for the 15 s background timeout');
    });

    _rig('the link watch of a new connection starts in the mode the app is in', (r) {
      r.t.setBackground(true);
      r.connectLink();

      r.elapse(_sec(149));
      expect(r.client.pings, 0);
      r.elapse(_s);
      expect(r.client.pings, 1);
    });
  });

  group('LinkWatch', () {
    test('re-arming never leaves two watches: pings come at the interval, not twice as often', () {
      fakeAsync((async) {
        final live = LinkLiveness(clock: () => async.elapsed);
        var pings = 0;
        final watch = LinkWatch(
          liveness: live,
          ping: () async => pings++,
          onDead: () {},
          isClosed: () => false,
        )..start();

        for (var i = 0; i < 10; i++) {
          watch.configure(_sec(150), _sec(15));
          watch.configure(_sec(25), _sec(10), checkNow: i.isEven);
          async.flushMicrotasks();
        }
        final base = pings;

        async.elapse(_sec(100));
        expect(pings - base, inInclusiveRange(3, 4), reason: 'one ping per 25 s of silence, from one watch');
        expect(watch.armed, isTrue);
      });
    });

    test('stop cancels everything, and a stopped watch ignores configure', () {
      fakeAsync((async) {
        final live = LinkLiveness(clock: () => async.elapsed);
        var pings = 0;
        final watch = LinkWatch(
          liveness: live,
          ping: () async => pings++,
          onDead: () {},
          isClosed: () => false,
        )..start();

        watch.stop();
        watch.configure(_sec(1), _sec(1), checkNow: true);
        async.elapse(_sec(100));

        expect(pings, 0);
      });
    });

    test('a ping that fails is a dead link, reported once', () {
      fakeAsync((async) {
        final live = LinkLiveness(clock: () => async.elapsed);
        var dead = 0;
        LinkWatch(
          liveness: live,
          ping: () => Future.error(StateError('closed')),
          onDead: () => dead++,
          isClosed: () => false,
        ).start();

        async.elapse(_sec(200));

        expect(dead, 1);
      });
    });

    test('bytes that keep arriving keep a pinged link alive past the timeout', () {
      fakeAsync((async) {
        final live = LinkLiveness(clock: () => async.elapsed);
        var dead = 0;
        final answer = Completer<void>();
        LinkWatch(
          liveness: live,
          ping: () => answer.future,
          onDead: () => dead++,
          isClosed: () => false,
        ).start();
        async.elapse(_sec(25)); // pinged, never answered

        for (var i = 0; i < 12; i++) {
          async.elapse(_sec(5));
          live.inbound(); // the replay is still coming in
        }
        expect(dead, 0, reason: '60 s with a ping out, but bytes flowed');

        async.elapse(_sec(11));
        expect(dead, 1, reason: 'then silence for the 10 s timeout');
      });
    });
  });

  group('through the isolate', () {
    late IsolateTransport t;
    setUp(() => t = IsolateTransport(builder: _buildProbe, config: () => null, onPin: (_) {}));
    tearDown(() => t.close());

    Future<List<Object?>> seen() async =>
        (await t.request('probe'))['background'] as List<Object?>;

    test('a flag set before the worker exists is applied when it starts', () async {
      t.setBackground(true);

      expect(await seen(), [true]);
    });

    test('changes reach a running worker in order, and repeats are dropped', () async {
      expect(await seen(), isEmpty);

      t
        ..setBackground(true)
        ..setBackground(true)
        ..setBackground(false)
        ..setBackground(false)
        ..setBackground(true);

      expect(await seen(), [true, false, true]);
    });

    test('a replacement worker is told the app is still in the background', () async {
      t.setBackground(true);
      expect(await seen(), [true]);

      await expectLater(t.request('die'), throwsA(isA<HerdrTransportException>()));

      expect(await seen(), [true]);
    });

    test('a worker that starts after the app is back in the foreground is told nothing', () async {
      t
        ..setBackground(true)
        ..setBackground(false);

      expect(await seen(), isEmpty);
    });
  });

  group('HerdrApi', () {
    test('passes the flag to the transport', () {
      final transport = FakeTransport();
      final api = HerdrApi(transport);

      api.setBackground(true);
      api.setBackground(false);

      expect(transport.backgroundCalls, [true, false]);
    });
  });
}
