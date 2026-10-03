import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/services/remote_files.dart';
import 'file_format.dart';
import 'file_kind.dart';
import 'text_document.dart';

/// First read of a text file; also the sniffing window for every kind.
const viewerFirstChunk = 512 * 1024;

/// Text is never read past this, however often "Load more" is pressed.
const viewerTextLimit = 5 * 1024 * 1024;

/// Images larger than this are refused (they would take minutes over SSH and
/// hundreds of MB to decode).
const viewerImageLimit = 20 * 1024 * 1024;

/// Longest side a decoded image keeps. A 12000 px photo decoded in full is
/// ~570 MB of RGBA; at 2048 it is ~16 MB and still sharp on a phone.
const viewerImageMaxDimension = 2048;

/// Bytes shown in the hex preview of a binary file.
const viewerHexBytes = 256;

/// JSON larger than this is formatted off the UI isolate.
const _jsonIsolateThreshold = 128 * 1024;

/// A decoded image plus what the file really contained.
class DecodedImage {
  DecodedImage({required this.image, required this.width, required this.height, required this.downscaled});

  final ui.Image image;

  /// Pixel size of the file, not of [image] (which may have been shrunk).
  final int width;
  final int height;

  /// [image] has fewer pixels than the file.
  final bool downscaled;

  void dispose() => image.dispose();
}

/// Decodes [bytes], shrinking the longest side to [maxDimension] while
/// decoding (the full bitmap is never allocated). Throws when the bytes are not
/// an image the engine can read.
typedef ImageDecoder = Future<DecodedImage> Function(Uint8List bytes, {required int maxDimension});

Future<DecodedImage> decodeImageBytes(Uint8List bytes, {required int maxDimension}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    final shrink = w > maxDimension || h > maxDimension;
    codec = await descriptor.instantiateCodec(
      targetWidth: shrink && w >= h ? maxDimension : null,
      targetHeight: shrink && h > w ? maxDimension : null,
    );
    final frame = await codec.getNextFrame();
    return DecodedImage(image: frame.image, width: w, height: h, downscaled: shrink);
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// Pretty-prints [raw] JSON, or returns null when it is not valid JSON.
typedef JsonFormatter = Future<String?> Function(String raw);

String? _formatJsonSync(String raw) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(raw));
  } on FormatException {
    return null;
  }
}

Future<String?> formatJson(String raw) =>
    raw.length > _jsonIsolateThreshold ? compute(_formatJsonSync, raw) : SynchronousFuture(_formatJsonSync(raw));

enum ViewerPhase { loading, ready, failed }

/// One open file: reads what the viewer needs for its kind and holds the
/// result. Text arrives in pieces (never more than [viewerTextLimit]); images
/// are decoded once and released with the screen; anything else keeps only a
/// short head for the hex preview.
class FileViewerViewModel extends ChangeNotifier {
  FileViewerViewModel({
    required this._files,
    required this.stat,
    this._line,
    this._decoder = decodeImageBytes,
    this._formatJson = formatJson,
    this.firstChunk = viewerFirstChunk,
    this.textLimit = viewerTextLimit,
    this.imageLimit = viewerImageLimit,
  });

  final RemoteFiles _files;
  final RemoteStat stat;
  final int? _line;
  final ImageDecoder _decoder;
  final JsonFormatter _formatJson;
  final int firstChunk;
  final int textLimit;
  final int imageLimit;

  ViewerPhase _phase = ViewerPhase.loading;
  RemoteFileException? _error;
  late FileType _type = typeForName(stat.name);
  TextDocument? _doc;
  TextDocument? _prettyDoc;
  var _lastChunkFull = false;
  var _loadingMore = false;
  RemoteFileException? _moreError;
  var _wrap = false;
  var _pretty = false;
  var _source = false;
  DecodedImage? _image;
  Uint8List _head = Uint8List(0);
  var _epoch = 0;
  var _disposed = false;
  var _forceText = false;

  ViewerPhase get phase => _phase;
  RemoteFileException? get error => _error;
  FileType get type => _type;
  FileKind get kind => _type.kind;
  String get name => stat.name;

  /// The text being shown (formatted JSON when [pretty] is on).
  TextDocument? get document => _pretty ? (_prettyDoc ?? _doc) : _doc;
  bool get loadingMore => _loadingMore;
  RemoteFileException? get loadMoreError => _moreError;
  bool get wrap => _wrap;
  bool get pretty => _pretty;

  /// Markdown shown as written instead of rendered.
  bool get showSource => _source;
  DecodedImage? get image => _image;

  /// First bytes of a non-text file, for the hex preview.
  Uint8List get head => _head;

  int get _loaded => _doc?.bytes ?? 0;

  /// More of the file can be loaded (it is bigger than what is shown and the
  /// limit is not reached).
  bool get hasMore => _doc != null && _more && _loaded < textLimit;

  /// The file continues past [textLimit]: that is as much as is ever shown.
  bool get truncatedAtLimit => _doc != null && _more && _loaded >= textLimit;

  bool get _more => _moreAfter(_loaded);

  /// 1-based line to highlight and scroll to, when it exists in what is loaded.
  int? get highlightLine {
    final line = _line;
    final doc = _doc;
    if (line == null || doc == null || line < 1 || line > doc.lineCount) return null;
    return line;
  }

  /// Whether the text can be formatted (JSON that has been read completely).
  bool get canPretty => kind == FileKind.json && _doc != null && !truncatedAtLimit;

  bool get isText => switch (kind) {
        FileKind.text || FileKind.markdown || FileKind.json => true,
        _ => false,
      };

  Future<void> load() async {
    final epoch = ++_epoch;
    _phase = ViewerPhase.loading;
    _error = null;
    _moreError = null;
    _doc = null;
    _prettyDoc = null;
    _pretty = false;
    _image?.dispose();
    _image = null;
    notifyListeners();
    try {
      if (stat.kind == RemoteEntryKind.dir) {
        throw RemoteFileException(RemoteFileErrorKind.notAFile, '${stat.name} is a folder', path: stat.path);
      }
      if (stat.kind == RemoteEntryKind.other) {
        throw RemoteFileException(RemoteFileErrorKind.notAFile, 'Special files (sockets, devices, pipes) cannot be opened',
            path: stat.path);
      }
      final size = stat.size;
      final want = size == null || size == 0 ? firstChunk : (size < firstChunk ? size : firstChunk);
      final head = await _files.read(stat.path, length: want);
      if (!_current(epoch)) return;
      _lastChunkFull = head.length == want;
      _type = _forceText ? const FileType(FileKind.text, 'Text') : detectType(stat.name, head);
      switch (_type.kind) {
        case FileKind.text || FileKind.markdown || FileKind.json:
          final doc = TextDocument()..append(head, last: !_moreAfter(head.length));
          if (!_moreAfter(head.length)) doc.finish();
          _doc = doc;
          await _reachHighlightLine(epoch);
          if (!_current(epoch)) return;
          // Minified JSON is unreadable as it arrives: format it right away.
          if (kind == FileKind.json && canPretty && !hasMore && doc.lineCount <= 3) {
            await _setPretty(true, epoch);
            if (!_current(epoch)) return;
          }
        case FileKind.image:
          await _loadImage(head, epoch);
          if (!_current(epoch)) return;
        case FileKind.svg || FileKind.pdf || FileKind.binary:
          _head = Uint8List.sublistView(head, 0, head.length < viewerHexBytes ? head.length : viewerHexBytes);
      }
      _phase = ViewerPhase.ready;
    } on RemoteFileException catch (e) {
      if (!_current(epoch)) return;
      _error = e;
      _phase = ViewerPhase.failed;
    }
    notifyListeners();
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;

  bool _moreAfter(int loaded) {
    final size = stat.size;
    if (size != null && size > 0) return loaded < size;
    return _lastChunkFull;
  }

  Future<void> _loadImage(Uint8List head, int epoch) async {
    final size = stat.size ?? head.length;
    if (size > imageLimit) {
      throw RemoteFileException(
        RemoteFileErrorKind.tooLarge,
        'This image is ${formatBytes(size)}; images over ${formatBytes(imageLimit)} are not opened.',
        path: stat.path,
      );
    }
    final Uint8List bytes;
    if (head.length >= size) {
      bytes = head;
    } else {
      bytes = await _files.readAll(stat.path, size: size);
      if (!_current(epoch)) return;
    }
    try {
      final decoded = await _decoder(bytes, maxDimension: viewerImageMaxDimension);
      if (!_current(epoch)) {
        decoded.dispose();
        return;
      }
      _image = decoded;
    } on Object {
      if (!_current(epoch)) return;
      throw RemoteFileException(
        RemoteFileErrorKind.failed,
        "This image can't be decoded. It may be damaged or in a format Android does not support.",
        path: stat.path,
        fatal: true,
      );
    }
  }

  /// Loads further pieces until [highlightLine]'s line is in memory.
  Future<void> _reachHighlightLine(int epoch) async {
    final line = _line;
    if (line == null) return;
    while (_current(epoch) && hasMore && _doc!.lineCount < line) {
      await _readMore(epoch);
    }
  }

  Future<void> retry() => load();

  /// Whether the file can be read as text although it is not shown that way
  /// (SVG: an image format whose source is text).
  bool get canViewAsText => kind == FileKind.svg;

  /// Shows [FileKind.svg] source as text.
  Future<void> viewAsText() {
    _forceText = true;
    return load();
  }

  /// Reads the next piece of a long text file.
  Future<void> loadMore() async {
    if (_loadingMore || !hasMore) return;
    final epoch = _epoch;
    _loadingMore = true;
    _moreError = null;
    notifyListeners();
    try {
      await _readMore(epoch);
    } on RemoteFileException catch (e) {
      if (_current(epoch)) _moreError = e;
    }
    if (_disposed || epoch != _epoch) return;
    _loadingMore = false;
    notifyListeners();
  }

  Future<void> _readMore(int epoch) async {
    final doc = _doc!;
    final left = textLimit - doc.bytes;
    final size = stat.size;
    var want = left < firstChunk ? left : firstChunk;
    if (size != null && size > 0 && size - doc.bytes < want) want = size - doc.bytes;
    final piece = await _files.read(stat.path, offset: doc.bytes, length: want);
    if (!_current(epoch)) return;
    _lastChunkFull = piece.length == want && piece.isNotEmpty;
    final more = _moreAfter(doc.bytes + piece.length) && doc.bytes + piece.length < textLimit;
    doc.append(piece, last: !more || piece.isEmpty);
    if (!_more || piece.isEmpty) doc.finish();
  }

  /// Everything the file's text (up to [textLimit]) for the clipboard; loads
  /// the rest first. [complete] is false when the file is larger than that.
  Future<({String text, bool complete})?> textForCopy() async {
    final doc = _doc;
    if (doc == null) return null;
    final epoch = _epoch;
    try {
      while (_current(epoch) && hasMore) {
        await _readMore(epoch);
      }
    } on RemoteFileException {
      // Copy what is loaded.
    }
    if (_disposed) return null;
    notifyListeners();
    final shown = document!;
    return (text: shown.text, complete: !truncatedAtLimit);
  }

  void setWrap(bool value) {
    if (_wrap == value) return;
    _wrap = value;
    notifyListeners();
  }

  void setShowSource(bool value) {
    if (_source == value) return;
    _source = value;
    notifyListeners();
  }

  /// Switches formatted JSON on or off. Turning it on reads the rest of the
  /// file first. Returns a message when it cannot (not valid JSON, too big).
  Future<String?> setPretty(bool on) => _setPretty(on, _epoch);

  Future<String?> _setPretty(bool on, int epoch) async {
    if (!on) {
      _pretty = false;
      notifyListeners();
      return null;
    }
    final doc = _doc;
    if (doc == null || kind != FileKind.json) return null;
    try {
      while (_current(epoch) && hasMore) {
        await _readMore(epoch);
      }
    } on RemoteFileException catch (e) {
      return e.message;
    }
    if (!_current(epoch)) return null;
    if (truncatedAtLimit) {
      return 'This file is too large to format (${formatBytes(textLimit)} limit).';
    }
    final formatted = await _formatJson(doc.text);
    if (!_current(epoch)) return null;
    if (formatted == null) return "This isn't valid JSON, so it is shown as written.";
    _prettyDoc = TextDocument()..append(utf8.encode(formatted), last: true);
    _pretty = true;
    notifyListeners();
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _image?.dispose();
    _image = null;
    _doc = null;
    _prettyDoc = null;
    super.dispose();
  }
}
