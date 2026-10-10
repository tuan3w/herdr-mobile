// The toast system (ui/core/toast.dart): one toast at a time that replaces the
// one showing, durations from one place, undo coalescing, motion, haptics, and
// where it stands (above the tab bar, a form's action bar, or the bottom
// inset).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/shot.dart' show loadAppFonts;

/// The context of the screen the toast is shown from.
late BuildContext _ctx;

Toaster get _toaster => Toaster.of(_ctx);

Widget _app({Widget? home, bool reduceMotion = false}) => MaterialApp(
      theme: AppTheme.light(),
      navigatorObservers: [ToastRouteObserver()],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: home ??
          Scaffold(
            body: Builder(
              builder: (context) {
                _ctx = context;
                return const SizedBox.expand();
              },
            ),
          ),
    );

Future<void> _pump(WidgetTester tester, {bool reduceMotion = false}) async {
  await tester.pumpWidget(_app(reduceMotion: reduceMotion));
}

/// Ends the test with no toast timer left behind.
Future<void> _end(WidgetTester tester) => tester.pumpWidget(const SizedBox());

Finder get _toast => find.byKey(toastKey);

/// Advances the clock by [ms] in 50 ms frames, so timers and animations fire
/// where they would on a device. A frame first, with no time passing: a toast
/// is built (and its clock started) by the frame after it is shown.
Future<void> _ms(WidgetTester tester, int ms) async {
  await tester.pump();
  for (var t = 0; t < ms; t += 50) {
    await tester.pump(Duration(milliseconds: ms - t < 50 ? ms - t : 50));
  }
}

/// Time to let a leaving toast finish its exit.
const _exit = 300;

Widget _tabBarPage() => Scaffold(
      body: Builder(
        builder: (context) {
          _ctx = context;
          return Stack(
            children: [
              const SizedBox.expand(),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: FloatingTabBar(
                  index: 0,
                  onChanged: (_) {},
                  tabs: const [
                    TabSpec(icon: LucideIcons.bot, label: 'Agents'),
                    TabSpec(icon: LucideIcons.settings, label: 'Settings'),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

void main() {
  setUpAll(loadAppFonts);

  group('replacing', () {
    testWidgets('a new toast replaces the one showing: one card, the new text, no queue behind it', (tester) async {
      await _pump(tester);
      _toaster.show('First');
      await _ms(tester, 400);
      _toaster.show('Second');
      await _ms(tester, 400);

      expect(_toast, findsOneWidget);
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);

      // Past the first one's own time nothing of it comes back, and the
      // second one's clock started when it arrived.
      await _ms(tester, 2400);
      expect(find.text('Second'), findsOneWidget, reason: '2.8 s after it arrived, with 3 s to live');
      await _ms(tester, 400);
      await _ms(tester, _exit);
      expect(_toast, findsNothing);
      expect(find.text('First'), findsNothing, reason: 'a replaced toast is not queued');
      await _end(tester);
    });

    testWidgets('a failure takes the place of a toast with an action at once', (tester) async {
      await _pump(tester);
      _toaster.show('Closed tab', action: ToastAction('Undo', () {}));
      await _ms(tester, 400);
      _toaster.show('Could not reach the machine', kind: ToastKind.failed);
      await _ms(tester, 16);

      expect(find.text('Could not reach the machine'), findsOneWidget);
      expect(find.text('Closed tab'), findsNothing);
      expect(find.byKey(toastActionKey), findsNothing);
      await _end(tester);
    });

    testWidgets('a toast that is already leaving comes back with the new text and a full clock', (tester) async {
      await _pump(tester);
      _toaster.show('Old');
      await _ms(tester, 3000);
      await _ms(tester, 100); // mid-exit
      _toaster.show('New');
      await _ms(tester, 400);

      expect(find.text('New'), findsOneWidget);
      await _ms(tester, 2500);
      expect(find.text('New'), findsOneWidget);
      await _ms(tester, 400);
      await _ms(tester, _exit);
      expect(_toast, findsNothing);
      await _end(tester);
    });

    testWidgets('a tap on the toast puts it away', (tester) async {
      await _pump(tester);
      _toaster.show('Copied');
      await _ms(tester, 400);

      await tester.tap(find.text('Copied'));
      await tester.pump();
      await _ms(tester, _exit);
      expect(_toast, findsNothing);
      await _end(tester);
    });

    testWidgets('a sheet opening puts a toast away: it never covers the sheet', (tester) async {
      await _pump(tester);
      _toaster.show('Copied');
      await _ms(tester, 400);

      unawaited(showModalBottomSheet<void>(context: _ctx, builder: (_) => const SizedBox(height: 200)));
      await tester.pump();
      await _ms(tester, _exit);
      expect(_toast, findsNothing);
      await tester.pumpAndSettle();
      await _end(tester);
    });

    testWidgets('a captured Toaster still works after its screen is gone, and is quiet once the app is', (tester) async {
      await _pump(tester);
      Toaster? captured;
      unawaited(Navigator.of(_ctx).push(MaterialPageRoute<void>(
        builder: (context) {
          captured = Toaster.of(context);
          return const Scaffold(body: SizedBox.expand());
        },
      )));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(Scaffold))).pop();
      await tester.pumpAndSettle();

      captured!.show('Still here');
      await _ms(tester, 400);
      expect(find.text('Still here'), findsOneWidget);

      await _end(tester);
      captured!.show('Nobody home'); // must not throw
      await tester.pump();
    });
  });

  group('time on screen', () {
    Future<void> staysUntil(WidgetTester tester, int ms) async {
      await _ms(tester, ms - 100);
      expect(_toast, findsOneWidget, reason: 'still showing at ${ms - 100} ms');
      await _ms(tester, 100);
      await tester.pumpAndSettle(const Duration(milliseconds: 20));
      expect(_toast, findsNothing, reason: 'gone after $ms ms and its exit');
    }

    testWidgets('a plain message: 3 s', (tester) async {
      await _pump(tester);
      _toaster.show('Copied');
      await staysUntil(tester, 3000);
      await _end(tester);
    });

    testWidgets('a toast with an action: 5 s', (tester) async {
      await _pump(tester);
      _toaster.show('Closed tab', action: ToastAction('Undo', () {}));
      await staysUntil(tester, 5000);
      await _end(tester);
    });

    testWidgets('a failure: 5 s', (tester) async {
      await _pump(tester);
      _toaster.show('No browser could open the link.', kind: ToastKind.failed);
      await staysUntil(tester, 5000);
      await _end(tester);
    });

    testWidgets('a success without an action is a plain message: 3 s', (tester) async {
      await _pump(tester);
      _toaster.show('Interrupted 2', kind: ToastKind.success);
      await staysUntil(tester, 3000);
      await _end(tester);
    });

    testWidgets('an explicit duration wins', (tester) async {
      await _pump(tester);
      _toaster.show('Slow', duration: const Duration(seconds: 8));
      await staysUntil(tester, 8000);
      await _end(tester);
    });

    test('the defaults come from one table', () {
      expect(ToastTiming.of(ToastKind.info, hasAction: false), const Duration(seconds: 3));
      expect(ToastTiming.of(ToastKind.success, hasAction: false), const Duration(seconds: 3));
      expect(ToastTiming.of(ToastKind.info, hasAction: true), const Duration(seconds: 5));
      expect(ToastTiming.of(ToastKind.failed, hasAction: false), const Duration(seconds: 5));
    });
  });

  group('actions and undo coalescing', () {
    testWidgets('the action runs once, however often it is tapped, and the toast leaves', (tester) async {
      await _pump(tester);
      var calls = 0;
      _toaster.show('Closed tab', action: ToastAction('Undo', () => calls++));
      await _ms(tester, 400);

      await tester.tap(find.text('Undo'));
      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await _ms(tester, 50);
      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await _ms(tester, _exit);

      expect(calls, 1);
      expect(_toast, findsNothing);
      await _end(tester);
    });

    testWidgets('repeated actions with one groupKey share a toast whose Undo runs them all, latest first',
        (tester) async {
      await _pump(tester);
      final undone = <int>[];
      void review(int i) => _toaster.show(
            'Marked reviewed',
            action: ToastAction('Undo', () => undone.add(i)),
            groupKey: 'review',
            groupMessage: (n) => 'Marked $n reviewed',
          );

      review(1);
      await _ms(tester, 400);
      expect(find.text('Marked reviewed'), findsOneWidget);

      review(2);
      await _ms(tester, 400);
      expect(_toast, findsOneWidget);
      expect(find.text('Marked 2 reviewed'), findsOneWidget);

      review(3);
      await _ms(tester, 400);
      expect(find.text('Marked 3 reviewed'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await _ms(tester, _exit);
      expect(undone, [3, 2, 1], reason: 'every undo ran, once, newest first');
      await _end(tester);
    });

    testWidgets('a call that did several things joins with its count', (tester) async {
      await _pump(tester);
      String say(int n) => 'Marked $n reviewed';
      _toaster.show(say(1), action: ToastAction('Undo', () {}), groupKey: 'review', groupMessage: say);
      await _ms(tester, 400);
      _toaster.show(say(4), action: ToastAction('Undo', () {}), groupKey: 'review', groupMessage: say, count: 4);
      await _ms(tester, 400);
      expect(find.text('Marked 5 reviewed'), findsOneWidget);

      _toaster.show(say(2), action: ToastAction('Undo', () {}), groupKey: 'review', groupMessage: say);
      await _ms(tester, 400);
      expect(find.text('Marked 6 reviewed'), findsOneWidget, reason: 'the weight stays in the total');
      await _end(tester);
    });

    testWidgets('each joining call restarts the clock', (tester) async {
      await _pump(tester);
      void close() => _toaster.show(
            'Closed tab',
            action: ToastAction('Undo', () {}),
            groupKey: 'close',
            groupMessage: (n) => 'Closed $n tabs',
          );
      close();
      await _ms(tester, 4500);
      close();
      await _ms(tester, 4500);
      expect(find.text('Closed 2 tabs'), findsOneWidget, reason: '4.5 s after the second, 9 s after the first');
      await _ms(tester, 700);
      await _ms(tester, _exit);
      expect(_toast, findsNothing);
      await _end(tester);
    });

    testWidgets('once the toast is gone the next call starts a new group of one', (tester) async {
      await _pump(tester);
      final undone = <int>[];
      void review(int i) => _toaster.show(
            'Marked reviewed',
            action: ToastAction('Undo', () => undone.add(i)),
            groupKey: 'review',
            groupMessage: (n) => 'Marked $n reviewed',
          );
      review(1);
      await _ms(tester, 5000);
      await _ms(tester, _exit);
      expect(_toast, findsNothing);

      review(2);
      await _ms(tester, 400);
      expect(find.text('Marked reviewed'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await _ms(tester, _exit);
      expect(undone, [2], reason: 'the expired one is not undone with it');
      await _end(tester);
    });

    testWidgets('a toast already leaving is not joined: its Undo is gone with it', (tester) async {
      await _pump(tester);
      final undone = <int>[];
      void review(int i) => _toaster.show(
            'Marked reviewed',
            action: ToastAction('Undo', () => undone.add(i)),
            groupKey: 'review',
            groupMessage: (n) => 'Marked $n reviewed',
          );
      review(1);
      await _ms(tester, 5000);
      await _ms(tester, 60); // started to leave
      review(2);
      await _ms(tester, 400);

      expect(find.text('Marked reviewed'), findsOneWidget);
      expect(find.text('Marked 2 reviewed'), findsNothing);
      await tester.tap(find.text('Undo'));
      await _ms(tester, _exit);
      expect(undone, [2]);
      await _end(tester);
    });

    testWidgets('different keys, or no key, replace instead of joining', (tester) async {
      await _pump(tester);
      final undone = <String>[];
      _toaster.show(
        'Marked reviewed',
        action: ToastAction('Undo', () => undone.add('review')),
        groupKey: 'review',
        groupMessage: (n) => 'Marked $n reviewed',
      );
      await _ms(tester, 400);
      _toaster.show(
        'Closed tab',
        action: ToastAction('Undo', () => undone.add('close')),
        groupKey: 'close',
        groupMessage: (n) => 'Closed $n tabs',
      );
      await _ms(tester, 400);
      expect(find.text('Closed tab'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await _ms(tester, _exit);
      expect(undone, ['close']);
      await _end(tester);
    });

    testWidgets('without a groupMessage a joined toast shows the newest text', (tester) async {
      await _pump(tester);
      _toaster.show('Copied path', groupKey: 'copy');
      await _ms(tester, 400);
      _toaster.show('Copied link', groupKey: 'copy');
      await _ms(tester, 400);
      expect(find.text('Copied link'), findsOneWidget);
      expect(_toast, findsOneWidget);
      await _end(tester);
    });
  });

  group('motion', () {
    Future<double> topAt(WidgetTester tester, {required bool reduce, required int ms}) async {
      await _pump(tester, reduceMotion: reduce);
      _toaster.show('Copied');
      await tester.pump();
      await _ms(tester, ms);
      final y = tester.getTopLeft(_toast).dy;
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final rest = tester.getTopLeft(_toast).dy;
      await _end(tester);
      return y - rest;
    }

    testWidgets('it slides up into place', (tester) async {
      final offset = await topAt(tester, reduce: false, ms: 30);
      expect(offset, greaterThan(1), reason: 'still below its resting place early in the entry');
    });

    testWidgets('with reduced motion it does not move, it only fades', (tester) async {
      final offset = await topAt(tester, reduce: true, ms: 30);
      expect(offset, 0);
    });

    testWidgets('it is in within 250 ms and out within 190 ms', (tester) async {
      await _pump(tester);
      _toaster.show('Copied', duration: const Duration(seconds: 1));
      await tester.pump();
      await _ms(tester, 250);
      final rest = tester.getTopLeft(_toast).dy;
      await _ms(tester, 16);
      expect(tester.getTopLeft(_toast).dy, rest, reason: 'settled by 250 ms');

      await _ms(tester, 750); // 1 s: starts to leave
      await _ms(tester, 195);
      expect(_toast, findsNothing, reason: 'removed 190 ms after it starts to leave');
      await _end(tester);
    });
  });

  group('haptics', () {
    testWidgets('success is the sent haptic, failed the failed one, info none; once per toast', (tester) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await _pump(tester);

      _toaster.show('Copied');
      await tester.pump();
      expect(haptics, isEmpty);

      _toaster.show('Interrupted 2', kind: ToastKind.success);
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.lightImpact']);

      _toaster.show('Could not reach it', kind: ToastKind.failed);
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.lightImpact', 'HapticFeedbackType.heavyImpact']);
      await _end(tester);
    });
  });

  group('where it stands', () {
    testWidgets('above the tab bar, clear of it', (tester) async {
      await tester.pumpWidget(_app(home: _tabBarPage()));
      await tester.pump();
      _toaster.show('Copied');
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      final bar = tester.getRect(find.byType(FloatingTabBar));
      final toast = tester.getRect(_toast);
      expect(toast.bottom, lessThanOrEqualTo(bar.top));
      expect(toast.bottom, bar.top - 8, reason: 'the bar margin again, above the pill');
      expect(toast.bottom, tester.view.physicalSize.height / tester.view.devicePixelRatio - FloatingBar.clearance(_ctx));
      await _end(tester);
    });

    testWidgets('above the tab bar and the gesture inset on a phone with a navigation area', (tester) async {
      tester.view.padding = const FakeViewPadding(bottom: 68);
      tester.view.viewPadding = const FakeViewPadding(bottom: 68);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(home: _tabBarPage()));
      await tester.pump();
      _toaster.show('Copied');
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      expect(tester.getRect(_toast).bottom, lessThanOrEqualTo(tester.getRect(find.byType(FloatingTabBar)).top));
      await _end(tester);
    });

    testWidgets('on a pushed screen there is no tab bar: it stands on the bottom inset', (tester) async {
      tester.view.padding = const FakeViewPadding(bottom: 68); // 34 dp at 2x
      tester.view.viewPadding = const FakeViewPadding(bottom: 68);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(home: _tabBarPage()));
      await tester.pump();
      final home = _ctx;
      unawaited(Navigator.of(home).push(MaterialPageRoute<void>(
        builder: (context) {
          _ctx = context;
          return const Scaffold(body: SizedBox.expand());
        },
      )));
      await tester.pumpAndSettle();

      _toaster.show('Copied');
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(tester.getRect(_toast).bottom, height - 34 - 16);
      await _end(tester);
    });

    testWidgets('a toast shown on the tab screen steps down when a screen covers the bar', (tester) async {
      await tester.pumpWidget(_app(home: _tabBarPage()));
      await tester.pump();
      final home = _ctx;
      _toaster.show('Copied', duration: const Duration(seconds: 30));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final above = tester.getRect(_toast).bottom;

      unawaited(Navigator.of(home).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: SizedBox.expand()))));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(tester.getRect(_toast).bottom, greaterThan(above), reason: 'no bar left to clear');

      Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(tester.getRect(_toast).bottom, above, reason: 'the bar is back');
      await _end(tester);
    });

    testWidgets('above a bar of its own height, riding on the keyboard when the body shrinks for it', (tester) async {
      tester.view
        ..physicalSize = const Size(800, 1200) // 400 x 600 dp
        ..devicePixelRatio = 2
        ..viewInsets = const FakeViewPadding(bottom: 600); // 300 dp
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              _ctx = context;
              return Column(
                children: const [
                  Expanded(child: SizedBox.expand()),
                  ToastShelf(aboveKeyboard: true, child: SizedBox(height: 120, width: double.infinity, key: Key('bar'))),
                ],
              );
            },
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      _toaster.show('Copied');
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      final bar = tester.getRect(find.byKey(const Key('bar')));
      expect(bar.bottom, 300, reason: 'the bar sits on the keyboard');
      expect(tester.getRect(_toast).bottom, bar.top - 12);
      await _end(tester);
    });

    testWidgets('a bar that grows moves the toast up with it', (tester) async {
      final height = ValueNotifier<double>(60);
      addTearDown(height.dispose);
      await tester.pumpWidget(_app(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              _ctx = context;
              return Column(
                children: [
                  const Expanded(child: SizedBox.expand()),
                  ToastShelf(
                    child: ValueListenableBuilder<double>(
                      valueListenable: height,
                      builder: (_, h, _) => SizedBox(height: h, width: double.infinity, key: const Key('bar')),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
      _toaster.show('Copied', duration: const Duration(seconds: 30));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final before = tester.getRect(_toast).bottom;

      height.value = 160;
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(tester.getRect(_toast).bottom, before - 100);
      await _end(tester);
    });
  });

  group('look and access', () {
    testWidgets('the text is a live region and the action a 44 dp button', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      _toaster.show('Closed tab', action: ToastAction('Undo', () {}));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      final text = tester.getSemantics(find.text('Closed tab'));
      expect(text.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      final action = tester.getSemantics(find.byKey(toastActionKey));
      expect(action.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(action.label, 'Undo');
      expect(tester.getSize(find.byKey(toastActionKey)).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.byKey(toastActionKey)).width, greaterThanOrEqualTo(44));

      // Assistive tech activates it straight away.
      action.owner!.performAction(action.id, SemanticsAction.tap);
      await _ms(tester, _exit);
      expect(_toast, findsNothing);
      handle.dispose();
      await _end(tester);
    });

    testWidgets('no Material snack bar is ever built', (tester) async {
      await _pump(tester);
      _toaster.show('Copied');
      _toaster.show('Closed tab', action: ToastAction('Undo', () {}), kind: ToastKind.success);
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(Material).evaluate().where((e) => e.widget.key == toastKey), isEmpty);
      await _end(tester);
    });

    testWidgets('the message and the button are plain text: no underline from the fallback style', (tester) async {
      // The overlay has no Scaffold above it; without its own Material the
      // text took MaterialApp's fallback, a double yellow underline.
      await _pump(tester);
      _toaster.show('Copied as Markdown', action: ToastAction('Undo', () {}));
      await _ms(tester, 400);
      final texts = tester.widgetList<RichText>(find.descendant(of: _toast, matching: find.byType(RichText)));
      expect(texts, hasLength(2));
      for (final t in texts) {
        final style = (t.text as TextSpan).style!;
        expect(style.decoration ?? TextDecoration.none, TextDecoration.none, reason: t.text.toPlainText());
      }
      await _end(tester);
    });

    testWidgets('long text wraps to two lines and is cut after that; the card stays on a 320 dp phone',
        (tester) async {
      tester.view.physicalSize = const Size(640, 1200);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await _pump(tester);
      final long = List.filled(30, 'một đoạn chữ rất dài').join(' ');
      _toaster.show(long, kind: ToastKind.failed, action: ToastAction('Copy', () {}));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));

      final paragraph = tester.renderObject<RenderParagraph>(find.text(long));
      expect(paragraph.didExceedMaxLines, isTrue);
      expect(paragraph.size.height, lessThan(15 * 1.45 * 2 + 4));
      final card = tester.getRect(_toast);
      expect(card.left, greaterThanOrEqualTo(16));
      expect(card.right, lessThanOrEqualTo(320 - 16));
      expect(tester.takeException(), isNull);
      await _end(tester);
    });

    testWidgets('on a wide screen it stays a narrow card, centred', (tester) async {
      tester.view.physicalSize = const Size(2000, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester);
      _toaster.show('Copied');
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      final card = tester.getRect(_toast);
      expect(card.width, lessThanOrEqualTo(480));
      expect(card.center.dx, 1000);
      await _end(tester);
    });
  });
}
