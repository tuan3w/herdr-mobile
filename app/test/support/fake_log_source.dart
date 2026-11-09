import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'fake_transport.dart';

/// A session log "on the host": [push] appends lines the way the follower
/// delivers them, [drop] breaks the channel.
class FakeLogSource implements SessionLogSource {
  /// What each `follow` was asked, oldest first.
  final calls = <({String path, int? from, int? until, bool digest, int? tailBytes})>[];

  /// What a `follow` with `until` sends instead of the lines themselves, by the
  /// line's index in [lines] (the host's digest of it); a line not here goes
  /// out as it is.
  final digests = <int, String>{};

  /// Holds a `follow` with `until` until it completes: a read that takes a while.
  Completer<void>? untilGate;

  /// The stream of each `follow`, oldest first.
  final streams = <StreamController<LogBatch>>[];

  /// Indexes of the streams the session cancelled (it closed the channel).
  final cancelled = <int>[];

  /// Fails the next `follow` at once with this.
  Object? openError;

  /// A `follow` without `from` delivers nothing by itself: the test hands
  /// out the tail with [tailOf] when it wants to.
  bool holdTails = false;

  /// What the file holds: a `follow` without `from` starts with all of it.
  final lines = <String>[];
  final _ends = <int>[];
  var _end = 0;

  @override
  Stream<LogBatch> follow(String path, {int? from, int? until, bool digest = false, int? tailBytes}) {
    final index = streams.length;
    calls.add((path: path, from: from, until: until, digest: digest, tailBytes: tailBytes));
    final c = StreamController<LogBatch>(onCancel: () => cancelled.add(index));
    streams.add(c);
    final error = openError;
    if (error != null) {
      openError = null;
      scheduleMicrotask(() {
        c.addError(error);
        unawaited(c.close());
      });
    } else if (until != null) {
      var at = _ends.indexWhere((e) => e > (from ?? 0));
      if (at < 0) at = lines.length;
      var stop = at;
      // As the host: a line that starts before `until` is sent whole.
      while (stop < lines.length && (stop == 0 ? 0 : _ends[stop - 1]) < until) {
        stop++;
      }
      final sent = [for (var i = at; i < stop; i++) digest ? (digests[i] ?? lines[i]) : lines[i]];
      final end = stop == 0 ? 0 : _ends[stop - 1];
      final gate = untilGate;
      scheduleMicrotask(() async {
        if (gate != null) await gate.future;
        if (c.isClosed) return;
        if (sent.isNotEmpty) c.add(LogBatch(sent, end));
        c.add(LogBatch(const [], end, caughtUp: true));
        await c.close();
      });
    } else if (from == null && lines.isNotEmpty && !holdTails) {
      final tail = tailOf(tailBytes);
      scheduleMicrotask(() {
        for (final batch in tail) {
          c.add(batch);
        }
      });
    } else if (from != null) {
      final at = _ends.indexWhere((e) => e > from);
      final rest = at >= 0 ? lines.sublist(at) : const <String>[];
      final end = _end;
      scheduleMicrotask(() {
        if (rest.isNotEmpty) c.add(LogBatch(rest, end));
        c.add(LogBatch(const [], end, caughtUp: true));
      });
    }
    return c.stream;
  }

  /// What each `blob` was asked, oldest first.
  final blobCalls = <({String path, int start, String hash})>[];

  /// The pictures this host can send, by `<start>.<hash>`.
  final blobs = <String, Uint8List>{};

  /// Holds every `blob` until it completes (a slow link).
  Completer<void>? blobGate;

  /// Fails the next `blob` with this.
  Object? blobError;

  @override
  Future<Uint8List> blob(String path, {required int start, required String hash}) async {
    blobCalls.add((path: path, start: start, hash: hash));
    final gate = blobGate;
    if (gate != null) await gate.future;
    final error = blobError;
    if (error != null) {
      blobError = null;
      throw error;
    }
    return blobs['$start.$hash'] ?? (throw StateError('no picture $start.$hash scripted'));
  }

  StreamController<LogBatch> get last => streams.last;

  /// What a tail read of [tailBytes] (the host's 192 KB by default) sends:
  /// the lines from the first line start inside the window, then the
  /// caught-up note. [batchLines] splits the lines into batches of that many.
  List<LogBatch> tailOf(int? tailBytes, {int? batchLines}) {
    final want = _end - (tailBytes ?? 192 * 1024);
    var at = 0;
    while (at < lines.length && (at == 0 ? 0 : _ends[at - 1]) < want) {
      at++;
    }
    final head = at == 0 ? 0 : _ends[at - 1];
    final step = batchLines ?? lines.length;
    return [
      for (var i = at; i < lines.length; i += step)
        LogBatch(
          lines.sublist(i, i + step > lines.length ? lines.length : i + step),
          _ends[(i + step > lines.length ? lines.length : i + step) - 1],
          head: i == at ? head : null,
        ),
      LogBatch(const [], _end, caughtUp: true),
    ];
  }

  /// The channel of the latest `follow` is open.
  bool get open => streams.isNotEmpty && !cancelled.contains(streams.length - 1) && !last.isClosed;

  /// Appends [more] to the file and delivers them on the open channel.
  void push(List<String> more) {
    write(more);
    if (open) last.add(LogBatch(more, _end));
  }

  /// Puts [more] in the file without delivering them (they arrive with the
  /// next `follow`).
  void write(List<String> more) {
    for (final l in more) {
      lines.add(l);
      _end += utf8.encode(l).length + 1;
      _ends.add(_end);
    }
  }

  /// The file was replaced: what follows is its new content.
  void reset(List<String> content) {
    lines.clear();
    _ends.clear();
    _end = 0;
    write(content);
    if (open) {
      last
        ..add(LogBatch(const [], _end, reset: true))
        ..add(LogBatch(List.of(content), _end));
    }
  }

  /// The channel breaks.
  void drop([Object error = const HerdrTransportException('The link dropped.')]) {
    if (!open) return;
    last
      ..addError(error)
      ..close();
  }

  /// The offset after everything pushed so far.
  int get end => _end;
}

// -- log lines (hand-written, in the shape omp writes) ------------------------

const _stamp = '2026-10-04T10:00:00.000Z';

String sessionLine({String cwd = '/work/proj', String? title}) =>
    jsonEncode({'type': 'session', 'version': 3, 'id': 's1', 'timestamp': _stamp, 'cwd': cwd, 'title': ?title});

String userLine(String id, String text) => jsonEncode({
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': _stamp,
  'message': {
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'attribution': 'user',
    'timestamp': 1,
  },
});

String assistantLine(String id, String text) => jsonEncode({
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': _stamp,
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'text', 'text': text},
    ],
    'stopReason': 'stop',
    'timestamp': 2,
  },
});

/// An assistant message that starts tool call [callId] (`bash`, `ask`, ...).
String toolCallLine(String id, String callId, String name, Map<String, Object?> arguments) => jsonEncode({
  'type': 'message',
  'id': id,
  'parentId': null,
  'timestamp': _stamp,
  'message': {
    'role': 'assistant',
    'content': [
      {'type': 'toolCall', 'id': callId, 'name': name, 'arguments': arguments},
    ],
    'stopReason': 'toolUse',
    'timestamp': 2,
  },
});

String toolResultLine(String id, String callId, String name, String text, {Map<String, Object?>? details}) =>
    jsonEncode({
      'type': 'message',
      'id': id,
      'parentId': null,
      'timestamp': _stamp,
      'message': {
        'role': 'toolResult',
        'toolCallId': callId,
        'toolName': name,
        'content': [
          {'type': 'text', 'text': text},
        ],
        'details': ?details,
        'isError': false,
        'timestamp': 3,
      },
    });

// -- a machine with one omp pane ----------------------------------------------

/// `pane.read` answers the current [screen] (or the next of [screens] per
/// input request, the last one repeating). An input request is what types
/// into the pane: `pane.send_input`, `pane.send_keys`, and `agent.prompt`
/// (herdr types the message, then enter).
class ScreenTransport extends FakeTransport {
  ScreenTransport(super.snapshot);

  String screen = '';

  /// When set, the screen is what this says, read at every `pane.read` (a model
  /// of a dialog that reacts to the keys), and [onInput] sees every input
  /// request.
  String Function()? liveScreen;
  void Function(Map<String, dynamic> params)? onInput;

  /// When set, the screen is `screens[min(sends, last)]`, `sends` counting
  /// the input requests so far.
  List<String>? screens;

  static bool _isInput(String method) =>
      method == 'pane.send_input' || method == 'pane.send_keys' || method == 'agent.prompt';

  int get sends => calls.where((c) => _isInput(c.$1)).length;

  /// Requests of [method], oldest first.
  List<Map<String, dynamic>> of(String method) => [
    for (final c in calls)
      if (c.$1 == method) c.$2,
  ];

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) {
    if (_isInput(method)) onInput?.call(params);
    if (method != 'pane.read') return super.request(method, params);
    calls.add((method, params));
    final list = screens;
    final text = liveScreen != null
        ? liveScreen!()
        : (list == null ? screen : list[sends < list.length ? sends : list.length - 1]);
    return Future.value({
      'type': 'pane_read',
      'read': {'text': text, 'truncated': false},
    });
  }
}

const omp = MachineProfile(id: 'm', label: 'devbox', host: 'h', username: 'u');
const ompLog = '/home/u/.omp/agent/sessions/--work-proj--/2026-10-04T10-00-00_abc.jsonl';

/// A snapshot with one pane `w1:p1` running omp with `agent_session` = [log].
Map<String, dynamic> ompSnapshot({String status = 'idle', String? log = ompLog, String agent = 'omp'}) {
  final json = snapshotJson(panes: [(id: 'w1:p1', ws: 'w1', agent: agent, status: status)]);
  final pane = (json['panes'] as List).first as Map<String, dynamic>;
  if (log != null) pane['agent_session'] = {'agent': agent, 'kind': 'path', 'value': log};
  return json;
}

/// A live machine with the omp pane, ready for an `ObservedAgentSession`.
class ObservedRig {
  ObservedRig._(this.transport, this.machine, this.previews);

  final ScreenTransport transport;
  final MachineConnection machine;
  final PanePreviews previews;
  final source = FakeLogSource();

  static Future<ObservedRig> create({
    String status = 'idle',
    String? log = ompLog,
    String agent = 'omp',
    Map<String, bool Function(String screen)> screenWaits = const {},
  }) async {
    final transport = ScreenTransport(ompSnapshot(status: status, log: log, agent: agent));
    final machine = MachineConnection(
      profile: omp,
      api: HerdrApi(transport),
      backoff: (_) => const Duration(milliseconds: 10),
      pollInterval: const Duration(hours: 1),
      structuralDelay: const Duration(milliseconds: 10),
      churnInterval: const Duration(milliseconds: 30),
      screenWaits: screenWaits,
    )..start();
    await eventually(() => machine.isLive, reason: 'machine online');
    final previews = PanePreviews(
      changes: machine,
      connection: (_) => machine,
      minInterval: const Duration(milliseconds: 10),
      startGap: Duration.zero,
    );
    return ObservedRig._(transport, machine, previews);
  }

  Map<String, dynamic> get _pane => ((transport.snapshot['panes'] as List).first as Map<String, dynamic>);

  /// herdr now says the pane is [status] (`idle`, `working`, `blocked`, `done`).
  Future<void> setStatus(String status) async {
    _pane['agent_status'] = status;
    await machine.refresh();
  }

  /// The agent in the pane names another log.
  Future<void> setLog(String path) async {
    _pane['agent_session'] = {'agent': 'omp', 'kind': 'path', 'value': path};
    await machine.refresh();
  }

  /// The pane is gone from herdr.
  Future<void> removePane() async {
    (transport.snapshot['panes'] as List).clear();
    await machine.refresh();
  }

  /// Requests of [method] so far.
  List<Map<String, dynamic>> sent(String method) => transport.of(method);

  void dispose() {
    previews.dispose();
    machine.dispose();
  }
}
