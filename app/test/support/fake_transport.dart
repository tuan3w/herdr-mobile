import 'dart:async';

import 'package:herdr_mobile/data/services/herdr_transport.dart';

/// Builds a `session.snapshot` payload.
Map<String, dynamic> snapshotJson({
  List<({String id, String label})> workspaces = const [
    (id: 'w1', label: 'main'),
  ],
  List<({String id, String ws, String? agent, String status})> panes = const [],
  String version = '9.9.9',
}) =>
    {
      'version': version,
      'workspaces': [
        for (final (i, w) in workspaces.indexed)
          {
            'workspace_id': w.id,
            'number': i + 1,
            'label': w.label,
            'focused': i == 0,
            'pane_count': panes.where((p) => p.ws == w.id).length,
            'tab_count': 1,
            'agent_status': 'idle',
          },
      ],
      'tabs': [
        for (final w in workspaces)
          {
            'tab_id': '${w.id}:t1',
            'workspace_id': w.id,
            'number': 1,
            'label': '1',
            'focused': false,
            'pane_count': panes.where((p) => p.ws == w.id).length,
            'agent_status': 'idle',
          },
      ],
      'panes': [
        for (final p in panes)
          {
            'pane_id': p.id,
            'workspace_id': p.ws,
            'tab_id': '${p.ws}:t1',
            'focused': false,
            'cwd': '/work/${p.ws}',
            'terminal_title_stripped': 'title ${p.id}',
            'agent_status': p.status,
            'revision': 1,
            if (p.agent != null) 'agent': p.agent,
          },
      ],
    };

/// Scriptable in-memory transport.
class FakeTransport implements HerdrTransport {
  FakeTransport([Map<String, dynamic>? snapshot])
      : snapshot = snapshot ?? snapshotJson();

  Map<String, dynamic> snapshot;

  /// When set, every request throws this until cleared.
  Object? failure;

  final List<(String, Map<String, dynamic>)> calls = [];
  final List<StreamController<Map<String, dynamic>>> _streams = [];
  bool closed = false;

  int get snapshotCalls => calls.where((c) => c.$1 == 'session.snapshot').length;
  int get subscriptions => _streams.length;

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    calls.add((method, params));
    if (failure != null) throw failure!;
    return switch (method) {
      'ping' => {'type': 'pong', 'version': (snapshot['version'] as String)},
      'session.snapshot' => {'type': 'session_snapshot', 'snapshot': snapshot},
      _ => {'type': 'ok'},
    };
  }

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    final c = StreamController<Map<String, dynamic>>();
    _streams.add(c);
    if (failure != null) {
      scheduleMicrotask(() {
        c.addError(failure!);
        c.close();
      });
    }
    return c.stream;
  }

  void emit([Map<String, dynamic> event = const {'event': 'pane_updated'}]) =>
      _streams.last.add(event);

  /// Simulates the event channel dropping.
  void dropEvents(Object error) {
    _streams.last
      ..addError(error)
      ..close();
  }

  int resets = 0;

  @override
  void reset() => resets++;

  @override
  Future<void> close() async => closed = true;
}

/// Polls until [test] is true (real time), failing after [timeout].
Future<void> eventually(
  bool Function() test, {
  Duration timeout = const Duration(seconds: 3),
  String reason = 'condition',
}) async {
  final end = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(end)) {
      throw StateError('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
