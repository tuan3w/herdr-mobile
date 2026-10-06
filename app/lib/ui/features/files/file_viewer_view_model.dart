import 'dart:async';
import 'dart:convert';

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

/// Bytes shown in the hex preview of a binary file.
const viewerHexBytes = 256;

/// JSON larger than this is formatted off the UI isolate.
const _jsonIsolateThreshold = 128 * 1024;

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
    required this._stat,
    this._line,
    this._formatJson = formatJson,
    this.firstChunk = viewerFirstChunk,
    this.textLimit = viewerTextLimit,
    this._forceText = false,
  });

  final RemoteFiles _files;

  /// What the file was when the text on screen was read (its time and size).
  /// A refresh replaces it.
  RemoteStat _stat;
  RemoteStat get stat => _stat;
  final int? _line;
  final JsonFormatter _formatJson;
  final int firstChunk;
  final int textLimit;

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
  bool _forceText;
  Uint8List _head = Uint8List(0);
  var _epoch = 0;
  var _disposed = false;
  var _changed = false;
  var _checking = false;
  var _refreshing = false;
  RemoteFileException? _refreshError;

  ViewerPhase get phase => _phase;
  RemoteFileException? get error => _error;
  FileType get type => _type;
  FileKind get kind => _type.kind;
  String get name => stat.name;

  /// A re-stat found the file newer than what is shown ([checkForChange]).
  bool get changedOnDisk => _changed;

  /// A refresh is reading the file again; the old content stays on screen.
  bool get refreshing => _refreshing;

  /// Why the last refresh failed; the old content is still shown.
  RemoteFileException? get refreshError => _refreshError;

  /// The text being shown (formatted JSON when [pretty] is on).
  TextDocument? get document => _pretty ? (_prettyDoc ?? _doc) : _doc;
  bool get loadingMore => _loadingMore;
  RemoteFileException? get loadMoreError => _moreError;
  bool get wrap => _wrap;
  bool get pretty => _pretty;

  /// Markdown shown as written instead of rendered.
  bool get showSource => _source;

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
    _loadingMore = false;
    _refreshing = false;
    _refreshError = null;
    _changed = false;
    _doc = null;
    _prettyDoc = null;
    _pretty = false;
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
        case FileKind.image || FileKind.svg || FileKind.pdf || FileKind.binary:
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

  /// Loads further pieces until [highlightLine]'s line is in memory.
  Future<void> _reachHighlightLine(int epoch) async {
    final line = _line;
    if (line == null) return;
    while (_current(epoch) && hasMore && _doc!.lineCount < line) {
      await _readMore(epoch);
    }
  }

  Future<void> retry() => load();

  /// One stat, no body: whether the file on the host is newer than what is
  /// shown. Sets [changedOnDisk]; a failed stat says nothing (a blip is not a
  /// change) and leaves it as it was.
  Future<void> checkForChange() async {
    if (_disposed || _phase != ViewerPhase.ready || _checking || _refreshing) return;
    _checking = true;
    final epoch = _epoch;
    try {
      final fresh = await _files.stat(_stat.path);
      if (!_current(epoch) || _refreshing) return;
      final changed = _newerThanShown(fresh);
      if (changed != _changed) {
        _changed = changed;
        notifyListeners();
      }
    } on RemoteFileException {
      // Nothing learned.
    } finally {
      _checking = false;
    }
  }

  bool _newerThanShown(RemoteStat fresh) {
    final then = _stat.modified;
    final now = fresh.modified;
    if (then != null && now != null) return now.isAfter(then);
    return fresh.size != _stat.size;
  }

  /// Reads the file again without leaving it: the old content stays on screen
  /// (and its place) until the new text replaces it, and stays if the read
  /// fails, with [refreshError] saying why. A file that is no longer text, or
  /// not text at all (an image), is opened again from the start.
  Future<void> refresh() async {
    if (_disposed || _refreshing) return;
    if (_phase == ViewerPhase.failed) return load();
    if (_phase != ViewerPhase.ready) return;
    final epoch = ++_epoch;
    _loadingMore = false;
    _refreshing = true;
    _refreshError = null;
    notifyListeners();
    try {
      final fresh = await _files.stat(_stat.path);
      if (!_current(epoch)) return;
      if (!isText) {
        _stat = fresh;
        await load();
        return;
      }
      if (!fresh.isFile) {
        throw RemoteFileException(RemoteFileErrorKind.notAFile, '${fresh.name} is not a file any more', path: fresh.path);
      }
      final size = fresh.size;
      final want = size == null || size == 0 ? firstChunk : (size < firstChunk ? size : firstChunk);
      final head = await _files.read(fresh.path, length: want);
      if (!_current(epoch)) return;
      final type = _forceText ? const FileType(FileKind.text, 'Text') : detectType(fresh.name, head);
      if (type.kind != FileKind.text && type.kind != FileKind.markdown && type.kind != FileKind.json) {
        _stat = fresh;
        await load();
        return;
      }
      _stat = fresh;
      _type = type;
      _lastChunkFull = head.length == want;
      final more = _moreAfter(head.length);
      final doc = TextDocument()..append(head, last: !more);
      if (!more) doc.finish();
      final wasPretty = _pretty;
      _doc = doc;
      _prettyDoc = null;
      _pretty = false;
      _changed = false;
      if (wasPretty && kind == FileKind.json) await _setPretty(true, epoch);
      if (!_current(epoch)) return;
    } on RemoteFileException catch (e) {
      if (!_current(epoch)) return;
      _refreshError = e;
    }
    _refreshing = false;
    notifyListeners();
  }

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
    _doc = null;
    _prettyDoc = null;
    super.dispose();
  }
}
