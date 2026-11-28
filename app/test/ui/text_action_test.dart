// A `TextAction` that may not be taken now (a guard, an answer on its way)
// stays on screen, dimmed, and must still be readable: a dimmed word the person
// cannot make out is a dead end with no reason (AGENTS.md, principle 7).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

double _contrast(Color a, Color b) {
  double lum(Color c) => c.computeLuminance();
  final la = lum(a), lb = lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final brightness in Brightness.values) {
    final ds = brightness == Brightness.dark ? Ds.ink : Ds.paper;
    for (final tone in TextActionTone.values) {
      testWidgets('a disabled ${tone.name} action reaches 3:1 on the page, a sheet and a panel ($brightness)', (
        tester,
      ) async {
        late Color color;
        for (final (name, bg) in [('bg', ds.bg), ('surface', ds.surface), ('fill', ds.fill)]) {
          await tester.pumpWidget(
            MaterialApp(
              theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
              home: Scaffold(
                backgroundColor: bg,
                body: Center(
                  child: TextAction(label: 'Read all', tone: tone, enabled: false, onTap: () {}),
                ),
              ),
            ),
          );
          color = tester.widget<Text>(find.text('Read all')).style!.color!;
          // Composite over the page: a translucent label reads as what it paints.
          final seen = Color.alphaBlend(color, bg);
          expect(_contrast(seen, bg), greaterThanOrEqualTo(3), reason: 'disabled ${tone.name} on $name: $seen');
        }
      });
    }

    testWidgets('a disabled action is still dimmer than an enabled one, and takes no tap ($brightness)', (
      tester,
    ) async {
      var taps = 0;
      Future<Color> pump(bool enabled) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
            home: Scaffold(
              body: Center(
                child: TextAction(label: 'Read all', enabled: enabled, onTap: () => taps++),
              ),
            ),
          ),
        );
        return Color.alphaBlend(tester.widget<Text>(find.text('Read all')).style!.color!, ds.bg);
      }

      final on = await pump(true);
      final off = await pump(false);
      await tester.tap(find.text('Read all'));
      await tester.pump();

      expect(_contrast(off, ds.bg), lessThan(_contrast(on, ds.bg)), reason: 'dim means less than enabled');
      expect(taps, 0);
    });
  }
}
