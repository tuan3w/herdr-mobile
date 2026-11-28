// The contrast the design tokens promise (comments in `tokens.dart`,
// "Colour roles" in `docs/DESIGN.md`), measured. A promise that nobody measures
// drifts: the dark terminal's black was documented at >= 4.5:1 and was 1.96:1,
// and the pressed key's label was 4.19:1 under the same words.
//
// Floors: text 4.5:1 (WCAG 1.4.3), shapes, icons and control edges 3:1 (1.4.11).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

/// WCAG contrast ratio.
double contrast(Color a, Color b) {
  double lum(Color c) {
    double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  final la = lum(a), lb = lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final ds in [Ds.paper, Ds.ink]) {
    final name = ds.isDark ? 'ink' : 'paper';
    final surfaces = {'bg': ds.bg, 'surface': ds.surface, 'fill': ds.fill, 'fillPressed': ds.fillPressed};

    test('$name: the three text tiers reach 4.5:1 on bg, surface, fill and fillPressed', () {
      // fillPressed is what a pressed key, chip or control paints under its
      // label: the label must not dim while it is touched.
      for (final MapEntry(key: on, value: bg) in surfaces.entries) {
        for (final (tier, c) in [('text', ds.text), ('textSecondary', ds.textSecondary), ('textMuted', ds.textMuted)]) {
          expect(contrast(c, bg), greaterThanOrEqualTo(4.5), reason: '$tier on $on');
        }
      }
    });

    test('$name: status words reach 4.5:1 on bg, surface and fill', () {
      for (final MapEntry(key: on, value: bg) in surfaces.entries) {
        if (on == 'fillPressed') continue;
        for (final (word, c) in [('blockedText', ds.blockedText), ('dangerText', ds.dangerText)]) {
          expect(contrast(c, bg), greaterThanOrEqualTo(4.5), reason: '$word on $on');
        }
      }
    });

    test('$name: textTertiary (icons, chevrons, the switch when off) reaches 3:1 on bg, surface and fill', () {
      for (final on in ['bg', 'surface', 'fill']) {
        expect(contrast(ds.textTertiary, surfaces[on]!), greaterThanOrEqualTo(3), reason: 'textTertiary on $on');
      }
    });

    test('$name: the edge of a field reaches 3:1 on surface', () {
      expect(contrast(ds.controlBorder, ds.surface), greaterThanOrEqualTo(3));
    });

    test('$name: added lines read as text on the page and on a panel', () {
      for (final bg in [ds.bg, ds.surface, ds.fill]) {
        expect(contrast(ds.addedText, bg), greaterThanOrEqualTo(4.5));
      }
    });

    test('$name: the toast is readable: words, action, and the kind marks as shapes', () {
      expect(contrast(ds.onInverse, ds.inverseSurface), greaterThanOrEqualTo(4.5));
      expect(contrast(ds.inverseAccent, ds.inverseSurface), greaterThanOrEqualTo(4.5));
      for (final c in [ds.done, ds.danger]) {
        expect(contrast(c, ds.inverseSurface), greaterThanOrEqualTo(3));
      }
      // The status words are never drawn on the inverse surface (a failed
      // toast says it in `onInverse` with a `danger` mark), so their contrast
      // there is not a promise; the dark ones happen to hold it too.
      if (ds.isDark) {
        expect(contrast(ds.dangerText, ds.inverseSurface), greaterThanOrEqualTo(4.5));
      }
    });
  }

  test('selected output on the dark terminal keeps 7:1 with its text', () {
    final terminal = TerminalPalette.dark;
    final over = Color.alphaBlend(terminal.selection, terminal.background);
    expect(contrast(terminal.foreground, over), greaterThanOrEqualTo(7));
  });
}
