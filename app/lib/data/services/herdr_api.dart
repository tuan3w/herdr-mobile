import '../models/herdr_models.dart';
import 'herdr_transport.dart';
import 'remote_files.dart';

enum ReadSource {
  visible('visible'),
  recent('recent'),
  recentUnwrapped('recent_unwrapped');

  const ReadSource(this.wire);
  final String wire;
}

enum SplitDirection {
  right('right'),
  down('down');

  const SplitDirection(this.wire);
  final String wire;
}

/// This herdr is too old for the request (an unknown method, or a parameter it
/// does not know). A [HerdrApiException], so existing handlers still catch it.
class HerdrUnsupportedException extends HerdrApiException {
  const HerdrUnsupportedException(this.method)
      : super('unsupported', 'herdr does not support $method');

  final String method;
}

extension HerdrApiExceptionX on HerdrApiException {
  /// The workspace, tab or pane is already gone (closed on the desktop in the
  /// meantime).
  bool get isNotFound => code.endsWith('_not_found');
}

/// Typed herdr socket API over any [HerdrTransport].
class HerdrApi {
  HerdrApi(this._transport);

  final HerdrTransport _transport;

  /// File access over the same connection (SFTP), for the file viewer.
  late final RemoteFiles files = RemoteFiles(_transport);

  Future<String> ping() async =>
      (await _transport.request('ping'))['version'] as String? ?? '';

  Future<Snapshot> snapshot() async {
    final r = await _transport.request('session.snapshot');
    return Snapshot.fromJson(r['snapshot'] as Map<String, dynamic>);
  }

  Future<PaneRead> readPane(
    String paneId, {
    ReadSource source = ReadSource.recent,
    int? lines,
    bool ansi = false,
  }) async {
    final r = await _transport.request('pane.read', {
      'pane_id': paneId,
      'source': source.wire,
      'lines': ?lines,
      if (ansi) 'format': 'ansi',
      'strip_ansi': !ansi,
    });
    return PaneRead.fromJson(r['read'] as Map<String, dynamic>);
  }

  /// Types [text] into the pane without pressing enter.
  Future<void> sendText(String paneId, String text) =>
      _transport.request('pane.send_text', {'pane_id': paneId, 'text': text});

  /// Sends herdr key-combo strings, e.g. `enter`, `esc`, `ctrl+c`.
  Future<void> sendKeys(String paneId, List<String> keys) =>
      _transport.request('pane.send_keys', {'pane_id': paneId, 'keys': keys});

  /// Types [text] then presses enter.
  Future<void> sendLine(String paneId, String text) =>
      _transport.request('pane.send_input', {
        'pane_id': paneId,
        'text': text,
        'keys': ['enter'],
      });

  /// Creates a workspace (with one tab and one pane) running a login shell in
  /// [cwd]. Never focuses it unless asked: [focus] moves the desktop user's
  /// view, which a phone has no business doing.
  ///
  /// `cwd` in the result is where the shell really started: herdr quietly
  /// falls back to the home directory when the folder does not exist.
  Future<({String workspaceId, String tabId, String rootPaneId, String? cwd})> createWorkspace({
    String? cwd,
    String? label,
    bool focus = false,
    Map<String, String> env = const {},
  }) async {
    final r = await _call('workspace.create', {
      'cwd': ?cwd,
      if (label != null && label.isNotEmpty) 'label': label,
      'focus': focus,
      if (env.isNotEmpty) 'env': env,
    });
    return (
      workspaceId: _id(r, 'workspace', 'workspace_id'),
      tabId: _id(r, 'tab', 'tab_id'),
      rootPaneId: _id(r, 'root_pane', 'pane_id'),
      cwd: switch (r['root_pane']) {
        {'cwd': final String cwd} => cwd,
        _ => null,
      },
    );
  }

  /// Adds a tab (with one pane) to [workspaceId].
  Future<({String tabId, String rootPaneId})> createTab({
    required String workspaceId,
    String? cwd,
    String? label,
    bool focus = false,
    Map<String, String> env = const {},
  }) async {
    final r = await _call('tab.create', {
      'workspace_id': workspaceId,
      'cwd': ?cwd,
      if (label != null && label.isNotEmpty) 'label': label,
      'focus': focus,
      if (env.isNotEmpty) 'env': env,
    });
    return (tabId: _id(r, 'tab', 'tab_id'), rootPaneId: _id(r, 'root_pane', 'pane_id'));
  }

  /// Splits [targetPaneId]; returns the new pane's id.
  Future<String> splitPane({
    required String targetPaneId,
    String? workspaceId,
    SplitDirection direction = SplitDirection.right,
    String? cwd,
    bool focus = false,
  }) async {
    final r = await _call('pane.split', {
      'direction': direction.wire,
      'target_pane_id': targetPaneId,
      'workspace_id': ?workspaceId,
      'cwd': ?cwd,
      'focus': focus,
    });
    return _id(r, 'pane', 'pane_id');
  }

  Future<void> closeWorkspace(String workspaceId) =>
      _call('workspace.close', {'workspace_id': workspaceId});

  Future<void> closeTab(String tabId) => _call('tab.close', {'tab_id': tabId});

  Future<void> closePane(String paneId) => _call('pane.close', {'pane_id': paneId});

  Future<void> renameWorkspace(String workspaceId, String label) =>
      _call('workspace.rename', {'workspace_id': workspaceId, 'label': label});

  Future<void> renameTab(String tabId, String label) =>
      _call('tab.rename', {'tab_id': tabId, 'label': label});

  /// An empty [label] clears the pane's name (herdr takes null for that).
  Future<void> renamePane(String paneId, String label) =>
      _call('pane.rename', {'pane_id': paneId, 'label': label.isEmpty ? null : label});

  /// Agent kinds herdr can detect on this machine (`claude`, `codex`, ...).
  /// Empty when this herdr predates `server.agent_manifests`.
  Future<List<String>> agentManifests() async {
    final Map<String, dynamic> r;
    try {
      r = await _call('server.agent_manifests', const {});
    } on HerdrUnsupportedException {
      return const [];
    }
    return [
      for (final m in (r['manifests'] as List?) ?? const [])
        if (m is Map && m['agent'] is String && (m['agent'] as String).isNotEmpty)
          m['agent'] as String,
    ];
  }

  /// [HerdrTransport.request] with "this herdr is too old for that" told
  /// apart from a bad request: herdr answers an unknown method (or a
  /// parameter it does not know) with the same `invalid_request` it uses for
  /// bad values.
  Future<Map<String, dynamic>> _call(String method, Map<String, dynamic> params) async {
    try {
      return await _transport.request(method, params);
    } on HerdrApiException catch (e) {
      if (e.code == 'invalid_request' &&
          (e.message.contains('unknown variant `$method`') ||
              e.message.contains('unknown field'))) {
        throw HerdrUnsupportedException(method);
      }
      rethrow;
    }
  }

  static String _id(Map<String, dynamic> r, String object, String key) {
    final id = switch (r[object]) {
      final Map<String, dynamic> o => o[key],
      _ => null,
    };
    if (id is! String || id.isEmpty) {
      throw const HerdrTransportException('Unexpected response from herdr', fatal: false);
    }
    return id;
  }

  /// Subscribes to coarse change events. Any event means "re-fetch".
  ///
  /// Only parameterless types belong here: `pane.agent_status_changed`,
  /// `pane.output_matched` and `pane.scroll_changed` require a `pane_id`, and
  /// herdr rejects the WHOLE subscription if one entry is invalid (the event
  /// channel then dies and the connection flaps). A test checks this list
  /// against the schema.
  Stream<Map<String, dynamic>> changes() => _transport.events(const [
        {'type': 'workspace.created'},
        {'type': 'workspace.updated'},
        {'type': 'workspace.closed'},
        {'type': 'workspace.renamed'},
        {'type': 'tab.created'},
        {'type': 'tab.closed'},
        {'type': 'tab.renamed'},
        {'type': 'pane.created'},
        {'type': 'pane.closed'},
        {'type': 'pane.updated'},
        {'type': 'pane.exited'},
        {'type': 'pane.agent_detected'},
        {'type': 'layout.updated'},
      ]);

  /// See [HerdrTransport.reset].
  void reset() => _transport.reset();

  Future<void> close() => _transport.close();
}
