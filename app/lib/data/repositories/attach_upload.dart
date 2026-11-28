import 'dart:async';

import '../models/remote_file.dart';
import 'machine_connection.dart';

/// An upload the person can wait for or cancel.
abstract interface class AttachUpload {
  /// The absolute path of the copy on the host; fails with the reason (a
  /// `RemoteFileException` for a host problem).
  Future<String> get done;

  /// Stops the transfer; [done] then fails.
  void cancel();
}

/// Sends a file of the phone to the host. A small interface so the composer's
/// tests run the chips with a fake link.
abstract interface class AttachUploader {
  AttachUpload start({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
  });
}

/// Uploads into the host's inbox for one session: the host picks the path
/// (`RemoteFiles.reserveInboxFile`) and stores the file through the agent
/// helper (`RemoteFiles.uploadToInbox`).
///
/// A transfer that was cut (the link dropped, the person cancelled) keeps its
/// path, so sending the same file again continues where the host stopped
/// instead of starting over.
class HostUploader implements AttachUploader {
  HostUploader({required this.machine, required this.sessionKey});

  final MachineConnection machine;
  final String sessionKey;
  final _paths = <String, String>{};

  @override
  AttachUpload start({
    required String localPath,
    required String fileName,
    void Function(int sent, int total)? onProgress,
  }) => _HostUpload(machine, sessionKey, localPath, fileName, onProgress, _paths);
}

class _HostUpload implements AttachUpload {
  _HostUpload(this._machine, this._sessionKey, this._localPath, this._fileName, this._onProgress, this._paths) {
    unawaited(_run());
  }

  final MachineConnection _machine;
  final String _sessionKey;
  final String _localPath;
  final String _fileName;
  final void Function(int sent, int total)? _onProgress;
  final Map<String, String> _paths;
  final _done = Completer<String>();
  UploadJob? _job;
  var _cancelled = false;

  @override
  Future<String> get done => _done.future;

  Future<void> _run() async {
    final memory = '$_localPath\n$_fileName';
    try {
      final remote = _paths[memory] ?? await _machine.files.reserveInboxFile(key: _sessionKey, name: _fileName);
      _paths[memory] = remote;
      if (_cancelled) {
        _done.completeError(const _Cancelled());
        return;
      }
      final job = _machine.files.uploadToInbox(localPath: _localPath, inboxPath: remote, onProgress: _onProgress);
      _job = job;
      await job.done;
      _paths.remove(memory);
      _done.complete(remote);
    } on Object catch (e, s) {
      // What reached the host stays there for a cut transfer; any other
      // failure (a refused name, a file that changed) starts afresh.
      final cut = e is UploadCancelled || (e is RemoteFileException && e.kind == RemoteFileErrorKind.network);
      if (!cut) _paths.remove(memory);
      if (!_done.isCompleted) _done.completeError(e, s);
    }
  }

  @override
  void cancel() {
    _cancelled = true;
    _job?.cancel();
    if (_job == null && !_done.isCompleted) _done.completeError(const _Cancelled());
  }
}

class _Cancelled implements Exception {
  const _Cancelled();

  @override
  String toString() => 'Cancelled';
}
