import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/prompt_content.dart';
import '../../../data/models/remote_file.dart' show RemoteFileException;
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attach_upload.dart';
import '../../../data/repositories/recent_phone_files.dart';
import '../../../data/services/attach_limits.dart';
import '../../../data/services/image_prep.dart';
import '../attach/attach_kit.dart';
import '../attach/tray.dart';
import '../files/file_format.dart';
import '../files/file_kind.dart';
import 'attach_picker.dart';

/// The most a message carries: more than a phone screen can show as chips, and
/// more pictures than a prompt should hold.
const maxAttachments = 5;

enum AttachmentKind { image, file }

/// Where a chip is in its life. Only [ready] chips carry a block to send.
enum AttachPhase {
  /// A picture is being read and encoded, or a host file's text is being read.
  preparing,

  /// A file of the phone is going to the host.
  uploading,

  /// The upload failed: the chip offers Retry.
  failed,

  ready,
}

/// One chip above the field. Immutable apart from [progress]; a state change
/// makes a new one with the same [id].
class Attachment {
  const Attachment({
    required this.id,
    required this.kind,
    required this.label,
    this.detail,
    this.block,
    this.thumb,
    this.preview,
    this.previewPath,
    this._phase,
    this.note,
    this.size,
    this.error,
    this.progress,
  });

  final int id;
  final AttachmentKind kind;

  /// The file's name (`IMG_2031.jpg`, `acp_client.dart`).
  final String label;

  /// Where a file is, relative to the session's folder; null for a picture.
  final String? detail;

  /// What is sent; null until the chip is [AttachPhase.ready].
  final ContentBlock? block;

  /// The prepared JPEG, for the chip's thumbnail and the viewer.
  final Uint8List? thumb;

  /// A picture to show before [thumb] exists: the gallery's own thumbnail
  /// bytes, already decoded by the grid.
  final Uint8List? preview;

  /// A picture on the phone to draw small while it uploads (a file picked in
  /// the Files tab).
  final String? previewPath;

  final AttachPhase? _phase;
  AttachPhase get phase => _phase ?? (block == null ? AttachPhase.preparing : AttachPhase.ready);

  /// The second line when it is not the usual one (`Sent as a file · this
  /// agent takes no images`).
  final String? note;

  /// Bytes of the file or picture, when known.
  final int? size;

  /// Why an upload failed.
  final String? error;

  /// Upload progress, 0 to 1. Listened to by the chip alone: the composer is
  /// not rebuilt for a tick.
  final ValueNotifier<double>? progress;

  bool get preparing => phase == AttachPhase.preparing;
  bool get uploading => phase == AttachPhase.uploading;
  bool get failed => phase == AttachPhase.failed;
  bool get ready => phase == AttachPhase.ready;

  /// Embedded text, not a link: the agent gets the file's contents.
  bool get embedded => block is EmbeddedResourceBlock;

  Attachment _with({
    ContentBlock? block,
    Uint8List? thumb,
    String? detail,
    AttachPhase? phase,
    String? note,
    String? error,
    ValueNotifier<double>? progress,
    int? size,
  }) => Attachment(
    id: id,
    kind: kind,
    label: label,
    detail: detail ?? this.detail,
    block: block ?? this.block,
    thumb: thumb ?? this.thumb,
    preview: preview,
    previewPath: previewPath,
    phase: phase ?? _phase,
    note: note ?? this.note,
    size: size ?? this.size,
    error: error,
    progress: progress ?? this.progress,
  );
}

/// A pick waiting for the sheet to finish closing.
class _Job {
  _Job(this.id, this.pick);

  final int id;
  final TrayItem pick;
}

/// A file of the phone on its way to the host.
class _Transfer {
  _Transfer({required this.path, required this.name, required this.size, required this.progress, this.release});

  final String path;
  final String name;
  final int size;
  final ValueNotifier<double> progress;

  /// Called with the local path once the file is on the host (or given up).
  final Future<void> Function(String path)? release;
  AttachUpload? upload;
  var cancelled = false;
}

/// The pictures and files waiting to be sent with the draft. Owned by the
/// screen (as the draft's controller is); the composer and its chips listen.
///
/// A picture is prepared (`prepareImage`: decoded and scaled by the engine's
/// codec, encoded in a worker isolate) while its chip shows "Preparing…"; a
/// file of the phone is uploaded to the host and its chip shows the progress;
/// the message cannot be sent until every chip is ready. A file is attached as
/// a `@path` link (`prompt_content.dart`), or as embedded text when the agent
/// takes it and the file is small text.
class ComposerAttachments extends ChangeNotifier {
  ComposerAttachments({
    required this.session,
    required this.picker,
    this.prepare = prepareImage,
    this.readFile = readDeviceFile,
    this.onProblem,
    this._kit,
    this._uploader,
  });

  final AgentSessionView session;
  final AttachPicker picker;

  /// `prepareImage`; a test swaps it (the real one needs the engine's codec).
  final Future<PreparedImage> Function(Uint8List input) prepare;

  /// Reads a picture of the phone's storage (a test swaps it: file I/O needs
  /// the real clock).
  final Future<Uint8List> Function(String path) readFile;

  static Future<Uint8List> readDeviceFile(String path) => File(path).readAsBytes();

  /// A plain message for the person (a toast): too large, unreadable, no camera.
  void Function(String message)? onProblem;

  final AttachKit? _kit;
  AttachUploader? _uploader;

  /// The phone's library, files and uploads (the device's unless a test gave
  /// its own).
  AttachKit get kit => _kit ?? AttachKit.device();
  AttachUploader get uploader => _uploader ??= kit.uploaderFor(session);

  /// The attach sheet is up (a second tap on the paperclip does not push another).
  var sheetOpen = false;

  final _items = <Attachment>[];
  final _transfers = <int, _Transfer>{};
  final _staged = <_Job>[];
  final _recent = <int, bool>{};
  final _gate = _Gate(2);
  var _next = 0;
  var _disposed = false;
  var _usedGallery = false;

  List<Attachment> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  bool get full => _items.length >= maxAttachments;

  /// Places left in the message.
  int get room => maxAttachments - _items.length;

  /// Something is still being prepared or uploaded: the message waits.
  bool get busy => _items.any((a) => a.preparing || a.uploading);

  /// A file could not be sent.
  bool get hasFailed => _items.any((a) => a.failed);

  /// Every chip is ready: the message can go.
  bool get canSend => _items.every((a) => a.ready);

  /// Why the message cannot go yet, for the field's hint; null when it can.
  String? get waitingReason {
    final uploading = _items.where((a) => a.uploading).toList();
    if (uploading.isNotEmpty) {
      return uploading.length == 1 ? 'Uploading ${uploading.first.label}…' : 'Uploading ${uploading.length} files…';
    }
    if (_items.any((a) => a.preparing)) return 'Preparing your attachments…';
    if (hasFailed) return 'An upload failed: retry it or remove it';
    return null;
  }

  /// The blocks to send after the text, in the order they were attached; the
  /// attachments are gone afterwards.
  List<ContentBlock> take() {
    final blocks = [for (final a in _items) ?a.block];
    _items.clear();
    _transfers.clear();
    notifyListeners();
    return blocks;
  }

  /// Puts back [taken] (the chips handed to a send that failed) ahead of what
  /// was attached since, so the person's attachments are not lost with it.
  /// What no longer fits ([maxAttachments]) is let go, and the person is told.
  void restore(List<Attachment> taken) {
    if (_disposed || taken.isEmpty) return;
    final back = taken.take(room.clamp(0, taken.length)).toList();
    _items.insertAll(0, back);
    final lost = taken.length - back.length;
    if (lost > 0) {
      _problem(lost == 1 ? 'One attachment did not fit back and was removed.' : '$lost attachments did not fit back and were removed.');
    }
    notifyListeners();
  }

  /// Takes chip [id] out; an upload in flight is cancelled.
  void remove(int id) {
    final before = _items.length;
    _items.removeWhere((a) => a.id == id);
    final t = _transfers.remove(id);
    if (t != null) {
      t.cancelled = true;
      t.upload?.cancel();
      unawaited(_releaseLocal(t));
    }
    _staged.removeWhere((j) => j.id == id);
    if (_items.length != before) notifyListeners();
  }

  /// Starts the work the gallery tab can do before the person taps Attach: a
  /// picture is read and encoded the moment it is picked, so Attach has
  /// nothing left to wait for. [GalleryPick.work] cancels it when undone.
  void speculate(TrayItem item) {
    if (item is! GalleryPick || !session.acceptsImages || _disposed) return;
    item.work.future = _gate.run(() => _prepareGallery(item));
    // Errors surface where the result is used; nothing listens until then.
    unawaited(item.work.future!.then<void>((_) {}, onError: (Object _) {}));
  }

  /// A pick was undone: its encoding is abandoned.
  void abandon(TrayItem item) {
    if (item is GalleryPick) item.work.cancel();
  }

  /// Warms what the gallery tab needs (permission read, first page, first
  /// thumbnails). Never asks the system for anything.
  void warm() => unawaited(kit.galleryModel.warm());

  /// Takes a picture with the camera app or picks one with the system photo
  /// picker. It becomes what a picture of the gallery or the Files tab becomes
  /// ([_startPicture]): an image when the agent takes images, else a file
  /// uploaded to the host, whichever way it was chosen.
  Future<void> addPhoto({required bool camera}) async {
    final PickedPhoto? photo;
    try {
      photo = await (camera ? picker.camera() : picker.photo());
    } on ImagePrepException catch (e) {
      _problem(e.message);
      return;
    }
    if (photo == null || _disposed) return;
    if (full) {
      _problem(_fullMessage);
      return;
    }
    if (sizeVerdict(photo.size) == SizeVerdict.tooLarge) {
      _problem(tooLargeMessage(photo.name, photo.size));
      return;
    }
    final id = _next++;
    _items.add(
      Attachment(
        id: id,
        kind: AttachmentKind.image,
        label: photo.name,
        previewPath: photo.path,
        phase: AttachPhase.preparing,
        size: photo.size,
        note: _pictureNote,
      ),
    );
    notifyListeners();
    await _startPicture(id, path: photo.path, name: photo.name, size: photo.size, recent: false);
  }

  /// Attaches the host file [path] (absolute) as a link, or as its text when
  /// the agent takes embedded context and the file is small text.
  Future<void> addHostFile(String path) async {
    if (_disposed) return;
    if (full) {
      _problem(_fullMessage);
      return;
    }
    final id = _next++;
    _stageHost(id, path);
    notifyListeners();
    await _startHost(id, path);
  }

  /// Puts [picks] on the chips at once (so they appear in the frame the sheet
  /// closes in). Nothing is read or sent until [startStaged], which the sheet
  /// calls when its close animation has finished.
  void stage(List<TrayItem> picks) {
    for (final pick in picks) {
      if (full) {
        _problem(_fullMessage);
        break;
      }
      final id = _next++;
      switch (pick) {
        case GalleryPick():
          _usedGallery = true;
          _items.add(
            Attachment(
              id: id,
              kind: AttachmentKind.image,
              label: pick.name,
              preview: pick.thumb,
              phase: AttachPhase.preparing,
              note: _pictureNote,
            ),
          );
        case PhonePick():
          final image = typeForName(pick.name).kind == FileKind.image;
          if (sizeVerdict(pick.size) == SizeVerdict.tooLarge) {
            _problem(tooLargeMessage(pick.name, pick.size));
            continue;
          }
          _items.add(
            Attachment(
              id: id,
              kind: image ? AttachmentKind.image : AttachmentKind.file,
              label: pick.name,
              previewPath: image ? pick.path : null,
              phase: AttachPhase.preparing,
              size: pick.size,
              note: image ? _pictureNote : null,
            ),
          );
        case HostPick():
          _stageHost(id, pick.path);
      }
      _staged.add(_Job(id, pick));
    }
    notifyListeners();
  }

  /// The sheet is gone: begins the work for everything [stage]d.
  void startStaged() {
    final jobs = [..._staged];
    _staged.clear();
    final big = <String>[];
    for (final job in jobs) {
      final pick = job.pick;
      if (pick is PhonePick && sizeVerdict(pick.size) == SizeVerdict.large) big.add(pick.name);
      unawaited(_begin(job));
    }
    if (big.isNotEmpty) _problem(largeMessage(big.first, count: big.length));
  }

  /// Tries a failed upload again.
  void retry(int id) {
    final t = _transfers[id];
    if (t == null || _disposed) return;
    t.cancelled = false;
    _startUpload(id, t);
  }

  static const _noImagesNote = 'Sent as a file · this agent takes no images';
  static const _fullMessage = 'At most $maxAttachments attachments per message.';

  /// The second line of a picture's chip: an agent that takes no images gets
  /// it as a file, and the chip says so from the start.
  String? get _pictureNote => session.acceptsImages ? null : _noImagesNote;

  /// `report.pdf is 312 MB. Files up to 200 MB can be attached.`
  static String tooLargeMessage(String name, int bytes) =>
      '$name is ${formatBytes(bytes)}. Files up to ${formatBytes(attachRefuseBytes)} can be attached.';

  /// `Large file: uploading may take a while.`
  static String largeMessage(String name, {int count = 1}) =>
      count == 1 ? '$name is large; uploading it may take a while.' : '$count large files; uploading them may take a while.';

  void _stageHost(int id, String path) {
    final name = path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => path);
    final detail = relativeToCwd(path, session.cwd);
    if (!session.acceptsEmbeddedContext) {
      _items.add(
        Attachment(
          id: id,
          kind: AttachmentKind.file,
          label: name,
          detail: detail,
          block: fileLinkBlock(path, cwd: session.cwd),
          phase: AttachPhase.ready,
        ),
      );
    } else {
      _items.add(Attachment(id: id, kind: AttachmentKind.file, label: name, detail: detail, phase: AttachPhase.preparing));
    }
  }

  Future<void> _startHost(int id, String path) async {
    if (!session.acceptsEmbeddedContext) return;
    final text = await _smallText(path);
    _replace(
      id,
      (a) => a._with(
        block: fileBlock(path, cwd: session.cwd, text: text, embeddedContext: true),
        phase: AttachPhase.ready,
      ),
    );
  }

  Future<void> _begin(_Job job) async {
    if (_disposed || !_items.any((a) => a.id == job.id)) return;
    switch (job.pick) {
      case HostPick(:final path):
        await _startHost(job.id, path);
      case PhonePick(:final path, :final name, :final size):
        if (typeForName(name).kind == FileKind.image) {
          await _startPicture(job.id, path: path, name: name, size: size, release: kit.files.release, recent: true);
        } else {
          _beginUpload(job.id, path: path, name: name, size: size, release: kit.files.release, recent: true);
        }
      case GalleryPick pick:
        await _beginGallery(job.id, pick);
    }
  }

  Future<void> _beginGallery(int id, GalleryPick pick) async {
    if (session.acceptsImages) {
      try {
        final image = await (pick.work.future ?? _gate.run(() => _prepareGallery(pick)));
        _replace(id, (a) => a._with(block: image.toBlock(), thumb: image.bytes, phase: AttachPhase.ready, size: image.bytes.length));
        return;
      } on _TooBigForImage catch (e) {
        await _fileFromGallery(id, pick, known: e.file);
        return;
      } on _Abandoned {
        return;
      } on ImagePrepException catch (e) {
        _drop(id);
        _problem(e.message);
        return;
      } on Object {
        _drop(id);
        _problem('Could not read that picture.');
        return;
      }
    }
    await _fileFromGallery(id, pick);
  }

  /// The original of a gallery picture goes up as a file (an agent that takes
  /// no pictures, or a picture over the encoder's limit).
  Future<void> _fileFromGallery(int id, GalleryPick pick, {GalleryFileInfo? known}) async {
    final file = known ?? await _galleryFile(pick);
    if (file == null || _disposed) {
      _drop(id);
      _problem('Could not read that picture.');
      return;
    }
    if (sizeVerdict(file.size) == SizeVerdict.tooLarge) {
      _drop(id);
      _problem(tooLargeMessage(file.name, file.size));
      return;
    }
    _beginUpload(id, path: file.path, name: file.name, size: file.size, recent: false);
  }

  Future<GalleryFileInfo?> _galleryFile(GalleryPick pick) async {
    final f = await kit.gallery.file(pick.asset);
    return f == null ? null : GalleryFileInfo(f.path, f.name, f.size);
  }

  Future<PreparedImage> _prepareGallery(GalleryPick pick) async {
    final f = await _galleryFile(pick);
    if (pick.work.cancelled) throw const _Abandoned();
    if (f == null) throw const ImagePrepException('Could not read that picture.');
    if (f.size > maxImageInputBytes) throw _TooBigForImage(f);
    final bytes = await readFile(f.path);
    if (pick.work.cancelled) throw const _Abandoned();
    return prepare(bytes);
  }

  /// A picture lying on the phone (the camera's shot, the system picker's, or
  /// one the Files tab chose): prepared and sent as an image when the agent
  /// takes images and the encoder takes its size, else uploaded and sent as a
  /// file. A gallery pick follows the same rule in [_beginGallery].
  Future<void> _startPicture(
    int id, {
    required String path,
    required String name,
    required int size,
    Future<void> Function(String path)? release,
    required bool recent,
  }) async {
    if (session.acceptsImages && size <= maxImageInputBytes) {
      await _imageFromFile(id, path);
    } else {
      _beginUpload(id, path: path, name: name, size: size, release: release, recent: recent);
    }
  }

  Future<void> _imageFromFile(int id, String path) async {
    try {
      final bytes = await readFile(path);
      if (_disposed || !_items.any((a) => a.id == id)) return;
      final image = await prepare(bytes);
      _replace(id, (a) => a._with(block: image.toBlock(), thumb: image.bytes, phase: AttachPhase.ready, size: image.bytes.length));
    } on ImagePrepException catch (e) {
      _drop(id);
      _problem(e.message);
    } on Object {
      _drop(id);
      _problem('Could not read that picture.');
    }
  }

  void _beginUpload(
    int id, {
    required String path,
    required String name,
    required int size,
    Future<void> Function(String path)? release,
    required bool recent,
  }) {
    if (_disposed || !_items.any((a) => a.id == id)) return;
    final t = _Transfer(path: path, name: name, size: size, progress: ValueNotifier<double>(0), release: release);
    _transfers[id] = t;
    _recent[id] = recent;
    _startUpload(id, t);
  }

  void _startUpload(int id, _Transfer t) {
    t.progress.value = 0;
    _replace(id, (a) => a._with(phase: AttachPhase.uploading, progress: t.progress));
    final AttachUpload upload;
    try {
      upload = uploader.start(
        localPath: t.path,
        fileName: t.name,
        onProgress: (sent, total) => t.progress.value = total <= 0 ? 0 : (sent / total).clamp(0.0, 1.0),
      );
    } on Object {
      _replace(id, (a) => a._with(phase: AttachPhase.failed, error: 'Could not start the upload'));
      return;
    }
    t.upload = upload;
    upload.done.then<void>(
      (remote) {
        if (_disposed || t.cancelled || _transfers[id] != t) return;
        t.progress.value = 1;
        _replace(
          id,
          (a) => a._with(
            phase: AttachPhase.ready,
            block: fileLinkBlock(remote, cwd: session.cwd, size: t.size),
            detail: remote,
            size: t.size,
            note: a.note ?? 'Uploaded \u00b7 ${formatBytes(t.size)}',
          ),
        );
        if (_recent[id] ?? false) {
          unawaited(
            kit.recents.add(
              RecentPhoneFile(name: t.name, size: t.size, machineId: session.machine.profile.id, hostPath: remote),
            ),
          );
        }
        unawaited(_releaseLocal(t));
      },
      onError: (Object e) {
        if (_disposed || t.cancelled || _transfers[id] != t) return;
        final message = e is RemoteFileException ? e.message : 'The upload failed';
        _replace(id, (a) => a._with(phase: AttachPhase.failed, error: message));
      },
    );
  }

  Future<void> _releaseLocal(_Transfer t) async {
    final release = t.release;
    if (release != null) await release(t.path);
  }

  /// The file's text when it is small and readable as UTF-8, else null (then
  /// the file goes as a link). Never throws.
  Future<String?> _smallText(String path) async {
    try {
      final files = session.machine.files;
      final size = (await files.stat(path)).size;
      if (size == null || size == 0 || size > maxEmbeddedBytes) return null;
      final bytes = await files.readAll(path, size: size);
      if (bytes.contains(0)) return null;
      return utf8.decode(bytes);
    } on RemoteFileException {
      return null;
    } on FormatException {
      return null;
    }
  }

  void _problem(String message) {
    if (!_disposed) onProblem?.call(message);
  }

  void _drop(int id) {
    if (_disposed) return;
    _items.removeWhere((a) => a.id == id);
    _transfers.remove(id);
    notifyListeners();
  }

  /// Swaps chip [id] for [change]'s result; nothing when the person removed it
  /// meanwhile.
  void _replace(int id, Attachment Function(Attachment old) change) {
    if (_disposed) return;
    final i = _items.indexWhere((a) => a.id == id);
    if (i < 0) return;
    _items[i] = change(_items[i]);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _transfers.values) {
      t.cancelled = true;
      t.upload?.cancel();
      unawaited(_releaseLocal(t));
    }
    if (_usedGallery) unawaited(kit.gallery.clearFileCache());
    super.dispose();
  }
}

/// A picture's original on the phone, as the model needs it.
class GalleryFileInfo {
  const GalleryFileInfo(this.path, this.name, this.size);

  final String path;
  final String name;
  final int size;
}

class _Abandoned implements Exception {
  const _Abandoned();
}

class _TooBigForImage implements Exception {
  const _TooBigForImage(this.file);

  final GalleryFileInfo file;
}

/// Runs at most [limit] jobs at once, in order.
class _Gate {
  _Gate(this.limit);

  final int limit;
  var _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await job();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _running--;
      }
    }
  }
}
