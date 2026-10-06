// Battery and network cost of watching agents, in virtual time, deterministic.
//
//   BENCH_OUT=/tmp/bg.txt flutter test benchmark/background_bench_test.dart
//
// The real stack from the fleet down to the SSH layer runs: `FleetRepository`,
// `MachineConnection`, `HerdrApi`, `SshTransport` (its link watch, mux
// heartbeat, event channel and reconnects), `MuxClient` (deltas included),
// `PanePreviews`, `AttentionNotifier`. Only the bottom is replaced: an in-memory
// SSH client, mux script and herdr (`_Host`), which meter every message that
// would cross the radio, and a `fakeAsync` clock. No sockets, no wall time: the
// same run gives the same numbers.
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
//
// `bg_score_s_per_h` is the one number to lower: the radio cost per hour (see
// the assumptions) plus an hour's worth of radio for every share of the time a
// reachable machine was not watched and every share of the blocked agents that
// were never announced. A watch that dies is not cheap, it is broken. Metrics
// named `fg_` are the board in front, `bg_` the turbulent watch, `steady_` the
// quiet one.
//
// What is metered, per message: payload bytes (the mux's real framing and
// deflate for requests; the mux script's delta + deflate protocol for
// answers, ported to Dart in `_Host.serve`) plus packet overhead.
//
// ASSUMPTIONS, not measurements (a phone's modem is not here; mark any number
// built on them as modelled):
//  * the radio stays in its high-power state for [radioTailS] after the last
//    packet either way (LTE RRC inactivity timer; 3G/5G vary), and waking it
//    from idle costs as much as [wakeCostS] more seconds of it;
//  * every packet carries [packetOverhead] bytes (TCP/IP + SSH MAC and length);
//    TCP ACKs and retransmits are not counted;
//  * a machine's herdr sends the events the app subscribed to and no others;
//    a status change is one `pane_agent_status_changed`, nothing else.
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
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/attention_notifier.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/bridge_command.dart'
    show muxCompressMin, muxDeltaMin, muxReadyLine;
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;
import 'package:herdr_mobile/data/services/mux_client.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart';

import '../test/support/fake_agent_session.dart';
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

/// The command the rig's mux opener runs to get the transport to connect.
const _probe = 'sim:connect';

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

  void count(String what) => counts[what] = (counts[what] ?? 0) + 1;

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
    return (
      bytes: bytes,
      packets: packets,
      activeS: activeS,
      wakeups: wakeups,
      costS: activeS + wakeups * wakeCostS,
    );
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
    _emit('pane.agent_status_changed', 'pane_agent_status_changed',
        {'pane_id': pane, 'agent_status': status},
        paneId: pane);
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

  // -- the mux script: delta + deflate, ported from `bridge_command.dart` -----

  /// The answer to [q] as the app's `MuxClient` receives it, and what it cost
  /// on the wire.
  (String, int) serve(Map<String, dynamic> q) {
    final method = q['method'] as String;
    final id = q['id'];
    final params = (q['params'] as Map?)?.cast<String, dynamic>() ?? const {};
    final Map<String, dynamic> d;
    switch (method) {
      case 'ping':
        meter.count('mux_heartbeats');
        d = {'id': id, 'result': {'type': 'pong', 'version': '9.9.9'}};
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
        final pane = params['pane_id'] as String;
        final text = _screen(pane, params['lines'] as int? ?? 24);
        final read = <String, dynamic>{'text': text, 'truncated': false};
        d = {'id': id, 'result': {'type': 'pane_read', 'read': read}};
        if (text.length >= muxDeltaMin) {
          _heldAnswer(q, d, d['result'] as Map<String, dynamic>, 'read', text.split('\n'), snapshot: false);
        }
      default:
        meter.count('other_requests');
        d = {'id': id, 'result': {'type': 'ok'}};
    }
    final json = jsonEncode(d);
    final raw = utf8.encode(json);
    final size = raw.length > muxCompressMin
        ? 'Z${zlib.encode(raw).length}\n'.length + zlib.encode(raw).length
        : raw.length + 1;
    return (json, size);
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
      final literal = o.fold<int>(0, (a, e) => a + (e[0] is String ? e.fold<int>(0, (b, l) => b + (l as String).length) : 0));
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
  final _sessions = <_EventSession>[];
  final _muxes = <_Mux>[];
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
    for (final m in [..._muxes]) {
      m.end();
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
    if (command == _probe) throw SSHChannelOpenError(1, 'probe');
    link.host.meter
      ..count('channels')
      ..add(120, up: true);
    await _later(rtt);
    if (link.closed) throw StateError('closed');
    link.host.meter.add(100, up: false);
    link.inbound();
    return _EventSession(link);
  }

  @override
  Future<void> close() async => link.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The events channel: the app writes one subscribe frame, herdr answers with
/// an ack and then sends what was subscribed to.
class _EventSession implements SSHSession {
  _EventSession(this.link) {
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
  _Sub? _sub;
  var _closed = false;

  Meter get _meter => link.host.meter;

  void _onStdin(Uint8List bytes) {
    _meter.add(bytes.length, up: true);
    for (final line in utf8.decode(bytes).split('\n')) {
      if (line.trim().isEmpty) continue;
      final q = jsonDecode(line) as Map<String, dynamic>;
      if (q['method'] != 'events.subscribe') continue;
      _meter.count('subscriptions');
      final types = ((q['params'] as Map)['subscriptions'] as List).cast<Map<String, dynamic>>();
      // herdr rejects the whole subscription for one pane it does not have.
      for (final t in types) {
        final pane = t['pane_id'];
        if (pane != null && !link.host.hasPane(pane as String)) {
          _write(jsonEncode({
            'id': q['id'],
            'error': {'code': 'pane_not_found', 'message': 'no pane $pane'},
          }));
          return;
        }
      }
      final sub = _sub = _Sub(types, _write);
      unawaited(_later(rtt).then((_) {
        if (_closed) return;
        _write(jsonEncode({'id': q['id'], 'result': {'type': 'subscription_started'}}));
        link.host.subs.add(sub);
      }));
    }
  }

  void _write(String line) {
    if (_closed) return;
    final bytes = utf8.encode('$line\n');
    _meter.add(bytes.length, up: false);
    link.inbound();
    _out.add(Uint8List.fromList(bytes));
  }

  void finish() {
    if (_closed) return;
    _closed = true;
    if (_sub != null) link.host.subs.remove(_sub);
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

class _Mux implements MuxChannel {
  _Mux(this.link) {
    link._muxes.add(this);
    _lines.add(muxReadyLine);
  }

  final _Link link;
  final _lines = StreamController<String>(onCancel: () => Future<void>.value());
  final _exit = Completer<int?>();
  final _encoder = MuxRequestEncoder();

  @override
  Stream<String> get lines => _lines.stream;

  @override
  void send(String line) {
    if (_lines.isClosed) throw StateError('channel closed');
    final meter = link.host.meter;
    meter.add(_encoder.frame(line).length, up: true);
    final q = jsonDecode(line) as Map<String, dynamic>;
    final (json, size) = link.host.serve(q);
    _base.createTimer(rtt, () {
      if (_lines.isClosed) return;
      meter.add(size, up: false);
      link.inbound();
      _lines.add(json);
    });
  }

  void end() {
    if (!_exit.isCompleted) _exit.complete(null);
    if (!_lines.isClosed) unawaited(_lines.close());
  }

  @override
  Future<void> close() async {
    link._muxes.remove(this);
    end();
  }

  @override
  Future<int?> get exitCode => _exit.future;
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
    hosts['b'] = _Host(
      'b',
      meter,
      () => async.elapsed,
      {'q1': 'working', 'q2': 'working', 'q3': 'working', 'q4': 'idle'},
    );
    zone.run(() {
      final repository = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      fleet = FleetRepository(
        machines: repository,
        network: network,
        clock: wall,
        connect: (profile, secrets) => MachineConnection(
          profile: profile,
          api: HerdrApi(_transport(profile)),
          clock: wall,
        ),
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
      final sessions = FakeAgentSessions([]);
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
    late final SshTransport transport;
    return transport = SshTransport(
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
      openMuxChannel: (_) async {
        // The real mux channel is opened on the SSH client, connecting it
        // first: do that through the transport, so it knows the client.
        try {
          await transport.openExec(_probe);
        } on HerdrTransportException catch (e) {
          // The probe is refused by design; what matters is the connection.
          final up = host.link;
          if (host.down || up == null || up.closed) throw MuxUnavailable(e.message, linkLost: true);
        }
        final link = host.ensureLink();
        host.meter
          ..count('channels')
          ..add(120, up: true);
        await _later(rtt);
        host.meter.add(100 + muxReadyLine.length, up: false);
        link.inbound();
        return _Mux(link);
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
      attention.onLifecycleState(state);
    });
    async.flushMicrotasks();
  }

  /// Opens a preview of every agent card, as the board does.
  void openBoard() {
    zone.run(() {
      for (final h in hosts.values) {
        for (final pane in h.statuses.keys) {
          handles.add(previews.watch(h.id, pane));
        }
      }
    });
  }

  /// Every machine shows what herdr says.
  bool get fresh => hosts.values.every((h) {
        final c = fleet.connection(h.id);
        if (c == null || !c.isLive) return false;
        final shown = {for (final p in c.snapshot.panes) if (p.agent != null) p.id: p.status.name};
        return shown.length == h.statuses.length &&
            h.statuses.entries.every((e) => shown[e.key] == e.value);
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

void _metric(String name, num value) =>
    _out.add('METRIC $name=${value is int ? value : value.toStringAsFixed(3)}');

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
Future<void> _watch({
  required String prefix,
  required Duration watchFor,
  required bool turbulent,
}) async {
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
        print('TRACE $prefix +${m + 5}m ${r.fleet.connections.map((c) => c.state.name).join(',')} '
            'subs=${r.hosts.values.map((h) => h.subs.map((s) => s.types.length).toList()).join(' ')} '
            '${meter.counts}');
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
      print('TRACE $prefix episodes ${[for (final e in episodes) '${e.host}/${e.pane}@${e.startS}']} '
          'latencies $latencies');
    }
    latencies.sort();
    _metric('${prefix}_attention_episodes', episodes.length);
    _metric('${prefix}_attention_missed', missed);
    _metric('${prefix}_attention_latency_p95_s', _p95(latencies));
    _metric('${prefix}_attention_latency_max_s', latencies.isEmpty ? 0 : latencies.last);
    final missedFrac = episodes.isEmpty ? 0.0 : missed / episodes.length;
    // What nobody watched is worth as much as a radio held up the whole hour.
    _metric('${prefix}_score_s_per_h', bg.costS / hours + 3600 * (unwatchedFrac + missedFrac));

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

void main() {
  test('what watching agents costs the radio and the battery', () async {
    // The score is the turbulent run's; the steady run is its quiet baseline.
    await _watch(prefix: 'bg', watchFor: const Duration(hours: 2), turbulent: true);
    await _watch(prefix: 'steady', watchFor: const Duration(hours: 1), turbulent: false);
    await _suspended();

    final path = Platform.environment['BENCH_OUT'];
    if (path != null) File(path).writeAsStringSync('${_out.join('\n')}\n');
    // ignore: avoid_print
    print(_out.join('\n'));
    expect(_failures, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
