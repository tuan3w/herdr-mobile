import '../models/herdr_models.dart';
import 'herdr_transport.dart';

enum ReadSource {
  visible('visible'),
  recent('recent'),
  recentUnwrapped('recent_unwrapped');

  const ReadSource(this.wire);
  final String wire;
}

/// Typed herdr socket API over any [HerdrTransport].
class HerdrApi {
  HerdrApi(this._transport);

  final HerdrTransport _transport;

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

  /// Subscribes to coarse change events. Any event means "re-fetch".
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

  Future<void> close() => _transport.close();
}
