import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/photo_export.dart';
import '../../../data/services/remote_file_staging.dart';
import '../../../data/services/remote_files.dart';

enum CopyPhase { idle, running, done, failed }

/// How a share or a save ended: [done], or [problem] in words, or neither when
/// the person cancelled the copy (nothing to say).
typedef CopyResult = ({bool done, String? problem});

/// A file of the machine being copied to the phone: for the video player, and
/// for sharing or saving a file the viewer cannot do that with from memory.
/// One copy at a time (a second ask joins the one running); the viewer owns it,
/// and leaving the viewer stops the copy.
class FileCopyModel extends ChangeNotifier {
  FileCopyModel({required this._files, required this._staging, required this._export});

  final RemoteFiles _files;
  final RemoteFileStaging _staging;
  final PhotoExport _export;

  CopyPhase _phase = CopyPhase.idle;
  var _written = 0;
  var _total = 0;
  File? _file;
  RemoteStat? _of;
  String? _failure;
  Future<File?>? _running;
  ReadCancel? _cancel;
  var _disposed = false;

  CopyPhase get phase => _phase;
  bool get running => _phase == CopyPhase.running;

  /// Bytes on the phone so far, and of how many (while [running]).
  int get written => _written;
  int get total => _total;

  /// The copy, once [phase] is done.
  File? get file => _phase == CopyPhase.done ? _file : null;

  /// Why the last copy failed, in words; only while [phase] is failed.
  String? get failure => _failure;

  /// The file on the phone, copying it first unless this very file (same size
  /// and time) is already there. Null when the copy was cancelled or failed
  /// ([failure] says which).
  Future<File?> copy(RemoteStat stat) {
    if (_running case final running?) {
      if (_sameFile(_of, stat)) return running;
      // The file changed on the machine since this copy began (the person
      // reloaded it): that copy is of the old bytes. Stop it, then copy again.
      cancel();
      return running.then((_) => copy(stat));
    }
    // The copy may have been removed since (Android empties the temporary folder,
    // another copy took the place): then it is made again.
    if (_phase == CopyPhase.done && _file != null && _sameFile(_of, stat) && _file!.existsSync()) {
      return Future.value(_file);
    }
    final stop = ReadCancel();
    _cancel = stop;
    _of = stat;
    _phase = CopyPhase.running;
    _written = 0;
    _total = stat.size ?? 0;
    _failure = null;
    _notify();
    final run = _copy(stat, stop);
    _running = run;
    return run;
  }

  Future<File?> _copy(RemoteStat stat, ReadCancel cancel) async {
    try {
      final file = await _staging.fetch(
        _files,
        stat,
        cancel: cancel,
        onProgress: (n) {
          if (cancel.cancelled) return;
          _written = n;
          _notify();
        },
      );
      _file = file;
      _phase = CopyPhase.done;
      return file;
    } on ReadCancelled {
      _phase = CopyPhase.idle;
      return null;
    } on RemoteFileException catch (e) {
      _failure = e.message;
      _phase = CopyPhase.failed;
      return null;
    } finally {
      _running = null;
      _cancel = null;
      _notify();
    }
  }

  /// Stops the copy that is running; what was written stays for the next copy of
  /// the same file to continue from (see [RemoteFileStaging.fetch]).
  void cancel() => _cancel?.cancel();

  /// Hands the copy of [stat] to the share sheet, making it first.
  Future<CopyResult> share(RemoteStat stat) => _hand(stat, _export.shareFile);

  /// Puts the copy of the video [stat] in the gallery, making it first.
  Future<CopyResult> saveVideo(RemoteStat stat) => _hand(stat, _export.saveVideoToGallery);

  /// A hand-off is under way (the copy is done and the share sheet or the
  /// gallery has it, or is being asked).
  bool get handing => _handing;
  var _handing = false;

  Future<CopyResult> _hand(RemoteStat stat, Future<void> Function(File file) to) async {
    // A second tap while the first is still working would open a second share
    // sheet or save the video twice: it is ignored, the first one says what happened.
    if (_handing) return (done: false, problem: null);
    _handing = true;
    _notify();
    try {
      final file = await copy(stat);
      if (file == null) return (done: false, problem: _failure);
      try {
        await to(file);
        return (done: true, problem: null);
      } on PhotoExportException catch (e) {
        return (done: false, problem: e.message);
      }
    } finally {
      _handing = false;
      _notify();
    }
  }

  static bool _sameFile(RemoteStat? a, RemoteStat b) =>
      a != null && a.path == b.path && a.size == b.size && a.modified == b.modified;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    super.dispose();
  }
}
