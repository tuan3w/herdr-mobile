// How much of the streamed text is on screen: the probe of the stream bench's
// lag numbers. It knows the text that was received (letters and digits only,
// with the time each arrived) and reads the screen's text from the render tree.
import 'dart:math' as math;

import 'package:flutter/rendering.dart';

bool _alnum(int unit) => (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122);

String _letters(String text) {
  final b = StringBuffer();
  for (final unit in text.codeUnits) {
    if (_alnum(unit)) b.writeCharCode(unit);
  }
  return b.toString();
}

/// Matches what the screen shows against what the agent sent.
///
/// The streamed text must carry its own position: every few lines hold a
/// number that occurs once (`syntheticAnswer` does), so the last letters of a
/// paragraph say where in the answer it stands. Markdown marks and layout do
/// not matter, only letters and digits are compared.
class LagProbe {
  final _received = StringBuffer();
  String _receivedText = '';
  final _arrivalUs = <int>[];

  /// Letters and digits of the answer on screen, counted from its start.
  int painted = 0;

  /// Reads that found the screen's text in what was received / that did not.
  int reads = 0;
  int unread = 0;

  /// Letters and digits received so far.
  int get received => _arrivalUs.length;

  /// A chunk arrived at [us].
  void record(String chunk, int us) {
    final before = _received.length;
    _received.write(_letters(chunk));
    for (var i = before; i < _received.length; i++) {
      _arrivalUs.add(us);
    }
  }

  /// The oldest character that arrived and is not on screen at [nowUs]: how
  /// long it has waited (ms) and how many characters wait.
  ({int lagMs, int pending}) lag(int nowUs) {
    if (painted >= received) return (lagMs: 0, pending: 0);
    return (lagMs: (nowUs - _arrivalUs[painted]) ~/ 1000, pending: received - painted);
  }

  /// Updates [painted] from the render tree under [root]; [screenHeight] is
  /// the window's height in logical pixels (paragraphs outside it are not on
  /// screen). Returns false when no paragraph could be matched.
  bool read(RenderObject? root, double screenHeight) {
    reads++;
    if (_receivedText.length != _received.length) _receivedText = _received.toString();
    final tail = root == null || _receivedText.isEmpty ? null : screenTail(root, screenHeight);
    final index = tail == null ? -1 : _receivedText.indexOf(tail, math.max(0, painted - 96));
    if (index < 0) {
      unread++;
      return false;
    }
    painted = math.max(painted, index + tail!.length);
    return true;
  }

  /// The last letters and digits of the lowest paragraph on screen that is
  /// part of what was received and says where it is: a tail that occurs twice
  /// from [painted] on is skipped. The newest paragraph is often cut mid-line
  /// by the reveal (`nested item` before its number arrives), and a cut that
  /// repeats an earlier line would read as text painted much too early.
  /// This is the one place that knows how text is painted (`RenderParagraph`);
  /// a different text engine changes only this.
  String? screenTail(RenderObject root, double screenHeight) {
    final found = <({double bottom, String text})>[];
    void visit(RenderObject o) {
      if (o is RenderParagraph) {
        if (!o.attached || !o.hasSize) return;
        final top = o.localToGlobal(Offset.zero).dy;
        final bottom = top + o.size.height;
        if (bottom < 0 || top > screenHeight) return;
        found.add((bottom: bottom, text: o.text.toPlainText(includeSemanticsLabels: false)));
        return;
      }
      o.visitChildren(visit);
    }

    visit(root);
    found.sort((a, b) => b.bottom.compareTo(a.bottom));
    for (final p in found) {
      final letters = _letters(p.text);
      if (letters.length < 8) continue;
      final tail = letters.substring(letters.length - math.min(24, letters.length));
      final from = math.max(0, painted - 96);
      final first = _receivedText.indexOf(tail, from);
      if (first >= 0 && _receivedText.indexOf(tail, first + 1) < 0) return tail;
    }
    return null;
  }
}
