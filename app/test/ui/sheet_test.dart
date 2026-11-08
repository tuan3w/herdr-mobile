// Every sheet's physics: where a release goes, the rubber band above full
// height, a close that can be caught, the half height of a tall sheet and the
// scroll that hands its drags to the sheet, the buttons that stay in reach,
// and the keyboard the sheet stands on.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import '../support/shot.dart' show loadAppFonts;

const _screen = Size(412, 892);

Future<void> _open(WidgetTester tester, WidgetBuilder builder) async {
  tester.view
    ..physicalSize = _screen
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => ColoredBox(
          color: context.ds.bg,
          child: Center(
            child: GestureDetector(
              onTap: () => showAppSheet<void>(context, builder: builder),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester) => tester.getRect(find.byType(SheetSurface)).top;
bool _isOpen() => find.byType(SheetSurface).evaluate().isNotEmpty;

Widget _short(BuildContext _) =>
    const SheetScaffold(title: 'Short', kind: SheetKind.message, child: SizedBox(height: 260));

Widget _long(BuildContext _) => SheetScaffold(
  title: 'Long',
  kind: SheetKind.list,
  scrolls: true,
  child: ListView.builder(itemCount: 80, itemBuilder: (context, i) => SizedBox(height: 48, child: Text('line $i'))),
);

void main() {
  setUpAll(loadAppFonts);

  group('SheetMath.target', () {
    double t(double y, double v, {double rest = 0, double away = 400}) =>
        SheetMath.target(y: y, velocity: v, rest: rest, away: away);

    test('a flick up goes to full height from anywhere', () {
      expect(t(300, -800), 0);
      expect(t(600, -800, rest: 360, away: 800), 0, reason: 'past half too: one throw, not two');
    });

    test('a flick down closes from the lowest stop, and lands on it from above', () {
      expect(t(20, 800), 400);
      expect(t(60, 1600, rest: 360, away: 800), 360, reason: 'from full: half first');
      expect(t(420, 600, rest: 360, away: 800), 800);
    });

    test('a slow release goes by where it would stop, not where it was let go', () {
      expect(t(150, 0), 0, reason: 'short of the threshold (180): back');
      expect(t(190, 0), 400, reason: 'past it: away');
      expect(t(100, 400), 400, reason: 'a quick short throw projects past it');
      expect(t(210, 0, rest: 360, away: 800), 360, reason: 'nearer half than full');
      expect(t(160, 0, rest: 360, away: 800), 0);
    });

    test('above full height it gives with resistance and never past the stretch', () {
      expect(SheetMath.shown(10, 400), 10);
      expect(SheetMath.shown(900, 400), 400, reason: 'never below the screen');
      var last = 0.0;
      for (final pull in [10.0, 50.0, 200.0, 5000.0]) {
        final shown = -SheetMath.shown(-pull, 400);
        expect(shown, greaterThan(last));
        expect(shown, lessThan(SheetMath.stretch));
        last = shown;
      }
    });
  });

  group('SheetPosition', () {
    SheetPosition make(WidgetTester tester, {bool reduced = true, List<int>? dismissed}) {
      final p = SheetPosition(vsync: tester, reduced: () => reduced, onDismiss: () => dismissed?.add(1));
      addTearDown(p.dispose);
      p.layout(full: 800, half: 440); // rests 360 down
      return p;
    }

    testWidgets('starts at half height and keeps its stop when the room changes', (tester) async {
      final p = make(tester);
      expect(p.offset.value, 360);
      p.expand();
      p.layout(full: 500, half: 440);
      expect(p.offset.value, 0);
    });

    testWidgets('a sheet with one stop rests at full height', (tester) async {
      final p = SheetPosition(vsync: tester, reduced: () => true, onDismiss: () {});
      addTearDown(p.dispose);
      p.layout(full: 400);
      expect(p.offset.value, 0);
      expect(p.restHalf, 0);
    });

    testWidgets('a short pull comes back, a long one or a flick closes', (tester) async {
      final dismissed = <int>[];
      final p = make(tester, dismissed: dismissed);
      p.dragBy(80);
      p.release(0);
      expect(p.offset.value, 360);
      p.dragBy(60);
      p.release(2400);
      expect(dismissed, [1]);
    });

    testWidgets('a sheet thrown away can be caught on its way out and brought back', (tester) async {
      final dismissed = <int>[];
      final p = make(tester, reduced: false, dismissed: dismissed);
      p.dragBy(300); // 660 of 800
      p.release(0);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      final caught = p.offset.value;
      expect(caught, greaterThan(660));
      expect(caught, lessThan(800));
      p.grab();
      await tester.pump(const Duration(milliseconds: 50));
      expect(p.offset.value, caught, reason: 'the finger stops it where it is');
      p.dragBy(-400);
      p.release(0);
      await tester.pumpAndSettle();
      expect(p.offset.value, 360, reason: 'back to half, its nearer stop');
      expect(dismissed, isEmpty);
    });
  });

  group('an app sheet', () {
    testWidgets('a short one opens whole; a slow short pull comes back, a flick closes it', (tester) async {
      await _open(tester, _short);
      final rest = _top(tester);
      final height = _screen.height - rest;
      await tester.timedDragFrom(Offset(206, rest + 20), Offset(0, height * 0.3), const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(_top(tester), closeTo(rest, 0.5));
      await tester.flingFrom(Offset(206, rest + 20), const Offset(0, 50), 1500);
      await tester.pumpAndSettle();
      expect(_isOpen(), isFalse);
    });

    testWidgets('dragged up past full height it gives a little and springs back', (tester) async {
      await _open(tester, _short);
      final rest = _top(tester);
      final g = await tester.startGesture(Offset(206, rest + 20));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, -30));
        await tester.pump(const Duration(milliseconds: 16));
      }
      final lifted = rest - _top(tester);
      expect(lifted, greaterThan(5));
      expect(lifted, lessThan(SheetMath.stretch));
      await g.up();
      await tester.pumpAndSettle();
      expect(_top(tester), closeTo(rest, 0.5));
    });

    testWidgets('caught while it closes, it comes back under the finger', (tester) async {
      await _open(tester, _short);
      final rest = _top(tester);
      await tester.flingFrom(Offset(206, rest + 20), const Offset(0, 60), 1500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      final leaving = _top(tester);
      expect(leaving, greaterThan(rest + 60));
      expect(leaving, lessThan(_screen.height - 40));
      final g = await tester.startGesture(Offset(206, leaving + 20));
      await tester.pump(const Duration(milliseconds: 100));
      expect(_top(tester), closeTo(leaving, 0.5), reason: 'stopped where the finger landed');
      await g.up();
      await tester.pumpAndSettle();
      expect(_isOpen(), isTrue);
      expect(_top(tester), closeTo(rest, 0.5));
    });

    testWidgets('a tall one opens at half; up shows it all, then the list scrolls; from its top a pull comes down', (
      tester,
    ) async {
      await _open(tester, _long);
      final half = _top(tester);
      expect(half, greaterThan(_screen.height * 0.3), reason: 'about half the screen shows');
      expect(find.text('line 0'), findsOneWidget);
      await tester.timedDragFrom(Offset(206, half + 200), const Offset(0, -500), const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      final full = _top(tester);
      expect(full, lessThan(half - 200));
      final list = tester.state<ScrollableState>(find.byType(Scrollable));
      expect(list.position.pixels, greaterThan(0), reason: 'what the sheet did not take scrolled the list');
      list.position.jumpTo(0);
      await tester.pump();
      await tester.timedDragFrom(Offset(206, full + 200), const Offset(0, 240), const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
      expect(_top(tester), closeTo(half, 1), reason: 'half height again, not closed');
    });

    testWidgets('a tall one keeps its buttons on the screen at half height', (tester) async {
      await _open(
        tester,
        (_) => SheetScaffold(
          title: 'Tall',
          kind: SheetKind.form,
          actions: [AppButton(label: 'Save', expand: true, onPressed: () {})],
          child: const SizedBox(height: 1200),
        ),
      );
      final half = _top(tester);
      expect(half, greaterThan(_screen.height * 0.3));
      final save = tester.getRect(find.text('Save'));
      expect(save.bottom, lessThan(_screen.height));
      expect(save.top, greaterThan(half));
      await tester.tap(find.text('Save'));
    });

    testWidgets('a form stands on the keyboard', (tester) async {
      await _open(tester, (_) => const SheetScaffold(title: 'Rename', kind: SheetKind.form, child: TextField()));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(SheetSurface)).bottom, closeTo(_screen.height - 300, 0.5));
    });

    testWidgets('a tap on the scrim closes it once it is up', (tester) async {
      await _open(tester, _short);
      await tester.tapAt(const Offset(206, 40));
      await tester.pumpAndSettle();
      expect(_isOpen(), isFalse);
    });
  });
}
