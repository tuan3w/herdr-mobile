import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_cells.dart';

import 'support/shot.dart' show loadAppFonts;

void main() {
  setUpAll(loadAppFonts);

  test('Japanese fallback preserves the terminal grid beside Latin and box drawing', () {
    final metrics = CellMetrics.measure(13, 2.625);
    for (final sample in {'A日本B': 6, '直骨令': 6, 'ｶﾀｶﾅ': 4, '│日本│': 6}.entries) {
      final text = TextPainter(
        text: TextSpan(text: sample.key, style: metrics.textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(text.width, closeTo(metrics.advance * sample.value, 0.05), reason: sample.key);
      text.dispose();
    }
  });
}
