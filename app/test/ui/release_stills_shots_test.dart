// Renders the screens the 0.1.64 and 0.1.66 release notes talk about to PNGs:
// Settings > Agents with `Stay connected when away`, a new chat with the `/`
// chip first, and a selection that covers inline code. Light and dark (`-dark`), 412 dp
// wide. Off by default; it writes files:
//
//   RELEASE_STILLS=1 flutter test test/ui/release_stills_shots_test.dart
//
// Then look at every PNG (`/tmp/release_stills`, or RELEASE_STILLS_DIR) before
// it goes into a release. The fleet and the text are invented.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_notifier.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart' show loadAppFonts;

void main() {
  if (Platform.environment['RELEASE_STILLS'] == null) {
    test('release stills are off (set RELEASE_STILLS=1)', () {}, skip: 'set RELEASE_STILLS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['RELEASE_STILLS_DIR'] ?? '/tmp/release_stills';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  const dpr = 2.625;
  const size = Size(412, 892);

  void phone(WidgetTester tester) {
    tester.view
      ..physicalSize = size * dpr
      ..devicePixelRatio = dpr
      ..padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr)
      ..viewPadding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    addTearDown(tester.view.reset);
  }

  var dark = false;

  Widget framed(GlobalKey key, Widget home) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    builder: (context, child) => RepaintBoundary(key: key, child: child!),
    home: home,
  );

  Future<void> snap(WidgetTester tester, GlobalKey key, String name) async {
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$out/$name${dark ? '-dark' : ''}.png').writeAsBytes(data!.buffer.asUint8List());
    });
  }

  for (final mode in const [false, true])
    group(mode ? 'dark' : 'light', () {
      setUp(() => dark = mode);

      testWidgets('settings: Stay connected when away', (tester) async {
        phone(tester);
        final key = GlobalKey();
        final notifications = NotificationSettings(MemoryNotificationStore());
        await notifications.load();
        final phrases = QuickPhrases(MemoryQuickPhrasesStore(const ['continue', 'run the tests']));
        await phrases.load();
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(
                create: (_) => AppSettings(MemoryAppSettingsStore(dark ? ThemeChoice.dark : null)),
              ),
              ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
              ChangeNotifierProvider.value(value: notifications),
              ChangeNotifierProvider.value(value: phrases),
              Provider<Notifier>.value(value: const NullNotifier()),
            ],
            child: framed(key, const SettingsScreen()),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await openSettingsGroup(tester, 'Agents');
        await tester.pump(const Duration(milliseconds: 400));
        await snap(tester, key, 'settings-stay-connected');
      });

      testWidgets('chat: mode and model chips, and `/` first', (tester) async {
        phone(tester);
        final key = GlobalKey();
        final session = FakeAgentSession(
          title: 'Fix payments',
          state: stateWith(
            commands: const [
              AcpCommand(name: 'review', description: 'Review the change'),
              AcpCommand(name: 'compact', description: 'Summarise the chat'),
            ],
            options: const [
              SelectConfigOption(
                id: 'mode',
                name: 'Approval mode',
                category: 'mode',
                value: 'ask',
                choices: [
                  ConfigChoice(value: 'ask', name: 'Ask'),
                  ConfigChoice(value: 'auto', name: 'Auto'),
                ],
              ),
              SelectConfigOption(
                id: 'model',
                name: 'Model',
                category: 'model',
                value: 'sonnet',
                choices: [
                  ConfigChoice(value: 'sonnet', name: 'Sonnet'),
                  ConfigChoice(value: 'opus', name: 'Opus'),
                ],
              ),
            ],
          ),
        );
        final phrases = QuickPhrases(
          MemoryQuickPhrasesStore(const ['continue', 'run the tests', 'summarise what you did']),
        );
        await phrases.load();
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: phrases,
            child: framed(key, AgentSessionScreen(key: ObjectKey(session), session: session)),
          ),
        );
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byType(TextField).last);
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        await snap(tester, key, 'chat-slash-chip');
      });

      testWidgets('chat: a selection covers the inline code in it', (tester) async {
        phone(tester);
        final key = GlobalKey();
        final session = FakeAgentSession(
          title: 'IgIntegrate',
          state: stateWith(
            items: [
              userMsg('u1', 'What did you find in the files you do not own?'),
              agentMsg(
                'a1',
                '**Bugs and gaps in files I don\'t own**\n\n'
                    '- `ledger.replay` cannot retract a `same_as` op: `retract` only updates `edge` and `node` tables, '
                    'and `same_as` rows have no id.\n'
                    '- `.gitignore` lacks `graph.sqlite.tmp`. It only exists while a build is running.\n'
                    '- Quote re-verification in `replay` is never exercised by `build`, because I pass no `doc_texts`.',
              ),
            ],
          ),
        );
        await tester.pumpWidget(framed(key, AgentSessionScreen(key: ObjectKey(session), session: session)));
        await tester.pump(const Duration(milliseconds: 100));
        // A long press selects a word; then the whole message is selected from it.
        final first = find.textContaining('Bugs and gaps', findRichText: true);
        await tester.longPress(first.first);
        await tester.pump(const Duration(milliseconds: 300));
        tester
            .state<SelectableRegionState>(find.byType(SelectableRegion).first)
            .selectAll(SelectionChangedCause.toolbar);
        await tester.pump(const Duration(milliseconds: 300));
        await snap(tester, key, 'chat-selection');
      });
    });
}
