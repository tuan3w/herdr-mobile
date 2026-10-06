import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/settings/quick_phrases_editor.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/memory_quick_phrases_store.dart';

Future<void> _frames(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<QuickPhrases> _phrases([List<String>? saved]) async {
  final phrases = QuickPhrases(MemoryQuickPhrasesStore(saved));
  await phrases.load();
  return phrases;
}

Future<void> _pumpSession(
  WidgetTester tester,
  FakeAgentSession session,
  QuickPhrases? phrases, {
  Size size = const Size(412, 892),
}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  addTearDown(tester.view.resetViewInsets);
  Widget app = MaterialApp(
    theme: AppTheme.light(),
    home: AgentSessionScreen(key: ObjectKey(session), session: session),
  );
  if (phrases != null) app = ChangeNotifierProvider.value(value: phrases, child: app);
  await tester.pumpWidget(app);
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _chips() => find.byType(AppChip);

void main() {
  group('chips above the agent-session composer', () {
    testWidgets('a tap fills the empty field and does not send', (tester) async {
      final session = FakeAgentSession();
      final phrases = await _phrases();
      await _pumpSession(tester, session, phrases);

      await tester.tap(find.byType(TextField).last);
      await _frames(tester, 2);
      expect(find.text('continue'), findsOneWidget);

      await tester.tap(find.text('yes, go ahead'));
      await _frames(tester, 2);

      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.controller!.text, 'yes, go ahead');
      expect(field.controller!.selection, const TextSelection.collapsed(offset: 13));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(session.sent, isEmpty);
      // The draft is there, so the chips make way for it.
      expect(_chips(), findsNothing);
    });

    testWidgets('hidden until the field is focused', (tester) async {
      await _pumpSession(tester, FakeAgentSession(), await _phrases());
      expect(_chips(), findsNothing);
    });

    testWidgets('hidden once there is text, back when it is cleared', (tester) async {
      await _pumpSession(tester, FakeAgentSession(), await _phrases());
      await tester.tap(find.byType(TextField).last);
      await _frames(tester, 2);
      expect(_chips(), findsWidgets);

      await tester.enterText(find.byType(TextField).last, 'fix the');
      await tester.pump();
      expect(_chips(), findsNothing);

      await tester.enterText(find.byType(TextField).last, '');
      await tester.pump();
      expect(_chips(), findsWidgets);
    });

    testWidgets('not offered while the session cannot take a message', (tester) async {
      final session = FakeAgentSession(link: AgentLink.reconnecting);
      await _pumpSession(tester, session, await _phrases());
      await tester.tap(find.byType(TextField).last, warnIfMissed: false);
      await _frames(tester, 2);
      expect(_chips(), findsNothing);
    });

    testWidgets('no phrases, no row', (tester) async {
      await _pumpSession(tester, FakeAgentSession(), await _phrases([]));
      await tester.tap(find.byType(TextField).last);
      await _frames(tester, 2);
      expect(_chips(), findsNothing);
    });

    testWidgets('without the store the composer is as before', (tester) async {
      await _pumpSession(tester, FakeAgentSession(), null);
      await tester.tap(find.byType(TextField).last);
      await _frames(tester, 2);
      expect(_chips(), findsNothing);
    });

    testWidgets('left out in the compact layout: landscape with the keyboard up', (tester) async {
      await _pumpSession(tester, FakeAgentSession(), await _phrases(), size: const Size(892, 412));
      await tester.tap(find.byType(TextField).last);
      await _frames(tester, 2);
      expect(_chips(), findsWidgets, reason: 'landscape without a keyboard has room');

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await _frames(tester, 2);
      expect(_chips(), findsNothing);

      tester.view.resetViewInsets();
      await _frames(tester, 2);
      expect(_chips(), findsWidgets);
    });

    testWidgets('a portrait keyboard keeps the row', (tester) async {
      await _pumpSession(tester, FakeAgentSession(), await _phrases());
      await tester.tap(find.byType(TextField).last);
      tester.view.viewInsets = const FakeViewPadding(bottom: 600);
      await _frames(tester, 2);
      expect(_chips(), findsWidgets);
    });

    testWidgets('a very long phrase stays on one chip', (tester) async {
      const long = 'Hãy kiểm tra lại toàn bộ thay đổi và giải thích rõ ràng từng bước';
      await _pumpSession(tester, FakeAgentSession(), await _phrases([QuickPhrases.clean(long)]));
      await tester.tap(find.byType(TextField).last);
      await _frames(tester, 2);
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_chips()).width, lessThanOrEqualTo(240));
    });
  });

  group('Settings > Quick phrases', () {
    Future<QuickPhrases> pumpSection(WidgetTester tester, {List<String>? saved}) async {
      final phrases = await _phrases(saved);
      tester.view
        ..physicalSize = const Size(360, 800) * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: phrases,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: SingleChildScrollView(child: QuickPhrasesSection())),
          ),
        ),
      );
      await _frames(tester, 2);
      return phrases;
    }

    testWidgets('adds a phrase', (tester) async {
      final phrases = await pumpSection(tester);
      await tester.tap(find.text('Add a phrase'));
      await _frames(tester);

      // Save waits for text.
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Save')).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'squash the commits');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await _frames(tester);

      expect(phrases.phrases.last, 'squash the commits');
      expect(find.text('squash the commits'), findsOneWidget);
    });

    testWidgets('edits in place and deletes', (tester) async {
      final phrases = await pumpSection(tester);
      await tester.tap(find.text('yes, go ahead'));
      await _frames(tester);
      await tester.enterText(find.byType(TextField), 'sí, adelante');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await _frames(tester);
      expect(phrases.phrases[1], 'sí, adelante');

      await tester.tap(find.text('continue'));
      await _frames(tester);
      await tester.tap(find.text('Delete'));
      await _frames(tester);
      expect(phrases.phrases, isNot(contains('continue')));
      expect(find.text('continue'), findsNothing);
    });

    testWidgets('refuses a phrase already in the list and says why', (tester) async {
      final phrases = await pumpSection(tester);
      await tester.tap(find.text('Add a phrase'));
      await _frames(tester);
      await tester.enterText(find.byType(TextField), '  continue ');
      await tester.pump();

      expect(find.text('Already in the list'), findsOneWidget);
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Save')).onPressed, isNull);
      expect(phrases.phrases, QuickPhrases.defaults);
    });

    testWidgets('a full list cannot grow', (tester) async {
      await pumpSection(tester, saved: [for (var i = 0; i < QuickPhrases.maxCount; i++) 'phrase $i']);
      final add = find.widgetWithText(AppButton, 'List is full (12)');
      expect(add, findsOneWidget);
      expect(tester.widget<AppButton>(add).onPressed, isNull);
    });

    testWidgets('an empty list says so and still offers Add', (tester) async {
      await pumpSection(tester, saved: []);
      expect(find.text('No phrases yet, so no chips.'), findsOneWidget);
      expect(find.text('Add a phrase'), findsOneWidget);
    });

    testWidgets('a worst-case phrase wraps and ellipsizes without overflow', (tester) async {
      final long = QuickPhrases.clean(
        'Hãy xem lại toàn bộ thay đổi, chạy lại các bài kiểm tra và giải thích thật kỹ lưỡng',
      );
      await pumpSection(tester, saved: [long, 'x' * 80]);
      expect(tester.takeException(), isNull);
    });
  });
}
