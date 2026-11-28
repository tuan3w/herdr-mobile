// Keyboard access to every control built on `PressBuilder` (a hardware keyboard
// on a tablet, a Chromebook or a desktop build): Tab reaches it, Enter and
// Space press it, and a ring says where the focus is, but only for a person
// using the keyboard, never while they touch.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

Widget _app(List<Widget> children, {Brightness brightness = Brightness.light}) => MaterialApp(
  theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
  home: Scaffold(
    body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  ),
);

Widget _press(String label, {VoidCallback? onTap, VoidCallback? onLongPress, Widget? child}) => PressBuilder(
  onTap: onTap,
  onLongPress: onLongPress,
  minTapSize: kMinTap,
  builder: (context, pressed) => child ?? Text(label),
);

Finder _ring(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(PressBuilder)),
  matching: find.byKey(PressBuilder.focusRingKey),
);

/// Whether the control draws its focus ring right now.
bool _ringShows(WidgetTester tester, String label) {
  final finder = _ring(label);
  if (finder.evaluate().isEmpty) return false;
  final paint = tester.widget<CustomPaint>(finder);
  return paint.foregroundPainter != null;
}

void main() {
  group('keyboard activation', () {
    testWidgets('Tab reaches a control, Enter presses it once and Space presses it once', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app([_press('Open', onTap: () => taps++)]));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(taps, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(taps, 2);
    });

    testWidgets('a held key does not press again and again', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app([_press('Open', onTap: () => taps++)]));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);

      expect(taps, 1);
    });

    testWidgets('Tab goes through the controls in the order they are drawn', (tester) async {
      final order = <String>[];
      await tester.pumpWidget(
        _app([
          _press('One', onTap: () => order.add('One')),
          _press('Two', onTap: () => order.add('Two')),
          _press('Three', onTap: () => order.add('Three')),
        ]),
      );
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      }
      expect(order, ['One', 'Two', 'Three']);
    });

    testWidgets('a control with no tap is skipped: a dead stop teaches nothing', (tester) async {
      var taps = 0;
      var holds = 0;
      await tester.pumpWidget(
        _app([_press('Off'), _press('Hold only', onLongPress: () => holds++), _press('On', onTap: () => taps++)]),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(taps, 1, reason: 'the first stop is the one with a tap');
      // A hold has no key: it stays a touch gesture.
      expect(holds, 0);
    });

    testWidgets('a control that is disabled while focused stops answering the keys', (tester) async {
      var taps = 0;
      final enabled = ValueNotifier(true);
      await tester.pumpWidget(
        _app([
          ValueListenableBuilder<bool>(
            valueListenable: enabled,
            builder: (context, on, _) => _press('Go', onTap: on ? () => taps++ : null),
          ),
        ]),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      enabled.value = false;
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(taps, 0);
    });

    testWidgets('typing in a field inside a control is not a press of the control', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _app([
          PressBuilder(
            onTap: () => taps++,
            builder: (context, pressed) => const SizedBox(width: 200, child: TextField()),
          ),
        ]),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(taps, 0);
    });

    testWidgets('a control inside a pressable row takes the key itself; the row does not also fire', (tester) async {
      var row = 0;
      var inner = 0;
      await tester.pumpWidget(
        _app([
          PressBuilder(
            onTap: () => row++,
            builder: (context, pressed) => Row(
              children: [
                const Text('Row'),
                _press('Inner', onTap: () => inner++),
              ],
            ),
          ),
        ]),
      );
      // First stop is the row, second the control inside it.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);

      expect(inner, 1);
      expect(row, 0);
    });

    testWidgets('a pointer tap still presses on release, and shows no ring', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_app([_press('Open', onTap: () => taps++)]));
      await tester.tap(find.text('Open'));
      await tester.pump();

      expect(taps, 1);
      expect(_ringShows(tester, 'Open'), isFalse, reason: 'a touch never shows the ring');
    });
  });

  group('the focus ring', () {
    for (final brightness in Brightness.values) {
      testWidgets('shows for the keyboard, in the accent, and not before ($brightness)', (tester) async {
        await tester.pumpWidget(_app([_press('Open', onTap: () {})], brightness: brightness));
        expect(_ringShows(tester, 'Open'), isFalse, reason: 'nothing is focused yet');

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();

        expect(_ringShows(tester, 'Open'), isTrue);
        expect(
          tester.renderObject(_ring('Open')),
          paints..rrect(color: (brightness == Brightness.dark ? Ds.ink : Ds.paper).accent),
        );
      });
    }

    testWidgets('moves with Tab: one control has it at a time', (tester) async {
      await tester.pumpWidget(_app([_press('One', onTap: () {}), _press('Two', onTap: () {})]));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect([_ringShows(tester, 'One'), _ringShows(tester, 'Two')], [true, false]);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect([_ringShows(tester, 'One'), _ringShows(tester, 'Two')], [false, true]);
    });

    testWidgets('a touch takes the ring away at once, and the next key brings it back', (tester) async {
      await tester.pumpWidget(_app([_press('One', onTap: () {}), _press('Two', onTap: () {})]));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_ringShows(tester, 'One'), isTrue);

      await tester.tap(find.text('Two'));
      await tester.pump();
      expect(_ringShows(tester, 'One'), isFalse, reason: 'the person is touching now');
      expect(_ringShows(tester, 'Two'), isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_ringShows(tester, 'One') || _ringShows(tester, 'Two'), isTrue);
    });

    testWidgets('it does not change the layout or the 44 dp hit area', (tester) async {
      await tester.pumpWidget(_app([_press('Open', onTap: () {})]));
      final before = tester.getSize(find.byType(PressBuilder));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(tester.getSize(find.byType(PressBuilder)), before);
      expect(before.height, greaterThanOrEqualTo(kMinTap));
    });

    testWidgets('it does not rebuild or reset what is inside the control', (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        _app([
          PressBuilder(
            onTap: () {},
            builder: (context, pressed) {
              builds++;
              return const _Counter();
            },
          ),
        ]),
      );
      await tester.tap(find.byType(_Counter));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(find.text('1'), findsOneWidget, reason: 'the ring is drawn over the child, it never remounts it');
      expect(builds, greaterThan(0));
    });
  });

  group('assistive technology', () {
    testWidgets('the control is still one button node with its own label, and the key adds none', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _app([
          PressBuilder(
            onTap: () {},
            semanticLabel: 'Open the board',
            builder: (context, pressed) => const Text('Board'),
          ),
        ]),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(find.bySemanticsLabel('Open the board'), findsOneWidget);
      final data = tester.getSemantics(find.bySemanticsLabel('Open the board'));
      expect(data.flagsCollection.isButton, isTrue);
      expect(find.bySemanticsLabel('Board'), findsNothing, reason: 'the label replaces the child, once');
      handle.dispose();
    });
  });
}

/// Keeps a count in its own state: a remount would reset it.
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;

  @override
  Widget build(BuildContext context) => GestureDetector(onTapDown: (_) => setState(() => n++), child: Text('$n'));
}
