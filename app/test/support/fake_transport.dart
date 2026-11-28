import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:herdr_mobile/data/host/host_link.dart' show HostException;
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/models/web_bridge.dart';
import 'package:herdr_mobile/data/services/file_walk_search.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'fake_fs.dart';

/// Builds a `session.snapshot` payload.
Map<String, dynamic> snapshotJson({
  List<({String id, String label})> workspaces = const [(id: 'w1', label: 'main')],
  List<({String id, String ws, String? agent, String status})> panes = const [],
  String version = '9.9.9',

  /// `completion_seq` per pane id, sent the way herdr does: on the snapshot's
  /// `agents` entries.
  Map<String, int> completionSeq = const {},
}) => {
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
      for (final MapEntry(:key, :value) in completionSeq.entries) {'pane_id': key, 'completion_seq': value},
    ],
};

/// Scriptable in-memory transport.
class FakeTransport implements HerdrTransport {
  FakeTransport([Map<String, dynamic>? snapshot]) : snapshot = snapshot ?? snapshotJson();

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
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
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

  void emit([Map<String, dynamic> event = const {'event': 'pane_updated'}]) => _streams.last.add(event);

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

  /// What [hostCall] answers; by default the agent helper cannot be had here.
  Future<Object?> Function(String service, String method, Map<String, Object?> args)? onHostCall;

  /// What [openHostStream] answers; by default the agent helper cannot be had here.
  Future<ExecChannel> Function(String service, String method, Map<String, Object?> args)? onHostStream;

  /// Every host call and stream opened, as `service.method`.
  final hostCalls = <String>[];

  @override
  Future<Object?> hostCall(String service, String method, [Map<String, Object?> args = const {}, Duration? timeout]) {
    hostCalls.add('$service.$method');
    final handler = onHostCall;
    if (handler == null) {
      return Future.error(const HostException('unavailable', 'The agent helper is not available here.'));
    }
    return handler(service, method, args);
  }

  @override
  Future<ExecChannel> openHostStream(String service, String method, [Map<String, Object?> args = const {}]) {
    hostCalls.add('$service.$method');
    final handler = onHostStream;
    if (handler == null) {
      return Future.error(const HostException('unavailable', 'The agent helper is not available here.'));
    }
    return handler(service, method, args);
  }

  /// What [openHostMessages] answers; by default the agent helper cannot be had here.
  Stream<Object?> Function(String service, String method, Map<String, Object?> args)? onHostMessages;

  @override
  Stream<Object?> openHostMessages(String service, String method, [Map<String, Object?> args = const {}]) {
    hostCalls.add('$service.$method');
    final handler = onHostMessages;
    if (handler == null) {
      return Stream.error(const HostException('unavailable', 'The agent helper is not available here.'));
    }
    return handler(service, method, args);
  }

  /// The remote file system this machine "has". Null (the default) means the
  /// transport has no file channel, like a host without SFTP support in the app.
  FakeFs? fs;

  @override
  bool get supportsFiles => fs != null;

  FakeFs get _fs => fs ?? (throw RemoteFileException(RemoteFileErrorKind.unsupported, 'No files here'));

  @override
  Future<RemoteStat> statFile(String path) => _fs.stat(path);

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => _fs.list(path);

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap, RemoteStat? ifMatch}) =>
      _fs.read(path, offset, length, ifMatch: ifMatch);

  @override
  Future<String> realPath(String path) => _fs.realPath(path);

  /// Every thumbnail asked for: `path@maxPx`, in call order.
  final List<String> thumbnails = [];

  /// What [thumbnailFile] answers; by default null, the way SFTP does.
  Future<Uint8List?> Function(String path, int maxPx, RemoteStat? expect, Future<void>? cancelled)? onThumbnail;

  @override
  Future<Uint8List?> thumbnailFile(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled}) async {
    thumbnails.add('$path@$maxPx');
    return onThumbnail?.call(path, maxPx, expect, cancelled);
  }

  /// Every search asked for, in call order.
  final List<FileSearchSpec> searches = [];

  /// What [searchFiles] answers; by default the walk over [fs] that a machine
  /// without the agent helper gets.
  Stream<FileSearchEvent> Function(FileSearchSpec spec)? onSearch;

  @override
  Stream<FileSearchEvent> searchFiles(FileSearchSpec spec) {
    searches.add(spec);
    final handler = onSearch;
    if (handler != null) return handler(spec);
    return walkSearch(_fs.list, spec);
  }

  final _watchers = <String, List<StreamController<RemoteStat?>>>{};

  /// How many [watchFile] subscriptions are listening to [path] right now.
  int watching(String path) => _watchers[path]?.where((c) => c.hasListener).length ?? 0;

  @override
  Stream<RemoteStat?> watchFile(String path) {
    late final StreamController<RemoteStat?> c;
    c = StreamController<RemoteStat?>(
      onListen: () {
        _watchers.putIfAbsent(path, () => []).add(c);
        try {
          c.add(_fs.peek(path));
        } on Object catch (e) {
          c
            ..addError(e)
            ..close();
        }
      },
      onCancel: () => _watchers[path]?.remove(c),
    );
    return c.stream;
  }

  /// Tells every watcher of [path] what it is now (a change on the machine).
  void touched(String path) {
    final now = _fs.peek(path);
    for (final c in [...?_watchers[path]]) {
      c.add(now);
    }
  }

  /// Ends every watcher of [path] with [error], the way a lost link does.
  void failWatchers(String path, Object error) {
    for (final c in [...?_watchers.remove(path)]) {
      c
        ..addError(error)
        ..close();
    }
  }

  /// Inbox paths handed out: `key -> name`, in call order.
  final List<String> reserved = [];

  /// Replaces the default reservation (`<home>/.herdr-mobile/inbox/<key>/<name>`).
  Future<String> Function(String key, String name)? onReserve;

  @override
  Future<String> reserveInboxFile({required String key, required String name}) async {
    reserved.add('$key -> $name');
    final handler = onReserve;
    if (handler != null) return handler(key, name);
    final fs = _fs;
    final dir = '${fs.home}/.herdr-mobile/inbox/$key';
    fs.mkdirs(dir);
    return '$dir/$name';
  }

  /// What [sweepInbox] answers, how often it was asked, and what it throws when set.
  int sweepRemoved = 0;
  int sweeps = 0;
  Object? sweepFailure;

  @override
  Future<int> sweepInbox() async {
    if (fs == null) {
      throw RemoteFileException(RemoteFileErrorKind.unsupported, 'Needs the agent helper on this machine.');
    }
    if (sweepFailure != null) throw sweepFailure!;
    sweeps++;
    return sweepRemoved;
  }

  /// Uploads asked for: `local -> inbox path`, in call order.
  final List<String> uploads = [];

  /// Replaces the default upload (which copies the local file into [fs]).
  UploadJob Function(String localPath, String inboxPath, void Function(int, int)? onProgress)? onUpload;

  @override
  UploadJob uploadFile({
    required String localPath,
    required String inboxPath,
    void Function(int sent, int total)? onProgress,
  }) {
    uploads.add('$localPath -> $inboxPath');
    final handler = onUpload;
    if (handler != null) return handler(localPath, inboxPath, onProgress);
    return CopyUpload(_fs, localPath, inboxPath, onProgress);
  }

  /// Pages asked for through [openWebBridge], in call order.
  final List<WebBridgeSpec> webBridges = [];

  /// What [openWebBridge] answers.
  WebBridgeInfo webInfo = const WebBridgeInfo(port: 41234, token: '0123456789abcdef0123456789abcdef');

  /// When set, [openWebBridge] throws this.
  Object? webFailure;

  /// While set, [openWebBridge] waits for it (a connection being made).
  Completer<void>? webGate;

  @override
  Future<WebBridgeInfo> openWebBridge(WebBridgeSpec spec) async {
    webBridges.add(spec);
    await webGate?.future;
    if (webFailure != null) throw webFailure!;
    return webInfo;
  }

  @override
  Future<void> close() async => closed = true;
}

/// Polls until [test] is true (real time), failing after [timeout].
Future<void> eventually(
  bool Function() test, {
  // Costs nothing once the condition holds. Generous because a loaded 4-core
  // runner stretches real work (a file written, 32 requests queued) well past
  // a few seconds; under flutter_test's 30 s per-test limit, so a real failure
  // still reports its reason here.
  Duration timeout = const Duration(seconds: 20),
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
  CopyUpload(FakeFs fs, String localPath, String inboxPath, void Function(int, int)? onProgress) {
    () async {
      try {
        final bytes = await File(localPath).readAsBytes();
        fs.writeFile(inboxPath, bytes);
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
