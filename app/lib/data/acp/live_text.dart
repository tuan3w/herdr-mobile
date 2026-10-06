import 'package:flutter/foundation.dart' show Listenable, VoidCallback;

/// The text of the message that is streaming in right now: append-only, and
/// the one mutable thing in the transcript.
///
/// A chunk costs [append], O(1) whatever the length of the message or of the
/// transcript: the piece is kept as it came, nothing is copied or joined. The
/// pieces are joined only when someone reads [text] (once per read, and the
/// joined text is kept as the one piece, so the next read joins only what
/// came after). A reader that only needs what grew since it last looked asks
/// for [tail] and pays for the new characters alone.
///
/// Listeners are told by [flush], never by [append]: the owner of the
/// transcript decides when the world hears of new text (once per frame, see
/// `AcpAgentSession`), so a burst of chunks is one notification. A
/// [LiveText] nobody flushes is just a string builder.
final class LiveText implements Listenable {
  LiveText([String initial = '']) {
    append(initial);
  }

  final _pieces = <String>[];
  int _length = 0;
  int _version = 0;
  int _told = 0;
  List<VoidCallback>? _listeners;

  /// Characters (UTF-16 code units) so far.
  int get length => _length;

  /// Counts [append]s that added something. Equal versions mean equal text.
  int get version => _version;

  /// An [append] happened that [flush] has not announced yet.
  bool get dirty => _version != _told;

  /// Everything so far. O(length) when something was appended since the last
  /// read, O(1) otherwise.
  String get text {
    if (_pieces.length > 1) {
      final joined = _pieces.join();
      _pieces
        ..clear()
        ..add(joined);
    }
    return _pieces.isEmpty ? '' : _pieces.first;
  }

  /// The text from code unit [from] to the end, in time proportional to the
  /// length of that part (plus the pieces it spans).
  String tail(int from) {
    RangeError.checkValueInInterval(from, 0, _length, 'from');
    if (from == _length) return '';
    var i = _pieces.length;
    var start = _length;
    while (start > from) {
      start -= _pieces[--i].length;
    }
    if (i == _pieces.length - 1) return _pieces[i].substring(from - start);
    final out = StringBuffer(_pieces[i].substring(from - start));
    for (var k = i + 1; k < _pieces.length; k++) {
      out.write(_pieces[k]);
    }
    return out.toString();
  }

  /// Adds [piece] at the end. O(1); does not notify.
  void append(String piece) {
    if (piece.isEmpty) return;
    _pieces.add(piece);
    _length += piece.length;
    _version++;
  }

  /// Tells the listeners, once, that text was appended since the last flush.
  void flush() {
    if (_version == _told) return;
    _told = _version;
    final listeners = _listeners;
    if (listeners == null) return;
    for (final listener in List<VoidCallback>.of(listeners)) {
      if (listeners.contains(listener)) listener();
    }
  }

  @override
  void addListener(VoidCallback listener) => (_listeners ??= []).add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners?.remove(listener);

  @override
  String toString() => 'LiveText($_length chars, v$_version)';
}
