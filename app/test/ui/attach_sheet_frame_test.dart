// The sheet's physics: it follows the finger 1:1 without laying the grid out
// again, a release hands the finger's velocity to a spring that picks half
// height, full height or away, the grid scrolls only at full height, and the
// keyboard lifts the sheet to full height.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_select.dart';
import 'package:herdr_mobile/ui/features/attach/attach_bars.dart';
import 'package:herdr_mobile/ui/features/attach/attach_kit.dart';
import 'package:herdr_mobile/ui/features/attach/gallery_tab.dart';
import 'package:herdr_mobile/ui/features/attach/sheet_frame.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/files_support.dart';
import '../support/shot.dart' show loadAppFonts;

Future<FakeKit> openSheet(WidgetTester tester, {int photos = 400, bool reduced = false}) async {
  tester.view
    ..physicalSize = const Size(824, 1784)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetViewInsets);
  final fake = FakeKit(gallery: FakeGallery(count: photos));
  final session = FakeAgentSession(machine: machineWithFiles(projectFs()), cwd: '/home/dev/herdr-mobile');
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: reduced), child: child!),
      home: AgentSessionScreen(key: ObjectKey(session), session: session, attachKit: fake.kit),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
  await tester.tap(find.byIcon(LucideIcons.paperclip).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return fake;
}

/// The grid's scrollable (not the transcript's behind the sheet).
ScrollableState grid(WidgetTester tester) =>
    tester.state<ScrollableState>(find.descendant(of: find.byType(GalleryTab), matching: find.byType(Scrollable)).first);

/// Top edge of the album chip (header): moves with the sheet.
double sheetTop(WidgetTester tester) => tester.getTopLeft(find.text('Recent')).dy;

void main() {
  setUpAll(loadAppFonts);
  tearDown(() => debugRegionBuilt = null);

  group('SheetPosition', () {
    Future<(SheetPosition, List<int>)> make(WidgetTester tester) async {
      final dismissed = <int>[];
      final p = SheetPosition(vsync: tester, reduced: () => true, onDismiss: () => dismissed.add(1));
      addTearDown(p.dispose);
      p.layout(full: 800, half: 440); // rests 360 down
      return (p, dismissed);
    }

    testWidgets('starts at half height', (tester) async {
      final (p, _) = await make(tester);
      expect(p.offset.value, 360);
      expect(p.expanded.value, isFalse);
    });

    testWidgets('a slow drag to the middle between the stops settles on the nearer one', (tester) async {
      final (p, d) = await make(tester);
      p.dragBy(-150); // 210: nearer to full (0) than half (360)? 210 is closer to 360
      p.release(0);
      expect(p.offset.value, 360);
      p.dragBy(-200); // 160
      p.release(0);
      expect(p.offset.value, 0);
      expect(p.expanded.value, isTrue);
      expect(d, isEmpty);
    });

    testWidgets('a flick up from half goes to full even from a short drag', (tester) async {
      final (p, _) = await make(tester);
      p.dragBy(-40);
      p.release(-1800);
      expect(p.offset.value, 0);
    });

    testWidgets('a flick down from full goes to half, not away', (tester) async {
      final (p, d) = await make(tester);
      p.expand();
      p.dragBy(60);
      p.release(1600);
      expect(p.offset.value, 360);
      expect(d, isEmpty);
    });

    testWidgets('dragging half height down past the middle of what is left dismisses', (tester) async {
      final (p, d) = await make(tester);
      p.dragBy(250); // 610 of 800: past 360 + 0.45 * 440 = 558
      p.release(0);
      expect(d, [1]);
    });

    testWidgets('a short pull down from half comes back', (tester) async {
      final (p, d) = await make(tester);
      p.dragBy(80);
      p.release(0);
      expect(p.offset.value, 360);
      expect(d, isEmpty);
    });

    testWidgets('a fast flick down from half dismisses even from a short drag', (tester) async {
      final (p, d) = await make(tester);
      p.dragBy(60);
      p.release(2400);
      expect(d, [1]);
    });

    testWidgets('past full height there is only a little give', (tester) async {
      final (p, _) = await make(tester);
      p.expand();
      p.dragBy(-100);
      expect(p.offset.value, inInclusiveRange(-30, 0));
    });

    testWidgets('the room changing (the keyboard) keeps the stop', (tester) async {
      final (p, _) = await make(tester);
      p.expand();
      p.layout(full: 500, half: 440);
      expect(p.offset.value, 0);
    });
  });

  group('in the composer', () {
    testWidgets('opens at about 55% of the screen', (tester) async {
      await openSheet(tester);
      final top = sheetTop(tester);
      // The camera tile sits just below the grabber and the header.
      expect(top, inInclusiveRange(892 * 0.45, 892 * 0.45 + 140));
    });

    testWidgets('follows the finger 1:1 and lays the grid out once', (tester) async {
      await openSheet(tester);
      final before = sheetTop(tester);
      final gridSize = tester.getSize(find.descendant(of: find.byType(GalleryTab), matching: find.byType(CustomScrollView)));
      final built = <String, int>{};
      debugRegionBuilt = (r) => built[r] = (built[r] ?? 0) + 1;
      final g = await tester.startGesture(Offset(206, before - 40));
      var last = before;
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(const Offset(0, 12));
        await tester.pump(const Duration(milliseconds: 16));
        final now = sheetTop(tester);
        // The first move is the touch slop (the drag starts after it); then
        // every 12 dp of the finger is 12 dp of the sheet.
        if (i > 2) expect(now - last, closeTo(12, 0.01), reason: 'step $i: 1:1 with the finger');
        last = now;
      }
      expect(sheetTop(tester) - before, greaterThan(90));
      expect(tester.getSize(find.descendant(of: find.byType(GalleryTab), matching: find.byType(CustomScrollView))), gridSize, reason: 'the grid is translated, never resized');
      expect(built['attach:grid'], isNull, reason: 'no rebuild of the grid during the drag');
      expect(built['attach:tile'], isNull, reason: 'nor of one tile');
      await g.up();
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('a pull down past the threshold closes it; a scrim tap closes it', (tester) async {
      await openSheet(tester);
      await tester.dragFrom(Offset(206, sheetTop(tester) - 40), const Offset(0, 420));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AttachTabBar), findsNothing);

      await tester.tap(find.byIcon(LucideIcons.paperclip).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tapAt(const Offset(200, 60));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AttachTabBar), findsNothing);
    });

    testWidgets('a flick up expands to full height; then the grid scrolls; at the top a pull brings the sheet down', (tester) async {
      await openSheet(tester);
      final half = sheetTop(tester);
      await tester.fling(find.text('Recent'), const Offset(0, -300), 2500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      final full = sheetTop(tester);
      expect(full, lessThan(half - 300), reason: 'now at full height');
      // The grid scrolls now.
      final scroll = grid(tester);
      await tester.drag(find.descendant(of: find.byType(GalleryTab), matching: find.byType(CustomScrollView)), const Offset(0, -400));
      await tester.pump();
      expect(scroll.position.pixels, greaterThan(100));
      // Back to the top, then pull down: the sheet follows and goes to half.
      scroll.position.jumpTo(0);
      await tester.pump();
      await tester.fling(find.descendant(of: find.byType(GalleryTab), matching: find.byType(CustomScrollView)), const Offset(0, 320), 2200);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(sheetTop(tester), closeTo(half, 40), reason: 'half height again, not closed');
      expect(find.byType(AttachTabBar), findsOneWidget);
    });

    testWidgets('at half height the grid does not scroll: the drag moves the sheet', (tester) async {
      await openSheet(tester);
      final scroll = grid(tester);
      await tester.drag(find.text('Recent'), const Offset(0, -60));
      await tester.pump();
      expect(scroll.position.pixels, 0);
    });

    testWidgets('focusing the search field on the Host tab lifts the sheet to full height for the keyboard', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byKey(AttachTabBar.tabKey(AttachTab.host)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final half = tester.getTopLeft(find.textContaining('Find in')).dy;
      tester.view.viewInsets = const FakeViewPadding(bottom: 560);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.getTopLeft(find.textContaining('Find in')).dy, lessThan(half - 150));
      expect(find.byKey(AttachTabBar.tabKey(AttachTab.gallery)), findsNothing, reason: 'the keyboard has the room, the tab bar steps aside');
    });

    testWidgets('reduced motion: a release lands on its stop at once', (tester) async {
      await openSheet(tester, reduced: true);
      final half = sheetTop(tester);
      await tester.dragFrom(Offset(206, half - 40), const Offset(0, -300));
      await tester.pump();
      expect(sheetTop(tester), lessThan(half - 300));
    });
  });
}
