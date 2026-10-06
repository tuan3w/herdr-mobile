import 'dart:convert';
import 'dart:typed_data';

import 'file_kind.dart' show utf8SafeLength;

/// A text file read in pieces: bytes go in as they arrive, lines come out.
///
/// Reads can stop anywhere, so a multi-byte character or a line may be split
/// across two pieces; both are carried over instead of being mangled. UTF-8
/// that is not valid becomes U+FFFD rather than an error. Lines end at `\n`; a
/// `\r` before it is dropped (CRLF files). Tabs are kept in [lines] (copying
/// gives the original) and counted as four columns by [widthOf].
class TextDocument {
  final List<String> _lines = [''];
  Uint8List _carry = Uint8List(0);
  var _maxColumns = 0;
  var _bytes = 0;

  /// Longest line in terminal-style columns (tabs as four, wide characters as
  /// two): sizes the horizontal extent of a non-wrapping view.
  int get maxColumns => _maxColumns;

  /// Bytes consumed so far.
  int get bytes => _bytes;

  /// Number of lines; a file that ends with a newline does not have an empty
  /// last line.
  int get lineCount => _lines.length - ((_lines.last.isEmpty && _lines.length > 1) ? 1 : 0);

  String line(int index) => _lines[index];

  /// All lines, without a phantom empty last line.
  List<String> get lines => lineCount == _lines.length ? _lines : _lines.sublist(0, lineCount);

  bool get isEmpty => _bytes == 0;

  /// The whole text, as read (tabs and all).
  String get text => lines.join('\n');

  /// Adds the next [chunk] of the file. [last] says there is nothing after it,
  /// so a trailing partial character is decoded (as U+FFFD) instead of waited
  /// for.
  void append(Uint8List chunk, {bool last = false}) {
    _bytes += chunk.length;
    final Uint8List data;
    if (_carry.isEmpty) {
      data = chunk;
    } else {
      data = Uint8List(_carry.length + chunk.length)
        ..setRange(0, _carry.length, _carry)
        ..setRange(_carry.length, _carry.length + chunk.length, chunk);
    }
    final usable = last ? data.length : utf8SafeLength(data);
    _carry = usable == data.length ? Uint8List(0) : Uint8List.fromList(data.sublist(usable));
    if (usable == 0) return;
    final decoded = const Utf8Decoder(allowMalformed: true).convert(data, 0, usable);
    // Drop the BOM of the first piece: it is not text.
    final text = _bytes == chunk.length && decoded.startsWith('\uFEFF') ? decoded.substring(1) : decoded;
    final parts = (_lines.removeLast() + text).split('\n');
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i];
      // A \r at the very end of a piece may belong to a \r\n that straddles
      // two pieces; it is dropped once the \n arrives, or at the end of file.
      if (i < parts.length - 1 && part.endsWith('\r')) part = part.substring(0, part.length - 1);
      _lines.add(part);
    }
    // Only the lines this piece touched need measuring: the one that was open
    // and the new ones.
    final first = _lines.length - parts.length;
    for (var i = first; i < _lines.length; i++) {
      final w = widthOf(_lines[i]);
      if (w > _maxColumns) _maxColumns = w;
    }
  }

  /// Finishes a file read to its end: a final `\r` is dropped like the others.
  void finish() {
    final lastLine = _lines.last;
    if (lastLine.endsWith('\r')) _lines[_lines.length - 1] = lastLine.substring(0, lastLine.length - 1);
  }

  /// Display width of [line] in columns, without building the expanded string.
  static int widthOf(String line) {
    var w = 0;
    for (final c in line.codeUnits) {
      if (c == 9) {
        w += 4;
      } else if ((c >= 0x1100 && c <= 0x115F) ||
          (c >= 0x2E80 && c <= 0xA4CF) ||
          (c >= 0xAC00 && c <= 0xD7A3) ||
          (c >= 0xF900 && c <= 0xFAFF) ||
          (c >= 0xFE30 && c <= 0xFE6F) ||
          (c >= 0xFF00 && c <= 0xFF60) ||
          (c >= 0xFFE0 && c <= 0xFFE6)) {
        w += 2;
      } else {
        w += 1;
      }
    }
    return w;
  }

  /// [line] ready to draw: tabs become four spaces.
  static String expandTabs(String line) => line.contains('\t') ? line.replaceAll('\t', '    ') : line;
}
