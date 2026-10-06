/// Incremental parsing of a message that is still arriving.
///
/// [StreamingMd.append] only buffers (O(chunk)); the work happens when the
/// blocks are read, once per frame:
///
///  * **Frozen blocks.** Text is split into chunks by `MdChunker`; a chunk that
///    can no longer change (a blank line closed it, or the next block started
///    after a list or indented code) is parsed ONCE and its blocks are kept.
///    [frozen] only ever grows, and its block objects are never replaced, so a
///    row widget can be keyed by `message#index`.
///  * **The tail.** The text after the last frozen chunk is re-parsed on every
///    change, and healed (`healTail`) for display. Its length is one open block
///    plus the line being typed, not the message.
///
/// Invariant (tested at every prefix of every corpus message):
/// `StreamingMd` fed a prefix, unhealed, gives exactly the blocks of
/// `parseMd(prefix)`.
library;

import 'dart:collection';

import 'md_chunker.dart';
import 'md_document.dart';
import 'md_heal.dart';
import 'md_parser.dart';

final class StreamingMd {
  StreamingMd({this.softBreaksAsNewlines = true});

  /// See `parseMd`.
  final bool softBreaksAsNewlines;

  final MdChunker _chunker = MdChunker();
  final StringBuffer _partial = StringBuffer();
  final List<MdBlock> _frozen = <MdBlock>[];
  late final List<MdBlock> _frozenView = UnmodifiableListView<MdBlock>(_frozen);
  int _frozenChunks = 0;
  bool _endedInCr = false;
  int _version = 0;

  int _tailVersion = -1;
  List<MdBlock> _tailPlain = const <MdBlock>[];
  List<MdBlock> _tailHealed = const <MdBlock>[];
  bool _hasPlain = false;
  bool _hasHealed = false;

  /// Increases with every [append] that changed the text: a cheap "dirty" flag
  /// for a `ValueListenable`.
  int get version => _version;

  /// Adds the next piece of the message. Any split is fine (mid-line,
  /// mid-codepoint is not: pass whole UTF-16 strings), `\r\n` too.
  void append(String text) {
    if (text.isEmpty) return;
    var s = text;
    if (_endedInCr && s.codeUnitAt(0) == 0x0a) s = s.substring(1);
    if (s.isEmpty) {
      _endedInCr = false;
      return;
    }
    _endedInCr = s.codeUnitAt(s.length - 1) == 0x0d;
    s = normalizeNewlines(s);
    var at = 0;
    while (true) {
      final nl = s.indexOf('\n', at);
      if (nl < 0) break;
      if (_partial.isEmpty) {
        _chunker.addLine(s.substring(at, nl));
      } else {
        _partial.write(s.substring(at, nl));
        _chunker.addLine(_partial.toString());
        _partial.clear();
      }
      at = nl + 1;
    }
    if (at < s.length) _partial.write(at == 0 ? s : s.substring(at));
    _version++;
  }

  /// The whole text received so far (newlines normalized).
  String get text {
    final b = StringBuffer();
    for (final l in _chunker.lines) {
      b
        ..write(l)
        ..writeCharCode(0x0a);
    }
    b.write(_partial);
    return b.toString();
  }

  void _sync() {
    while (_frozenChunks < _chunker.closed.length) {
      final c = _chunker.closed[_frozenChunks++];
      _frozen.addAll(parseMdChunk(_chunker.source(c.start, c.end),
          softBreaksAsNewlines: softBreaksAsNewlines));
    }
  }

  /// Blocks that can no longer change, in order. The same list object grows;
  /// its elements are identical between calls.
  List<MdBlock> get frozen {
    _sync();
    return _frozenView;
  }

  /// The source text of the part that is not frozen yet.
  String get tailSource => _chunker.tailSource(_partial.toString());

  /// The blocks of the open tail: with [heal] (display) or exactly as
  /// `parseMd` would have them (default off, for tests and the final state).
  /// Cached until the next [append].
  List<MdBlock> tail({bool heal = false}) {
    _sync();
    if (_tailVersion != _version) {
      _tailVersion = _version;
      _hasPlain = false;
      _hasHealed = false;
    }
    if (heal) {
      if (!_hasHealed) {
        _tailHealed = parseMdChunk(healTail(tailSource), softBreaksAsNewlines: softBreaksAsNewlines);
        _hasHealed = true;
      }
      return _tailHealed;
    }
    if (!_hasPlain) {
      _tailPlain = parseMdChunk(tailSource, softBreaksAsNewlines: softBreaksAsNewlines);
      _hasPlain = true;
    }
    return _tailPlain;
  }

  /// Frozen blocks followed by the tail, as a document.
  MdDocument document({bool heal = false}) =>
      MdDocument([...frozen, ...tail(heal: heal)]);
}
