import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/settings/app_switch.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/shot.dart' show loadAppFonts;

/// A notifier whose permission dialog the test answers by hand.
class _AskingNotifier extends NullNotifier {
  _AskingNotifier({this.current = NotifyPermission.granted});

  /// What Android allows without asking.
  NotifyPermission current;

  int asked = 0;
  Completer<NotifyPermission>? answer;

  @override
  Future<NotifyPermission> permission() async => current;

  @override
  Future<NotifyPermission> requestPermission() {
    asked++;
    return (answer = Completer<NotifyPermission>()).future;
  }
}

const _title = 'Notify me when an agent needs me';
const _alsoTitle = 'Also when an agent finishes';
const _blockedLine = 'Android is blocking notifications for herdr. '
    'Allow them in the system settings for this app.';

Future<NotificationSettings> _pump(
  WidgetTester tester,
  Notifier notifier, {
  NotificationChoice choice = const NotificationChoice(),
  double width = 360,
  double height = 1800,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  MemoryNotificationStore? store,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final settings = NotificationSettings(store ?? MemoryNotificationStore(choice));
  await settings.load();
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: AppSettings(MemoryAppSettingsStore())),
        ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
        ChangeNotifierProvider.value(value: settings),
        Provider<Notifier>.value(value: notifier),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const SettingsScreen(),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return settings;
}

Finder _row(String title) => find.widgetWithText(SwitchRow, title);

SwitchRow _rowWidget(WidgetTester tester, String title) => tester.widget<SwitchRow>(_row(title));

Future<void> _tap(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title));
  await tester.pump();
  await tester.tap(find.text(title));
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('the section replaces the ntfy instructions and starts off', (tester) async {
    final settings = await _pump(tester, _AskingNotifier());
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Alerts'), findsNothing);
    expect(find.textContaining('ntfy'), findsNothing);
    expect(_rowWidget(tester, _title).value, isFalse);
    expect(_rowWidget(tester, _alsoTitle).value, isFalse);
    expect(settings.enabled, isFalse);
    expect(find.textContaining('Notifications clear when you open the app.'), findsOneWidget);
    expect(find.text(_blockedLine), findsNothing);
  });

  testWidgets('turning it on asks Android first, and only a yes turns it on', (tester) async {
    final notifier = _AskingNotifier();
    final store = MemoryNotificationStore();
    final settings = await _pump(tester, notifier, store: store);

    await _tap(tester, _title);
    expect(notifier.asked, 1);
    expect(settings.enabled, isFalse, reason: 'not before the person answered');
    expect(_rowWidget(tester, _title).value, isFalse);

    notifier.answer!.complete(NotifyPermission.granted);
    await tester.pump(const Duration(milliseconds: 300));
    expect(settings.enabled, isTrue);
    expect(store.choice.enabled, isTrue);
    expect(_rowWidget(tester, _title).value, isTrue);
    expect(find.text(_blockedLine), findsNothing);
  });

  testWidgets('a no leaves it off, says why, and a later yes clears the line', (tester) async {
    final notifier = _AskingNotifier();
    final store = MemoryNotificationStore();
    final settings = await _pump(tester, notifier, store: store);

    await _tap(tester, _title);
    notifier.answer!.complete(NotifyPermission.denied);
    await tester.pump(const Duration(milliseconds: 300));
    expect(settings.enabled, isFalse);
    expect(store.choice.enabled, isFalse, reason: 'nothing saved');
    expect(_rowWidget(tester, _title).value, isFalse);
    expect(find.text(_blockedLine), findsOneWidget);

    await _tap(tester, _title);
    expect(notifier.asked, 2, reason: 'it asks again');
    notifier.answer!.complete(NotifyPermission.granted);
    await tester.pump(const Duration(milliseconds: 300));
    expect(settings.enabled, isTrue);
    expect(find.text(_blockedLine), findsNothing);
  });

  testWidgets('a second tap while the dialog is open does not ask twice', (tester) async {
    final notifier = _AskingNotifier();
    await _pump(tester, notifier);
    await _tap(tester, _title);
    await _tap(tester, _title);
    expect(notifier.asked, 1);
    notifier.answer!.complete(NotifyPermission.granted);
    await tester.pump();
  });

  testWidgets('turning it off needs no permission and clears the line', (tester) async {
    final notifier = _AskingNotifier(current: NotifyPermission.denied);
    final settings = await _pump(
      tester,
      notifier,
      choice: const NotificationChoice(enabled: true, alsoDone: true),
    );
    expect(find.text(_blockedLine), findsOneWidget, reason: 'on, but Android blocks them since');

    await _tap(tester, _title);
    expect(notifier.asked, 0);
    expect(settings.enabled, isFalse);
    expect(settings.alsoDone, isFalse);
    expect(find.text(_blockedLine), findsNothing);
  });

  testWidgets('a permission that is still granted shows no line when it was left on', (tester) async {
    await _pump(tester, _AskingNotifier(), choice: const NotificationChoice(enabled: true));
    expect(_rowWidget(tester, _title).value, isTrue);
    expect(find.text(_blockedLine), findsNothing);
  });

  group('"Also when an agent finishes"', () {
    testWidgets('is dimmed and inert while the first switch is off', (tester) async {
      final settings = await _pump(tester, _AskingNotifier());
      expect(_rowWidget(tester, _alsoTitle).enabled, isFalse);
      final dimmed = find.descendant(of: _row(_alsoTitle), matching: find.byType(Opacity));
      expect(tester.widget<Opacity>(dimmed).opacity, lessThan(1));

      await tester.ensureVisible(find.text(_alsoTitle));
      await tester.tap(find.text(_alsoTitle), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(settings.alsoDone, isFalse);
      expect(_rowWidget(tester, _alsoTitle).value, isFalse);
    });

    testWidgets('is announced as unavailable while off, and as a plain switch once on', (tester) async {
      final handle = tester.ensureSemantics();
      final notifier = _AskingNotifier();
      await _pump(tester, notifier);
      final off = tester.getSemantics(find.text(_alsoTitle));
      expect(off.label, contains(_alsoTitle));
      expect(off.flagsCollection.isEnabled, Tristate.isFalse);
      expect(off.flagsCollection.isToggled, Tristate.isFalse);

      await _tap(tester, _title);
      notifier.answer!.complete(NotifyPermission.granted);
      await tester.pump(const Duration(milliseconds: 300));
      final on = tester.getSemantics(find.text(_alsoTitle));
      expect(on.flagsCollection.isEnabled, isNot(Tristate.isFalse));
      expect(on.flagsCollection.isButton, isFalse);
      expect(
        find.descendant(of: _row(_alsoTitle), matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1)),
        findsNothing,
        reason: 'no dimming layer once it is usable',
      );
      handle.dispose();
    });

    testWidgets('works once notifications are on', (tester) async {
      final store = MemoryNotificationStore(const NotificationChoice(enabled: true));
      final settings = await _pump(tester, _AskingNotifier(), store: store);
      await _tap(tester, _alsoTitle);
      expect(settings.alsoDone, isTrue);
      expect(store.choice.alsoDone, isTrue);
      expect(_rowWidget(tester, _alsoTitle).value, isTrue);

      await _tap(tester, _title);
      expect(settings.alsoDone, isFalse, reason: 'it follows the first switch');
      expect(_rowWidget(tester, _alsoTitle).value, isFalse);
      expect(_rowWidget(tester, _alsoTitle).enabled, isFalse);
    });
  });

  testWidgets('the first switch is one node: label, toggled, not a button', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _AskingNotifier());
    final node = tester.getSemantics(_row(_title));
    expect(node.label, contains(_title));
    expect(node.flagsCollection.isButton, isFalse);
    expect(node.flagsCollection.isToggled, Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('the blocked line is announced when it appears', (tester) async {
    final handle = tester.ensureSemantics();
    final notifier = _AskingNotifier();
    await _pump(tester, notifier);
    await _tap(tester, _title);
    notifier.answer!.complete(NotifyPermission.denied);
    await tester.pump(const Duration(milliseconds: 300));
    final node = tester.getSemantics(find.text(_blockedLine));
    expect(node.label, _blockedLine);
    expect(node.flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('320 dp at 2x text: no overflow, 44 dp targets, nothing clipped (${brightness.name})',
        (tester) async {
      final notifier = _AskingNotifier();
      await _pump(
        tester,
        notifier,
        width: 320,
        height: 640,
        textScale: 2,
        brightness: brightness,
      );
      await _tap(tester, _title);
      notifier.answer!.complete(NotifyPermission.denied);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);

      for (final text in [_title, _alsoTitle, _blockedLine]) {
        await tester.ensureVisible(find.text(text));
        await tester.pump();
        final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
        expect(paragraph.didExceedMaxLines, isFalse, reason: text);
      }
      for (final row in [_title, _alsoTitle]) {
        final size = tester.getSize(_row(row));
        expect(size.height, greaterThanOrEqualTo(44), reason: row);
        expect(size.width, greaterThanOrEqualTo(44), reason: row);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
