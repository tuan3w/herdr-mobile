import 'dart:async';
import 'dart:convert';

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
  final calls = <({String path, int? from, int? tailBytes})>[];

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
  Stream<LogBatch> follow(String path, {int? from, int? tailBytes}) {
    final index = streams.length;
    calls.add((path: path, from: from, tailBytes: tailBytes));
    final c = StreamController<LogBatch>(onCancel: () => cancelled.add(index));
    streams.add(c);
    final error = openError;
    if (error != null) {
      openError = null;
      scheduleMicrotask(() {
        c.addError(error);
        unawaited(c.close());
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
        LogBatch(lines.sublist(i, i + step > lines.length ? lines.length : i + step),
            _ends[(i + step > lines.length ? lines.length : i + step) - 1], head: i == at ? head : null),
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
/// `pane.send_input`/`pane.send_keys`, the last one repeating).
class ScreenTransport extends FakeTransport {
  ScreenTransport(super.snapshot);

  String screen = '';

  /// When set, the screen is what this says, read at every `pane.read` (a model
  /// of a dialog that reacts to the keys), and [onInput] sees every
  /// `pane.send_input` and `pane.send_keys`.
  String Function()? liveScreen;
  void Function(Map<String, dynamic> params)? onInput;

  /// When set, the screen is `screens[min(sends, last)]`, `sends` counting
  /// the input and key requests so far.
  List<String>? screens;

  int get sends => calls.where((c) => c.$1 == 'pane.send_input' || c.$1 == 'pane.send_keys').length;

  /// Requests of [method], oldest first.
  List<Map<String, dynamic>> of(String method) => [
    for (final c in calls)
      if (c.$1 == method) c.$2,
  ];

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) {
    if (method == 'pane.send_input' || method == 'pane.send_keys') onInput?.call(params);
    if (method != 'pane.read') return super.request(method, params);
    calls.add((method, params));
    final list = screens;
    final text = liveScreen != null ? liveScreen!() : (list == null ? screen : list[sends < list.length ? sends : list.length - 1]);
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

  static Future<ObservedRig> create({String status = 'idle', String? log = ompLog, String agent = 'omp'}) async {
    final transport = ScreenTransport(ompSnapshot(status: status, log: log, agent: agent));
    final machine = MachineConnection(
      profile: omp,
      api: HerdrApi(transport),
      backoff: (_) => const Duration(milliseconds: 10),
      pollInterval: const Duration(hours: 1),
      structuralDelay: const Duration(milliseconds: 10),
      churnInterval: const Duration(milliseconds: 30),
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
