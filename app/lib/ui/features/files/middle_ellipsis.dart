import 'package:flutter/material.dart';

/// How many trailing characters of [name] always stay visible when it is cut
/// in the middle: the extension (`.dart`, `.tar.gz` keeps `.gz`) and four
/// characters before it, so `report.final.test.dart` still ends in
/// `…test.dart`. A name with no extension keeps its last six characters
/// (`build_2026_05_20_b` stays told apart from `…_a`).
int tailLength(List<String> chars) {
  final n = chars.length;
  var dot = -1;
  for (var i = n - 1; i > 0; i--) {
    if (chars[i] == '.') {
      dot = i;
      break;
    }
  }
  final ext = dot > 0 && n - dot <= 9 ? n - dot : 0;
  final keep = ext > 0 ? ext + 4 : 6;
  return keep >= n ? n : keep;
}

/// [text] cut in the MIDDLE with an ellipsis so it fits [maxWidth] on one line
/// in [style], keeping the start and the end (the extension). Whole when it
/// fits. When even the end alone does not fit, the end is cut at its start
/// instead, so the extension is the last thing to go.
String middleEllipsize(String text, double maxWidth, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  );
  double width(String s) {
    painter
      ..text = TextSpan(text: s, style: style)
      ..layout();
    return painter.width;
  }

  try {
    if (!maxWidth.isFinite || width(text) <= maxWidth) return text;
    final chars = text.characters.toList();
    final n = chars.length;
    // Longest head that fits ahead of the ellipsis and a tail of [tail] chars.
    int headFor(int tail) {
      final end = chars.sublist(n - tail).join();
      var lo = 0, hi = n - tail;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (width('${chars.sublist(0, mid).join()}…$end') <= maxWidth) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return width('…$end') <= maxWidth ? lo : -1;
    }

    final keep = tailLength(chars);
    for (var tail = keep; tail > 0; tail = tail > 4 ? tail - 2 : tail - 1) {
      if (tail >= n) break;
      final head = headFor(tail);
      // A head of nothing is `…name.dart`: fine, the end is what matters.
      if (head >= 0) return '${chars.sublist(0, head).join()}…${chars.sublist(n - tail).join()}';
    }
    // Not even `…` and a few characters fit: take the end that does.
    var lo = 1, hi = n;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (width('…${chars.sublist(mid).join()}') <= maxWidth) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return '…${chars.sublist(lo).join()}';
  } finally {
    painter.dispose();
  }
}

/// One line of a name that never loses its extension: cut in the middle when
/// it does not fit ([middleEllipsize]). Screen readers get the whole name.
class MiddleEllipsisText extends StatelessWidget {
  const MiddleEllipsisText(this.text, {super.key, required this.style});

  final String text;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) => Text(
          middleEllipsize(text, box.maxWidth, style, scaler),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: style,
        ),
      ),
    );
  }
}
