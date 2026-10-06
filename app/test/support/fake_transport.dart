import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'fake_fs.dart';

/// Builds a `session.snapshot` payload.
Map<String, dynamic> snapshotJson({
  List<({String id, String label})> workspaces = const [
    (id: 'w1', label: 'main'),
  ],
  List<({String id, String ws, String? agent, String status})> panes = const [],
  String version = '9.9.9',

  /// `completion_seq` per pane id, sent the way herdr does: on the snapshot's
  /// `agents` entries.
  Map<String, int> completionSeq = const {},
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
      if (completionSeq.isNotEmpty)
        'agents': [
          for (final MapEntry(:key, :value) in completionSeq.entries)
            {'pane_id': key, 'completion_seq': value},
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

  /// The entries of every [events] call, in order.
  final List<List<Map<String, dynamic>>> subscribed = [];

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
    subscribed.add(subscriptions);
    // A cancel that completes inside the test's fake clock, as a real
    // channel's does (the stock one hands back a future from the root zone,
    // which fake_async never runs).
    final c = StreamController<Map<String, dynamic>>(onCancel: () => Future<void>.value());
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

  /// Every [setBackground] call, in order.
  final List<bool> backgroundCalls = [];

  @override
  void setBackground(bool background) => backgroundCalls.add(background);

  /// Commands passed to [openExec], in order, and whether each asked for
  /// zipped lines.
  final List<String> execCommands = [];
  final List<bool> execZipped = [];

  /// What [openExec] answers; by default no command can run here.
  Future<ExecChannel> Function(String command)? onExec;

  @override
  Future<ExecChannel> openExec(String command, {bool zipped = false}) {
    execCommands.add(command);
    execZipped.add(zipped);
    final handler = onExec;
    if (handler == null) {
      return Future.error(const HerdrTransportException('No commands can run here'));
    }
    return handler(command);
  }

  /// The remote file system this machine "has". Null (the default) means the
  /// transport has no file channel, like a host without SFTP support in the app.
  FakeFs? fs;

  @override
  bool get supportsFiles => fs != null;

  FakeFs get _fs =>
      fs ?? (throw RemoteFileException(RemoteFileErrorKind.unsupported, 'No files here'));

  @override
  Future<RemoteStat> statFile(String path) => _fs.stat(path);

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => _fs.list(path);

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) =>
      _fs.read(path, offset, length);

  @override
  Future<String> realPath(String path) => _fs.realPath(path);

  @override
  Future<void> makeDirs(String path) => _fs.makeDirs(path);

  @override
  Future<void> removeFile(String path) => _fs.remove(path);

  /// Uploads asked for: `local -> remote`, in call order.
  final List<String> uploads = [];

  /// Replaces the default upload (which copies the local file into [fs]).
  UploadJob Function(String localPath, String remotePath, void Function(int, int)? onProgress)?
      onUpload;

  @override
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) {
    uploads.add('$localPath -> $remotePath');
    final handler = onUpload;
    if (handler != null) return handler(localPath, remotePath, onProgress);
    return CopyUpload(_fs, localPath, remotePath, onProgress);
  }

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

/// The default fake upload: copies the local file into [FakeFs] in one go.
class CopyUpload implements UploadJob {
  CopyUpload(FakeFs fs, String localPath, String remotePath, void Function(int, int)? onProgress) {
    () async {
      try {
        final bytes = await File(localPath).readAsBytes();
        fs.writeFile(remotePath, bytes);
        onProgress?.call(bytes.length, bytes.length);
        _done.complete();
      } on Object catch (e) {
        _done.completeError(e);
      }
    }();
  }

  final _done = Completer<void>();

  @override
  Future<void> get done => _done.future;

  @override
  void cancel() {}
}
