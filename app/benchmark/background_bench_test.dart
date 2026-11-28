// Battery and network cost of watching agents, in virtual time, deterministic.
//
//   BENCH_OUT=/tmp/bg.txt flutter test benchmark/background_bench_test.dart
//
// The real stack from the fleet down to the SSH layer runs: `FleetRepository`,
// `MachineConnection`, `HerdrApi`, `SshTransport` (its link watch, the machine's
// one `HostLink`, mux heartbeat, event stream and reconnects), `MuxClient`
// (deltas included), `SshAgentHost` (the session list), `PanePreviews`,
// `AttentionNotifier`. Only the bottom is replaced: an in-memory SSH client whose
// one exec channel is the host end of `herdr-host serve` (`_ServeSession`: it
// decodes the hostwire/1 frames the app writes and answers the way the helper
// does) over a fake herdr (`_Host`), which meter every message that would cross
// the radio, and a `fakeAsync` clock. No sockets, no wall time: the same run
// gives the same numbers.
//
// Workload (2 machines, 9 agents, one shell; seeded). Three runs:
//   foreground  3 min on the board, every working agent redrawing 10x/s
//               (herdr's `pane_updated` churn), previews on every card
//   watching    2 h in the background with notifications on (the foreground
//               service keeps the connections): agents block and unblock every
//               6-14 min, a Wi-Fi -> mobile handover at 40 min, an agent pane
//               appears at 55 min and one closes at 95 min, machine b is down
//               from 70 to 85 min
//   resume      back in the foreground: time until the board is true again
//   steady      the same without the turbulence, 1 h: what watching costs when
//               nothing goes wrong (`steady_*`)
//   suspended   notifications off: 1 h in the background, then the resume
//   warm        the board in front with 2 agents waiting, 3 min with and without
//               the warming of their tails (`warm_*`): reads and KB per minute,
//               and what is read once the board is covered or the app leaves
//
// `bg_score_s_per_h` is the one number to lower: the radio cost per hour (see
// the assumptions) plus an hour's worth of radio for every share of the time a
// reachable machine was not watched and every share of the blocked agents that
// were never announced. A watch that dies is not cheap, it is broken. Metrics
// named `fg_` are the board in front, `bg_` the turbulent watch, `steady_` the
// quiet one.
//
// What is metered, per message: the SSH channel's data as written, which is
// every frame at its size on the wire. The app's frames are the real ones (the
// `HostLink` writes them: 9 header bytes, requests deflated as pieces of the
// stream's continuous zlib stream); the host's are modelled on the helper's
// rules: a header of 9 bytes, and on a zctx stream (events and the mux are
// opened with it) every MSG of 64 bytes or more is the next piece of one
// sync-flushed zlib stream. Events are cut to the projection the app sent when
// it opened the stream; the mux's delta + rows protocol is ported to Dart in
// `_Host.serve`. Plus packet overhead.
//
// ASSUMPTIONS, not measurements (a phone's modem is not here; mark any number
// built on them as modelled):
//  * the radio stays in its high-power state for [radioTailS] after the last
//    packet either way (LTE RRC inactivity timer; 3G/5G vary), and waking it
//    from idle costs as much as [wakeCostS] more seconds of it;
//  * every packet carries [packetOverhead] bytes (TCP/IP + SSH MAC and length);
//    TCP ACKs and retransmits are not counted;
//  * a machine's herdr sends the events the app subscribed to and no others;
//    a status change is one `pane_agent_status_changed`, nothing else;
//  * the machine's one `serve` channel is opened with the SSH exec (one round
//    trip) and answers the app's HELLO a round trip later; every answer comes a
//    round trip after its request, an event as it happens.
//
// Results go to $BENCH_OUT as METRIC lines (`flutter test` decorates stdout).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/attention_notifier.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/pane_tails.dart' show paneTailRows;
import 'package:herdr_mobile/ui/features/pane/pane_view_model.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart' show muxDeltaMin, muxReadyLine;
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';
import 'package:herdr_mobile/data/services/ssh_agent_host.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart' show hostServeCommand;
import 'package:herdr_mobile/data/host/wire.dart';

import '../test/support/fake_network.dart';
import '../test/support/fake_notifier.dart';
import '../test/support/fake_transport.dart' show snapshotJson;
import '../test/support/memory_stores.dart';

const radioTailS = 10.0;
const wakeCostS = 2.0;
const packetOverhead = 76; // 40 TCP/IP + 36 SSH (length, padding, MAC)
const mss = 1400;

/// One round trip to the machines (ASSUMPTION: a phone on mobile data). The
/// link has no other latency, so a time in the results counts round trips and
/// the app's own delays.
const rtt = Duration(milliseconds: 80);

/// The zone of the fake clock; the rig's own timers are made in it, outside
/// the zone whose timers are counted as the app's.
late Zone _base;

Future<void> _later(Duration d) {
  final c = Completer<void>();
  _base.createTimer(d, c.complete);
  return c.future;
}

// ----------------------------------------------------------------------------
// The meter

class _Mark {
  const _Mark(this.ms, this.bytes, this.up);
  final int ms;
  final int bytes;
  final bool up;
}

typedef Window = ({int bytes, int packets, double activeS, int wakeups, double costS});

class Meter {
  Meter(this._now);

  final Duration Function() _now;
  final marks = <_Mark>[];
  final counts = <String, int>{};

  /// What happened and when, in ms, for BENCH_TRACE.
  final timeline = <(int, String)>[];

  void count(String what) {
    counts[what] = (counts[what] ?? 0) + 1;
    timeline.add((_now().inMilliseconds, what));
  }

  /// One message of [payload] bytes in one direction.
  void add(int payload, {required bool up}) {
    final packets = math.max(1, (payload / mss).ceil());
    final at = _now().inMilliseconds;
    for (var i = 0; i < packets; i++) {
      marks.add(_Mark(at, (i == packets - 1 ? payload - mss * (packets - 1) : mss) + packetOverhead, up));
    }
  }

  /// What crossed the radio in [fromMs, toMs): bytes, packets, the seconds the
  /// radio was held up and how many times it was woken from idle.
  Window window(int fromMs, int toMs) {
    var bytes = 0, packets = 0;
    final times = <int>[];
    for (final m in marks) {
      if (m.ms < fromMs || m.ms >= toMs) continue;
      bytes += m.bytes;
      packets++;
      if (times.isEmpty || times.last != m.ms) times.add(m.ms);
    }
    final tail = (radioTailS * 1000).round();
    var active = 0;
    var wakeups = 0;
    int? start, end;
    for (final t in times) {
      if (end != null && t <= end) {
        end = t + tail;
        continue;
      }
      if (start != null) active += math.min(end!, toMs) - start;
      start = t;
      end = t + tail;
      wakeups++;
    }
    if (start != null) active += math.min(end!, toMs) - start;
    final activeS = active / 1000;
    return (bytes: bytes, packets: packets, activeS: activeS, wakeups: wakeups, costS: activeS + wakeups * wakeCostS);
  }
}

// ----------------------------------------------------------------------------
// herdr, the mux script and the SSH link, in memory

class _Sub {
  _Sub(this.types, this.out);
  final List<Map<String, dynamic>> types;
  final void Function(String line) out;

  bool wants(String type, String? paneId) {
    for (final t in types) {
      if (t['type'] != type) continue;
      if (t['pane_id'] == null || t['pane_id'] == paneId) return true;
    }
    return false;
  }
}

class _Held {
  const _Held(this.seq, this.rows);
  final int seq;
  final List<String> rows;
}

class _Host {
  _Host(this.id, this.meter, this.now, Map<String, String> agents, {Set<String> shells = const {}})
    : statuses = {...agents},
      shells = {...shells};

  final String id;
  final Meter meter;
  final Duration Function() now;

  /// Agent panes and their status; [shells] are panes without an agent.
  final Map<String, String> statuses;
  final Set<String> shells;

  final subs = <_Sub>[];
  _Link? link;
  bool down = false;

  final _held = <String, _Held>{};
  var _seq = 0;
  final _scroll = <String, int>{};

  Map<String, dynamic> snapshot() => snapshotJson(
    panes: [
      for (final e in statuses.entries) (id: e.key, ws: 'w1', agent: 'claude', status: e.value),
      for (final s in shells) (id: s, ws: 'w1', agent: null, status: 'idle'),
    ],
  );

  Map<String, dynamic> _paneJson(String pane) =>
      (snapshot()['panes'] as List).cast<Map<String, dynamic>>().firstWhere((p) => p['pane_id'] == pane);

  bool hasPane(String pane) => statuses.containsKey(pane) || shells.contains(pane);

  // -- what herdr sends ---------------------------------------------------------

  void _emit(String type, String event, Map<String, dynamic> data, {String? paneId}) {
    final line = jsonEncode({'event': event, 'data': data});
    for (final s in [...subs]) {
      if (s.wants(type, paneId)) s.out(line);
    }
  }

  /// The screen of a working agent changed (~770 B each, as herdr sends it).
  void churn() {
    for (final MapEntry(:key, :value) in statuses.entries) {
      if (value != 'working') continue;
      _scroll[key] = (_scroll[key] ?? 0) + 1;
      if (!subs.any((s) => s.wants('pane.updated', key))) continue;
      final pane = _paneJson(key)..['revision'] = _scroll[key];
      final body = {'pane': pane};
      final pad = 770 - jsonEncode({'event': 'pane_updated', 'data': body}).length;
      if (pad > 0) pane['screen_hint'] = ' ' * pad;
      _emit('pane.updated', 'pane_updated', body, paneId: key);
    }
  }

  void setStatus(String pane, String status) {
    if (statuses[pane] == status) return;
    statuses[pane] = status;
    _emit('pane.agent_status_changed', 'pane_agent_status_changed', {
      'pane_id': pane,
      'agent_status': status,
    }, paneId: pane);
    _emit('pane.updated', 'pane_updated', {'pane': _paneJson(pane)}, paneId: pane);
  }

  void addAgent(String pane, String status) {
    statuses[pane] = status;
    _emit('pane.created', 'pane_created', {'pane_id': pane});
    _emit('pane.agent_detected', 'pane_agent_detected', {'pane_id': pane});
  }

  void closePane(String pane) {
    statuses.remove(pane);
    shells.remove(pane);
    _emit('pane.closed', 'pane_closed', {'pane_id': pane});
  }

  // -- the mux's answers: delta + rows, ported from `rust/crates/host/src/mux.rs` -----

  /// The answer to [q] as the app's `MuxClient` receives it (the text of one
  /// MSG on the `herdr.mux` stream).
  String serve(Map<String, dynamic> q) {
    final method = q['method'] as String;
    final id = q['id'];
    final params = (q['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    final Map<String, dynamic> d;
    switch (method) {
      case 'ping':
        meter.count('mux_heartbeats');
        d = {
          'id': id,
          'result': {'type': 'pong', 'version': '9.9.9'},
        };
      case 'session.snapshot':
        meter.count('snapshots');
        final s = snapshot();
        final rows = ['v${s['version']}'];
        for (final (k, c) in [('workspaces', 'w'), ('tabs', 't'), ('panes', 'p')]) {
          for (final x in s[k] as List) {
            rows.add('$c${jsonEncode(x)}');
          }
        }
        d = {
          'id': id,
          'result': {'type': 'session_snapshot', 'snapshot': <String, dynamic>{}},
        };
        _heldAnswer(q, d, d['result'] as Map<String, dynamic>, 'snapshot', rows, snapshot: true);
      case 'pane.read':
        meter.count('pane_reads');
        // The pane screen's 300-row tail, which the board warms for waiting agents.
        if (params['lines'] == 300) meter.count('pane_tail_reads');
        final pane = params['pane_id'] as String;
        final text = _screen(pane, params['lines'] as int? ?? 24);
        final read = <String, dynamic>{'text': text, 'truncated': false};
        d = {
          'id': id,
          'result': {'type': 'pane_read', 'read': read},
        };
        if (text.length >= muxDeltaMin) {
          _heldAnswer(q, d, d['result'] as Map<String, dynamic>, 'read', text.split('\n'), snapshot: false);
        }
      default:
        meter.count('other_requests');
        d = {
          'id': id,
          'result': {'type': 'ok'},
        };
    }
    return jsonEncode(d);
  }

  /// The last [lines] rows of a pane's screen: row N reads the same on every
  /// read, so a screen that scrolled by k rows is a delta of k rows.
  String _screen(String pane, int lines) {
    final base = _scroll[pane] ?? 0;
    final seed = pane.codeUnits.fold<int>(7, (h, c) => h * 31 + c);
    return [
      for (var i = 0; i < lines; i++)
        () {
          final n = base + i;
          final r = math.Random(seed ^ (n * 7919));
          return 'row $n: ${List.generate(10, (_) => 'w${r.nextInt(9000)}').join(' ')}';
        }(),
    ].join('\n');
  }

  void _heldAnswer(
    Map<String, dynamic> q,
    Map<String, dynamic> d,
    Map<String, dynamic> result,
    String boxKey,
    List<String> rows, {
    required bool snapshot,
  }) {
    final key = jsonEncode([q['method'], q['params']]);
    final have = q['mux_have'];
    final old = _held.remove(key);
    final seq = ++_seq;
    _held[key] = _Held(seq, rows);
    d['seq'] = seq;
    final n = rows.fold<int>(0, (a, r) => a + r.length + 1);
    Map<String, dynamic>? body;
    if (old != null && old.seq == have) {
      final o = _ops(old.rows, rows);
      final literal = o.fold<int>(
        0,
        (a, e) => a + (e[0] is String ? e.fold<int>(0, (b, l) => b + (l as String).length) : 0),
      );
      if (literal * 2 < n) body = {'base': have, 'o': o};
    }
    if (snapshot) {
      result[boxKey] = body != null ? {'delta': body} : {'rows': rows};
    } else if (body != null) {
      (result[boxKey] as Map<String, dynamic>)
        ..remove('text')
        ..['delta'] = body;
    }
  }

  /// Run of old rows kept `[start, count]`, new rows as a list; head and tail
  /// only (the script's difflib finds more, so a delta here is never smaller).
  static List<List<Object>> _ops(List<String> o, List<String> n) {
    var p = 0;
    final m = math.min(o.length, n.length);
    while (p < m && o[p] == n[p]) {
      p++;
    }
    var q = 0;
    while (q < m - p && o[o.length - 1 - q] == n[n.length - 1 - q]) {
      q++;
    }
    return [
      if (p > 0) [0, p],
      if (n.length - p - q > 0) n.sublist(p, n.length - q),
      if (q > 0) [o.length - q, q],
    ];
  }

  // -- the link ---------------------------------------------------------------

  _Link ensureLink() {
    final l = link;
    if (l != null && !l.closed) return l;
    return link = _Link(this);
  }

  /// The host went away (or its network): every channel ends at once.
  void dropLinks() => link?.close();
}

class _Link {
  _Link(this.host) {
    client = _Client(this);
  }

  final _Host host;
  late final _Client client;
  void Function()? onInbound;
  bool closed = false;
  final _sessions = <_ServeSession>[];
  final done = Completer<void>();

  void inbound() => onInbound?.call();

  void close() {
    if (closed) return;
    closed = true;
    if (identical(host.link, this)) host.link = null;
    if (!done.isCompleted) done.complete();
    for (final s in [..._sessions]) {
      s.finish();
    }
  }
}

class _Client implements SSHClient {
  _Client(this.link);
  final _Link link;

  @override
  bool get isClosed => link.closed;

  @override
  Future<void> get done => link.done.future;

  @override
  Future<void> ping() async {
    if (link.closed) throw StateError('closed');
    link.host.meter
      ..count('link_pings')
      ..add(32, up: true);
    await _later(rtt);
    if (link.closed) throw StateError('closed');
    link.host.meter.add(32, up: false);
    link.inbound();
  }

  @override
  Future<SSHSession> execute(
    String command, {
    SSHPtyConfig? pty,
    SSHX11Config? x11,
    Map<String, String>? environment,
  }) async {
    if (link.closed) throw StateError('closed');
    // The app opens one channel per connection, for the helper's `serve`.
    if (command != hostServeCommand()) throw StateError('unexpected command: $command');
    link.host.meter
      ..count('channels')
      ..add(120, up: true);
    await _later(rtt);
    if (link.closed) throw StateError('closed');
    link.host.meter.add(100, up: false);
    link.inbound();
    return _ServeSession(link);
  }

  @override
  Future<void> close() async => link.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The host end of the machine's one `herdr-host serve` channel: it decodes the
/// frames the app writes and answers as the real helper would (the wire is
/// `hostwire/1`, see `wire.dart`), so every frame crosses the meter at the size
/// it has on the wire, compression included.
///
///  * `herdr.events` (opened with zctx): the ack, then every event the app
///    subscribed to, as pieces of one continuous zlib stream;
///  * `herdr.mux` (zctx): `{"ready":true}`, then one MSG per request, answered
///    by [_Host.serve];
///  * `keeper.list`: one MSG and END; no agent session runs, so the answer is
///    empty and what is measured is the asking.
///
/// Every answer reaches the app a round trip after its request, an event as
/// it happens.
class _ServeSession implements SSHSession {
  _ServeSession(this.link) {
    link._sessions.add(this);
    _stdin.stream.listen(_onStdin);
  }

  final _Link link;
  // A cancel that completes inside the fake clock, as FakeTransport does: the
  // stock one answers with a future of the root zone, which fakeAsync never runs.
  final _out = StreamController<Uint8List>(onCancel: () => Future<void>.value());
  final _err = StreamController<Uint8List>(onCancel: () => Future<void>.value());
  final _stdin = StreamController<Uint8List>();
  final _done = Completer<void>();
  final _decoder = FrameDecoder(expectMagic: false);
  final _streams = <int, _HostStream>{};
  var _closed = false;

  Meter get _meter => link.host.meter;

  void _onStdin(Uint8List bytes) {
    _meter.add(bytes.length, up: true);
    _decoder.add(bytes, _onFrame);
  }

  void _onFrame(Frame f) {
    switch (f.kind) {
      case FrameKind.hello:
        // The magic and the host's HELLO, a round trip after ours.
        unawaited(
          _later(rtt).then((_) {
            final hello = Frame.json(FrameKind.hello, 0, {
              'proto': 1,
              'host': {
                'version': '9.9.9',
                'os': 'linux',
                'arch': 'x86_64',
                'home': '/home/u',
                'hostname': 'box',
                'user': 'u',
              },
              'limits': {'max_msg': maxPayload, 'max_data': maxData, 'window': 1 << 20, 'max_streams': 64},
              'services': {
                'herdr': {'available': true, 'reason': null},
                'keeper': {'available': true, 'reason': null},
              },
            });
            _write([...hostMagic, ...encodeFrame(hello)]);
          }),
        );
      case FrameKind.open:
        final o = (jsonDecode(utf8.decode(f.payload)) as Map).cast<String, dynamic>();
        final s = _streams[f.stream] = _HostStream(this, f.stream, zctx: o['zctx'] == true);
        s.open('${o['svc']}.${o['method']}', (o['args'] as Map?)?.cast<String, dynamic>() ?? const {});
      case FrameKind.msg:
        _streams[f.stream]?.onMessage(utf8.decode(_plain(f)));
      case FrameKind.reset:
        _streams.remove(f.stream)?.close();
      case FrameKind.data || FrameKind.credit || FrameKind.end:
        break;
    }
  }

  /// What the client's payload on [f]'s stream says, inflated.
  Uint8List _plain(Frame f) => switch (f.flags) {
    FrameFlags.none => f.payload,
    FrameFlags.deflate => Inflater.once(f.payload),
    FrameFlags.deflateCtx => _streams[f.stream]!.inflater.inflate(f.payload),
  };

  void _write(List<int> bytes) {
    if (_closed) return;
    _meter.add(bytes.length, up: false);
    link.inbound();
    _out.add(Uint8List.fromList(bytes));
  }

  void _send(Frame f) => _write(encodeFrame(f));

  void finish() {
    if (_closed) return;
    _closed = true;
    for (final s in _streams.values) {
      s.close();
    }
    _streams.clear();
    link._sessions.remove(this);
    unawaited(_out.close());
    unawaited(_err.close());
    unawaited(_stdin.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  StreamSink<Uint8List> get stdin => _stdin.sink;
  @override
  Stream<Uint8List> get stdout => _out.stream;
  @override
  Stream<Uint8List> get stderr => _err.stream;
  @override
  int? get exitCode => null;
  @override
  Future<void> get done => _done.future;
  @override
  void close() => finish();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One stream of the channel, host side. On a zctx stream every MSG of 64
/// bytes or more is the next piece of the stream's one zlib stream (the real
/// helper's rule, `CTX_MIN` in `rust/crates/host/src/session.rs`).
class _HostStream {
  _HostStream(this.session, this.id, {required this.zctx});

  final _ServeSession session;
  final int id;
  final bool zctx;
  final inflater = Inflater();
  final _deflater = RawZLibFilter.deflateFilter(level: 6);
  _Sub? _sub;
  var _closed = false;

  _Host get _host => session.link.host;

  void _msg(String text) {
    if (_closed) return;
    final plain = Uint8List.fromList(utf8.encode(text));
    if (!zctx || plain.length < 64) {
      session._send(Frame(FrameKind.msg, id, plain));
      return;
    }
    _deflater.process(plain, 0, plain.length);
    final piece = BytesBuilder(copy: false);
    while (true) {
      final chunk = _deflater.processed(flush: true);
      if (chunk == null || chunk.isEmpty) break;
      piece.add(chunk);
    }
    session._send(Frame(FrameKind.msg, id, piece.takeBytes(), flags: FrameFlags.deflateCtx));
  }

  void _end([Object? result]) {
    if (_closed) return;
    session._send(Frame.json(FrameKind.end, id, result ?? const {}));
  }

  void open(String method, Map<String, dynamic> args) {
    switch (method) {
      case 'herdr.mux':
        unawaited(_later(rtt).then((_) => _msg(muxReadyLine)));
      case 'herdr.events':
        _subscribe(args);
      case 'keeper.list':
        _host.meter.count('keeper_lists');
        unawaited(
          _later(rtt).then((_) {
            _msg('[]');
            _end();
          }),
        );
      default:
        _end({
          'error': {'code': 'unknown_method', 'message': method, 'retryable': false},
        });
    }
  }

  void _subscribe(Map<String, dynamic> args) {
    _host.meter.count('subscriptions');
    final types = (args['subscriptions'] as List).cast<Map<String, dynamic>>();
    // herdr rejects the whole subscription for one pane it does not have.
    for (final t in types) {
      final pane = t['pane_id'];
      if (pane != null && !_host.hasPane(pane as String)) {
        _msg(
          jsonEncode({
            'id': 'events',
            'error': {'code': 'pane_not_found', 'message': 'no pane $pane'},
          }),
        );
        return;
      }
    }
    // Each event is cut down to the fields the app asked for (the stream's
    // `projection`), as the helper does before it writes.
    final projection = args['projection'];
    final sub = _sub = _Sub(types, (line) => _msg(jsonEncode(_prune(jsonDecode(line), projection))));
    unawaited(
      _later(rtt).then((_) {
        if (_closed) return;
        _msg(
          jsonEncode({
            'id': 'events',
            'result': {'type': 'subscription_started'},
          }),
        );
        _host.subs.add(sub);
      }),
    );
  }

  /// A request on the mux stream.
  void onMessage(String text) {
    final q = jsonDecode(text) as Map<String, dynamic>;
    final answer = _host.serve(q);
    unawaited(_later(rtt).then((_) => _msg(answer)));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_sub != null) _host.subs.remove(_sub);
  }
}

/// [v] cut down to [spec]: `true` keeps a value whole, a map keeps its keys
/// (of each element, for a list). The shape `eventProjection` and the mux's
/// projections have.
Object? _prune(Object? v, Object? spec) {
  if (spec == true || spec == null) return v;
  if (v is List) return [for (final x in v) _prune(x, spec)];
  if (v is Map && spec is Map) {
    return {
      for (final e in spec.entries)
        if (v.containsKey(e.key)) e.key: _prune(v[e.key], e.value),
    };
  }
  return v;
}

/// Records when each notification was posted.
class _TimedNotifier extends FakeNotifier {
  _TimedNotifier(this._now);

  final Duration Function() _now;
  final posted = <({int id, int ms})>[];

  @override
  Future<void> show(AgentNotification notification) {
    posted.add((id: notification.id, ms: _now().inMilliseconds));
    return super.show(notification);
  }
}

// ----------------------------------------------------------------------------
// The rig: the app's pieces over `_Host`s

class _Rig {
  _Rig(this.async, {required bool notifications}) {
    _base = Zone.current;
    meter = Meter(() => async.elapsed);
    notifier = _TimedNotifier(() => async.elapsed);
    // Timer wake-ups of the app's code: what the CPU is woken for. The
    // scenario's own timers are made outside this zone and not counted.
    zone = Zone.current.fork(
      specification: ZoneSpecification(
        createTimer: (self, parent, z, d, f) {
          final site = counting ? _site() : '';
          return parent.createTimer(z, d, () {
            if (counting) _fired(site);
            f();
          });
        },
        createPeriodicTimer: (self, parent, z, d, f) {
          final site = counting ? _site() : '';
          return parent.createPeriodicTimer(z, d, (t) {
            if (counting) _fired(site);
            f(t);
          });
        },
      ),
    );
    hosts['a'] = _Host(
      'a',
      meter,
      () => async.elapsed,
      {'p1': 'working', 'p2': 'working', 'p3': 'working', 'p4': 'working', 'p5': 'idle'},
      shells: {'p6'},
    );
    hosts['b'] = _Host('b', meter, () => async.elapsed, {
      'q1': 'working',
      'q2': 'working',
      'q3': 'working',
      'q4': 'idle',
    });
    zone.run(() {
      final repository = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      fleet = FleetRepository(
        machines: repository,
        network: network,
        clock: wall,
        connect: (profile, secrets) =>
            MachineConnection(profile: profile, api: HerdrApi(_transport(profile)), clock: wall),
      );
      for (final (id, label) in [('a', 'Alpha'), ('b', 'Bravo')]) {
        repository.save(
          MachineProfile(id: id, label: label, host: '$id.local', username: 'u'),
          secrets: const MachineSecrets(password: 'x'),
        );
      }
      previews = PanePreviews(changes: fleet, connection: fleet.connection, clock: wall);
      final settings = NotificationSettings(
        MemoryNotificationStore(NotificationChoice(enabled: notifications, alsoDone: false)),
      )..load();
      sessions = AgentSessionRepository(
        fleet: fleet,
        hostFor: (machine) => SshAgentHost(machine.api.transport),
        clock: wall,
      );
      attention = AttentionNotifier(
        fleet: fleet,
        sessions: sessions,
        attention: AttentionSet(fleet: fleet, sessions: sessions),
        settings: settings,
        notifier: notifier,
        clock: wall,
      );
    });
    async.flushMicrotasks();
  }

  final FakeAsync async;
  final network = FakeNetwork();
  final hosts = <String, _Host>{};
  late final Meter meter;
  late final _TimedNotifier notifier;
  late final Zone zone;
  late final FleetRepository fleet;
  late final PanePreviews previews;
  late final AgentSessionRepository sessions;
  late final AttentionNotifier attention;
  final handles = <PreviewHandle>[];
  var counting = false;
  var timerFires = 0;

  /// Timer wake-ups by the line of the app that made the timer.
  final timerSites = <String, int>{};

  void _fired(String site) {
    timerFires++;
    timerSites[site] = (timerSites[site] ?? 0) + 1;
  }

  /// The first frame of the app's own code (not the rig) in the stack.
  static String _site() {
    for (final line in StackTrace.current.toString().split('\n')) {
      final at = line.indexOf('package:herdr_mobile/');
      if (at >= 0) return line.substring(at + 'package:herdr_mobile/'.length).replaceAll(')', '').trim();
    }
    return 'other';
  }

  SshTransport _transport(MachineProfile profile) {
    final host = hosts[profile.id]!;
    return SshTransport(
      profile: profile,
      secrets: const MachineSecrets(password: 'x'),
      onPinHostKey: (_) {},
      connectClient: (onInbound) async {
        if (host.down) {
          host.meter.add(60, up: true); // the SYN that gets no answer
          await _later(rtt);
          throw const HerdrTransportException('Cannot connect: host unreachable');
        }
        var link = host.link;
        if (link == null || link.closed) {
          // TCP + SSH handshake: ~3 round trips, a few KB of keys and
          // certificates.
          host.meter
            ..count('connects')
            ..add(2600, up: true);
          await _later(rtt * 3);
          host.meter.add(3200, up: false);
          link = host.ensureLink();
        }
        link.onInbound = onInbound;
        return link.client;
      },
      livenessClock: () => async.elapsed,
    );
  }

  Duration get now => async.elapsed;

  /// The app's clock. `DateTime.now()` is the machine's, which `fakeAsync`
  /// does not move: every clock the app takes is given this one.
  DateTime wall() => DateTime.utc(2026, 1, 1, 12).add(async.elapsed);

  /// Moves the clock in steps of at most [step], letting the root zone's
  /// microtasks run in between. A subscription cancelled after its stream
  /// ended answers with a future of the root zone; `fakeAsync` never runs
  /// those, so the code awaiting one would hang in the bench for ever (a
  /// connection whose event stream failed would stay `online`).
  Future<void> elapse(Duration d, {Duration step = const Duration(seconds: 1)}) async {
    var left = d;
    while (left > Duration.zero) {
      final s = left < step ? left : step;
      async.elapse(s);
      left -= s;
      for (var i = 0; i < 4; i++) {
        await Future<void>.value();
      }
      async.flushMicrotasks();
    }
  }

  /// A timer of the scenario, outside the zone whose timers are the app's.
  Timer at(Duration d, void Function() f) => async.run((_) => Timer(d, f));

  Timer every(Duration d, void Function() f) => async.run((_) => Timer.periodic(d, (_) => f()));

  static _Rig start(FakeAsync async, {required bool notifications}) =>
      async.run((_) => _Rig(async, notifications: notifications));

  void life(AppLifecycleState state) {
    zone.run(() {
      fleet.onLifecycleState(state);
      previews.onLifecycleState(state);
      sessions.onLifecycleState(state);
      attention.onLifecycleState(state);
    });
    async.flushMicrotasks();
  }

  /// Opens a preview of every agent card, as the board does.
  void openBoard() {
    zone.run(() {
      sessions.setBoardVisible(true);
      for (final h in hosts.values) {
        for (final pane in h.statuses.keys) {
          handles.add(previews.watch(h.id, pane));
        }
      }
    });
  }

  /// What the Agents board tells the pane tails while it is in front: the
  /// agents that wait on the person, in board order.
  void engageTails() {
    zone.run(() {
      previews.tails.board(
        inFront: true,
        targets: [
          for (final c in fleet.connections)
            for (final p in c.snapshot.panes)
              if (p.status == AgentStatus.blocked) (machine: c, paneId: p.id),
        ],
      );
    });
    async.flushMicrotasks();
  }

  /// Another screen covers the board.
  void coverTails() {
    zone.run(() => previews.tails.board(inFront: false));
    async.flushMicrotasks();
  }

  /// Every machine shows what herdr says.
  bool get fresh => hosts.values.every((h) {
    final c = fleet.connection(h.id);
    if (c == null || !c.isLive) return false;
    final shown = {
      for (final p in c.snapshot.panes)
        if (p.agent != null) p.id: p.status.name,
    };
    return shown.length == h.statuses.length && h.statuses.entries.every((e) => shown[e.key] == e.value);
  });

  /// Time until [fresh], stepping 100 ms; null if it never was within 2 min.
  Future<Duration?> untilFresh() async {
    final start = now;
    while (now - start < const Duration(minutes: 2)) {
      if (fresh) return now - start;
      await elapse(const Duration(milliseconds: 100));
    }
    return fresh ? now - start : null;
  }

  void dispose() {
    zone.run(() {
      for (final h in handles) {
        h.release();
      }
      unawaited(attention.dispose());
      sessions.dispose();
      previews.dispose();
      fleet.dispose();
    });
    async.flushMicrotasks();
  }
}

// ----------------------------------------------------------------------------
// The scenario

class _Episode {
  _Episode(this.host, this.pane, this.startS, this.endS);
  final String host;
  final String pane;
  final int startS;
  final int endS;
}

final _out = <String>[];
final _failures = <String>[];

void _metric(String name, num value) => _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

void _kb(String name, num bytes) => _metric(name, bytes / 1024);

double _p95(List<double> sorted) =>
    sorted.isEmpty ? 0 : sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];

/// Panes that block for six minutes at seeded moments. None while a machine is
/// legitimately out of reach (an outage, a handover and the retry that follows
/// it): an agent that blocks there is announced late for reasons that are not
/// the app's to fix.
List<_Episode> _episodes(_Rig r, Duration watchFor, List<(String, int, int)> outages) {
  final rng = math.Random(20261006);
  final episodes = <_Episode>[];
  for (final id in ['a', 'b']) {
    final panes = r.hosts[id]!.statuses.entries.where((e) => e.value == 'working').map((e) => e.key).toList();
    var t = 6 * 60 + rng.nextInt(240);
    while (t < watchFor.inSeconds - 12 * 60) {
      final pane = panes[rng.nextInt(panes.length)];
      final end = t + 6 * 60;
      final out = outages.any((o) => (o.$1 == id || o.$1 == '*') && t < o.$3 + 10 * 60 && end > o.$2 - 10 * 60);
      // Not right after the same pane's last one: an agent announced less than
      // a minute ago is not announced again (`notifyFlapWindow`).
      final flaps = episodes.any((e) => e.host == id && e.pane == pane && e.endS + 90 > t);
      if (!out && !flaps) {
        episodes.add(_Episode(id, pane, t, end));
      }
      t += (6 + rng.nextInt(9)) * 60;
    }
  }
  return episodes;
}

/// The app leaves for [watchFor] with notifications on, and what that costs is
/// written as `<prefix>_*` metrics. With [turbulent] the world misbehaves: a
/// handover, a pane that appears and one that closes, a machine that is down.
Future<void> _watch({required String prefix, required Duration watchFor, required bool turbulent}) async {
  {
    final async = FakeAsync(initialTime: DateTime.utc(2026, 1, 1, 12));
    final r = _Rig.start(async, notifications: true);
    final meter = r.meter;

    // The scenario's own timers live in the fakeAsync zone, outside the app's.
    r.every(const Duration(milliseconds: 100), () {
      for (final h in r.hosts.values) {
        h.churn();
      }
    });

    // -- in front -------------------------------------------------------------
    r.openBoard();
    await r.elapse(const Duration(seconds: 5));
    if (!r.fresh) _failures.add('$prefix: not fresh after connecting');
    if (turbulent) {
      final from = r.now.inMilliseconds;
      await r.elapse(const Duration(minutes: 3));
      final fg = meter.window(from, r.now.inMilliseconds);
      _kb('fg_kb_per_min', fg.bytes / 3);
      _metric('fg_packets_per_min', fg.packets / 3);
    } else {
      await r.elapse(const Duration(minutes: 1));
    }

    // -- the world while the app is away ----------------------------------------
    final awayS = r.now.inSeconds;
    final away = r.now;
    const handoverAt = 40 * 60, outageFrom = 70 * 60, outageTo = 85 * 60;
    final episodes = _episodes(r, watchFor, [
      if (turbulent) ('*', handoverAt, handoverAt + 5),
      if (turbulent) ('b', outageFrom, outageTo),
    ]);
    for (final e in episodes) {
      r.at(Duration(seconds: e.startS), () => r.hosts[e.host]!.setStatus(e.pane, 'blocked'));
      r.at(Duration(seconds: e.endS), () => r.hosts[e.host]!.setStatus(e.pane, 'working'));
    }
    // (machine, from, to) in seconds away: where a machine may rightly be down.
    final excused = <(String, int, int)>[];
    if (turbulent) {
      // A handover: no network for 5 s; the retry may wait out a backoff.
      excused.add(('*', handoverAt, handoverAt + 5 + 60));
      r.at(Duration(seconds: handoverAt), () {
        // The old address is gone: what was connected from it is black-holed.
        r.network.goOffline();
        for (final h in r.hosts.values) {
          h.dropLinks();
        }
        r.at(const Duration(seconds: 5), () => r.network.goOnline('mobile'));
      });
      r.at(Duration(seconds: 55 * 60), () => r.hosts['a']!.addAgent('p9', 'idle'));
      r.at(Duration(seconds: 56 * 60), () => r.hosts['a']!.setStatus('p9', 'working'));
      r.at(Duration(seconds: 95 * 60), () => r.hosts['b']!.closePane('q4'));
      // Down for 15 min; the background backoff is 5 min at most.
      excused.add(('b', outageFrom, outageTo + 6 * 60));
      r.at(Duration(seconds: outageFrom), () {
        r.hosts['b']!
          ..down = true
          ..dropLinks();
      });
      r.at(Duration(seconds: outageTo), () => r.hosts['b']!.down = false);
    }
    // Is every machine that can be reached watched? Sampled every 10 s.
    var samples = 0, unwatched = 0;
    r.every(const Duration(seconds: 10), () {
      final t = r.now.inSeconds - awayS;
      if (t < 0) return;
      for (final h in r.hosts.values) {
        if (excused.any((x) => (x.$1 == h.id || x.$1 == '*') && t >= x.$2 && t < x.$3)) continue;
        samples++;
        if (!(r.fleet.connection(h.id)?.isLive ?? false)) unwatched++;
      }
    });
    final trace = Platform.environment['BENCH_TRACE'] != null;

    // -- away -----------------------------------------------------------------
    r.counting = true;
    r.life(AppLifecycleState.paused);
    for (var m = 0; m < watchFor.inMinutes; m += 5) {
      await r.elapse(const Duration(minutes: 5));
      if (trace) {
        // ignore: avoid_print
        print(
          'TRACE $prefix +${m + 5}m ${r.fleet.connections.map((c) => c.state.name).join(',')} '
          'subs=${r.hosts.values.map((h) => h.subs.map((s) => s.types.length).toList()).join(' ')} '
          '${meter.counts}',
        );
      }
    }
    r.counting = false;
    final back = r.now;
    final hours = watchFor.inMinutes / 60;
    final bg = meter.window(away.inMilliseconds, back.inMilliseconds);
    _metric('${prefix}_radio_cost_s_per_h', bg.costS / hours);
    _metric('${prefix}_radio_active_s_per_h', bg.activeS / hours);
    _metric('${prefix}_wakeups_per_h', bg.wakeups / hours);
    _kb('${prefix}_wire_kb_per_h', bg.bytes / hours);
    _metric('${prefix}_packets_per_h', bg.packets / hours);
    _metric('${prefix}_timer_fires_per_h', r.timerFires / hours);
    final unwatchedFrac = samples == 0 ? 1.0 : unwatched / samples;
    _metric('${prefix}_unwatched_frac', unwatchedFrac);

    // Every agent that blocked for six minutes must have been announced.
    final latencies = <double>[];
    var missed = 0;
    for (final e in episodes) {
      final id = notificationIdFor('${e.host}/${e.pane}');
      final from = (awayS + e.startS) * 1000;
      final shown = r.notifier.posted.where((p) => p.id == id && p.ms >= from && p.ms < (awayS + e.endS) * 1000);
      if (shown.isEmpty) {
        missed++;
        if (trace) {
          // ignore: avoid_print
          print('TRACE $prefix missed ${e.host}/${e.pane}@${e.startS}');
        }
      } else {
        latencies.add((shown.first.ms - from) / 1000);
      }
    }
    if (trace) {
      // ignore: avoid_print
      print(
        'TRACE $prefix episodes ${[for (final e in episodes) '${e.host}/${e.pane}@${e.startS}']} '
        'latencies $latencies',
      );
    }
    latencies.sort();
    _metric('${prefix}_attention_episodes', episodes.length);
    _metric('${prefix}_attention_missed', missed);
    _metric('${prefix}_attention_latency_p95_s', _p95(latencies));
    _metric('${prefix}_attention_latency_max_s', latencies.isEmpty ? 0 : latencies.last);
    final missedFrac = episodes.isEmpty ? 0.0 : missed / episodes.length;
    // What nobody watched is worth as much as a radio held up the whole hour.
    _metric('${prefix}_score_s_per_h', bg.costS / hours + 3600 * (unwatchedFrac + missedFrac));

    if (trace && !turbulent) {
      final from = away.inMilliseconds + 10 * 60 * 1000;
      // ignore: avoid_print
      print(
        'TRACE $prefix timeline 10..20 min away: '
        '${[for (final (ms, w) in meter.timeline)
          if (ms >= from && ms < from + 600000) '${((ms - from) / 1000).toStringAsFixed(1)}s:$w']}',
      );
    }

    final sites = r.timerSites.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    _out.add('# $prefix timer wake-ups per hour, by the line that made the timer:');
    for (final e in sites.take(10)) {
      _out.add('#   ${(e.value / hours).round().toString().padLeft(6)}  ${e.key}');
    }
    _out.add('# $prefix wire counts over the whole run: ${meter.counts}');

    // -- back in front --------------------------------------------------------
    if (turbulent) {
      final from = r.now.inMilliseconds;
      r.life(AppLifecycleState.resumed);
      final took = await r.untilFresh();
      await r.elapse(const Duration(seconds: 20));
      final resume = meter.window(from, r.now.inMilliseconds);
      _metric('resume_fresh_ms', took?.inMilliseconds ?? 120000);
      _kb('resume_kb', resume.bytes);
      if (took == null) _failures.add('$prefix: the board was not fresh 2 min after resuming');
    }
    r.dispose();
  }
}

/// Notifications off, the default: the app lets go 90 s after it left.
Future<void> _suspended() async {
  {
    final async = FakeAsync(initialTime: DateTime.utc(2026, 1, 1, 12));
    final r = _Rig.start(async, notifications: false);
    r.every(const Duration(milliseconds: 100), () {
      for (final h in r.hosts.values) {
        h.churn();
      }
    });
    r.openBoard();
    await r.elapse(const Duration(seconds: 30));
    final away = r.now;
    r.counting = true;
    r.life(AppLifecycleState.paused);
    // The 90 s grace, then the radio's tail.
    await r.elapse(const Duration(minutes: 2));
    final settled = r.now;
    await r.elapse(const Duration(hours: 1));
    r.counting = false;
    final idle = r.meter.window(settled.inMilliseconds, r.now.inMilliseconds);
    final leave = r.meter.window(away.inMilliseconds, settled.inMilliseconds);
    _kb('suspended_wire_kb_per_h', idle.bytes);
    _metric('suspended_radio_cost_s_per_h', idle.costS);
    _metric('suspended_timer_fires_per_h', r.timerFires);
    _metric('leave_radio_cost_s', leave.costS);
    final from = r.now.inMilliseconds;
    r.hosts['a']!.setStatus('p1', 'blocked');
    r.life(AppLifecycleState.resumed);
    final took = await r.untilFresh();
    await r.elapse(const Duration(seconds: 20));
    final resume = r.meter.window(from, r.now.inMilliseconds);
    _metric('cold_resume_fresh_ms', took?.inMilliseconds ?? 120000);
    _kb('cold_resume_kb', resume.bytes);
    if (took == null) _failures.add('suspended: the board was not fresh 2 min after resuming');
    r.dispose();
  }
}

/// Tapping an agent on the board: when the pane screen has text, and when that
/// text is live, counted from the tap (finger up, ~100 ms after it went down).
/// Three ways: as before (the screen reads when it opens), with the last tail
/// kept (the first frame has text, marked saved), and with the press as well
/// (the read starts while the finger is down). Written as `open_*` on the
/// model's link (`rtt`), not measured on a phone.
Future<void> _open() async {
  for (final way in ['before', 'kept', 'press']) {
    final async = FakeAsync(initialTime: DateTime.utc(2026, 1, 1, 12));
    final r = _Rig.start(async, notifications: false);
    r.openBoard();
    await r.elapse(const Duration(seconds: 5));
    final conn = r.fleet.connection('a')!;
    final tails = r.previews.tails;
    // The pane was open a while ago: its tail is in memory, and old.
    r.zone.run(() => unawaited(tails.read(conn, 'p1', ReadSource.recent, paneTailRows)));
    await r.elapse(const Duration(seconds: 12));
    final reads = r.meter.counts['pane_tail_reads'] ?? 0;

    r.zone.run(() {
      if (way == 'press') tails.warm(conn, 'p1', wrap: false);
    });
    await r.elapse(const Duration(milliseconds: 100), step: const Duration(milliseconds: 10));
    final tap = r.now;
    final vm = r.zone.run(
      () => PaneViewModel.forMachine(conn, 'p1', wrap: false, tails: way == 'before' ? null : tails),
    );
    final firstFrame = vm.text.isNotEmpty;
    var liveAt = Duration.zero;
    for (var i = 0; i < 300 && (vm.isSaved || vm.lastRead == null); i++) {
      await r.elapse(const Duration(milliseconds: 10), step: const Duration(milliseconds: 10));
    }
    liveAt = r.now - tap;
    _metric('open_${way}_first_frame_has_text', firstFrame ? 1 : 0);
    _metric('open_${way}_live_after_tap_ms', liveAt.inMilliseconds);
    _metric('open_${way}_tail_reads', (r.meter.counts['pane_tail_reads'] ?? 0) - reads);
    r.zone.run(vm.dispose);
    r.dispose();
  }
}

/// The board in front with two agents waiting on the person, with and without
/// the pane tails' warming of those two (`PaneTails.board`): what it costs the
/// radio, and that nothing is read once the board is covered or the app leaves.
/// Written as `warm_*`. The tail reads are the pane screen's 300 rows, which
/// the mux sends as a delta against the last read of the same pane.
Future<void> _warm() async {
  Future<({double kbPerMin, double readsPerMin, _Rig rig, FakeAsync async})> run({required bool warm}) async {
    final async = FakeAsync(initialTime: DateTime.utc(2026, 1, 1, 12));
    final r = _Rig.start(async, notifications: false);
    r.every(const Duration(milliseconds: 100), () {
      for (final h in r.hosts.values) {
        h.churn();
      }
    });
    r.hosts['a']!
      ..setStatus('p1', 'blocked')
      ..setStatus('p2', 'blocked');
    r.openBoard();
    await r.elapse(const Duration(seconds: 5));
    if (warm) r.engageTails();
    await r.elapse(const Duration(seconds: 5));
    final from = r.now.inMilliseconds;
    final readsFrom = r.meter.counts['pane_tail_reads'] ?? 0;
    await r.elapse(const Duration(minutes: 3));
    final window = r.meter.window(from, r.now.inMilliseconds);
    final reads = (r.meter.counts['pane_tail_reads'] ?? 0) - readsFrom;
    return (kbPerMin: window.bytes / 1024 / 3, readsPerMin: reads / 3, rig: r, async: async);
  }

  final off = await run(warm: false);
  off.rig.dispose();
  final on = await run(warm: true);
  final r = on.rig;
  _metric('warm_off_fg_kb_per_min', off.kbPerMin);
  _metric('warm_on_fg_kb_per_min', on.kbPerMin);
  _metric('warm_tail_reads_per_min', on.readsPerMin);
  _metric('warm_fg_kb_regression_pct', off.kbPerMin == 0 ? 0 : (on.kbPerMin - off.kbPerMin) / off.kbPerMin * 100);
  if (off.readsPerMin != 0) _failures.add('warm: tails were read with no board warming (${off.readsPerMin}/min)');

  // The board is covered by another screen: nothing is read.
  r.coverTails();
  var from = r.meter.counts['pane_tail_reads'] ?? 0;
  await r.elapse(const Duration(minutes: 2));
  final covered = (r.meter.counts['pane_tail_reads'] ?? 0) - from;
  _metric('warm_covered_tail_reads', covered);
  if (covered != 0) _failures.add('warm: $covered tail reads while the board was covered');

  // Back in front, then the app leaves: nothing is read in the background.
  r.engageTails();
  await r.elapse(const Duration(seconds: 5));
  from = r.meter.counts['pane_tail_reads'] ?? 0;
  r.life(AppLifecycleState.paused);
  await r.elapse(const Duration(minutes: 10));
  final away = (r.meter.counts['pane_tail_reads'] ?? 0) - from;
  _metric('warm_background_tail_reads', away);
  if (away != 0) _failures.add('warm: $away tail reads in the background');
  r.dispose();
}

/// The first board request on a machine nobody has talked to yet: the SSH
/// connection, the exec channel, then the helper's HELLO, `herdr.mux`, ready and
/// the answer. The app writes our HELLO, the mux OPEN and the request together,
/// so the three answers come one round trip after the channel is open instead
/// of three. Written as `cold_first_request_ms`: virtual milliseconds from the
/// call to the answer, on the model's link (`rtt`).
Future<void> _coldStart() async {
  final async = FakeAsync(initialTime: DateTime.utc(2026, 1, 1, 12));
  final r = _Rig.start(async, notifications: false);
  final transport = r.zone.run(
    () => r._transport(const MachineProfile(id: 'a', label: 'Alpha', host: 'a.local', username: 'u')),
  );
  final start = r.now;
  Duration? took;
  Object? failed;
  r.zone.run(() {
    transport
        .request('session.snapshot')
        .then<void>(
          (_) => took = r.now - start,
          onError: (Object e) {
            failed = e;
          },
        );
  });
  await r.elapse(const Duration(seconds: 30), step: const Duration(milliseconds: 10));
  if (took == null) _failures.add('cold start: the first request got no answer in 30 s ($failed)');
  _metric('cold_first_request_ms', took?.inMilliseconds ?? 30000);
  _metric('cold_rtt_ms', rtt.inMilliseconds);
  unawaited(transport.close());
  async.flushMicrotasks();
  r.dispose();
}

void main() {
  // The pane screen's view model observes the app lifecycle.
  TestWidgetsFlutterBinding.ensureInitialized();
  test('what watching agents costs the radio and the battery', () async {
    // The score is the turbulent run's; the steady run is its quiet baseline.
    await _watch(prefix: 'bg', watchFor: const Duration(hours: 2), turbulent: true);
    await _watch(prefix: 'steady', watchFor: const Duration(hours: 1), turbulent: false);
    await _suspended();
    await _warm();
    await _open();
    await _coldStart();

    final path = Platform.environment['BENCH_OUT'];
    if (path != null) File(path).writeAsStringSync('${_out.join('\n')}\n');
    // ignore: avoid_print
    print(_out.join('\n'));
    expect(_failures, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
