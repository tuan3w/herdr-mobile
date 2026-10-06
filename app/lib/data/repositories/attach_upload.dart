import 'dart:async';

import '../services/remote_files.dart';
import 'host_inbox.dart';
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

/// Uploads into the host's inbox for one session (`reserveInboxPath`, then
/// `RemoteFiles.upload` over the machine's SFTP channel).
class HostUploader implements AttachUploader {
  HostUploader({required this.machine, required this.sessionKey});

  final MachineConnection machine;
  final String sessionKey;

  @override
  AttachUpload start({required String localPath, required String fileName, void Function(int sent, int total)? onProgress}) =>
      _HostUpload(machine, sessionKey, localPath, fileName, onProgress);
}

class _HostUpload implements AttachUpload {
  _HostUpload(this._machine, this._sessionKey, this._localPath, this._fileName, this._onProgress) {
    unawaited(_run());
  }

  final MachineConnection _machine;
  final String _sessionKey;
  final String _localPath;
  final String _fileName;
  final void Function(int sent, int total)? _onProgress;
  final _done = Completer<String>();
  UploadJob? _job;
  var _cancelled = false;

  @override
  Future<String> get done => _done.future;

  Future<void> _run() async {
    try {
      final remote = await reserveInboxPath(_machine, sessionKey: _sessionKey, fileName: _fileName);
      if (_cancelled) {
        _done.completeError(const _Cancelled());
        return;
      }
      final job = _machine.files.upload(localPath: _localPath, remotePath: remote, onProgress: _onProgress);
      _job = job;
      await job.done;
      _done.complete(remote);
    } on Object catch (e, s) {
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
