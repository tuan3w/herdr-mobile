import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/dictation.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/dictation/dictation_language_sheet.dart';
import 'package:herdr_mobile/ui/features/dictation/dictation_session.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'support/fake_agent_session.dart';
import 'support/fake_dictation.dart';

Future<Dictation> _dictation(FakeEngine engine, [MemoryDictationStore? store]) async {
  final d = Dictation(engine, store ?? MemoryDictationStore());
  await d.load();
  return d;
}

void main() {
  group('Dictation', () {
    test('listens in the phone\'s language until a language is picked, and remembers the pick', () async {
      final engine = FakeEngine();
      final store = MemoryDictationStore();
      final d = await _dictation(engine, store);
      await d.start(onWords: (_, _) {}, onProblem: (_) {});
      await d.stop();
      await d.setLanguage('vi_VN');
      await d.start(onWords: (_, _) {}, onProblem: (_) {});
      expect(engine.listenedIn, [null, 'vi_VN']);
      expect((await _dictation(engine, store)).languageId, 'vi_VN', reason: 'kept across launches');
    });

    test('a denied microphone says to allow it, once, and does not listen', () async {
      final engine = FakeEngine()
        ..initOk = false
        ..permitted = false;
      final problems = <DictationProblem>[];
      final d = await _dictation(engine);
      expect(await d.start(onWords: (_, _) {}, onProblem: problems.add), isFalse);
      expect(problems, [DictationProblem.denied]);
      expect(d.listening, isFalse);
    });

    test('a phone without a speech service says so, not that the microphone is off', () async {
      final engine = FakeEngine()..initOk = false;
      final problems = <DictationProblem>[];
      final d = await _dictation(engine);
      await d.start(onWords: (_, _) {}, onProblem: problems.add);
      expect(problems, [DictationProblem.unavailable]);
    });

    test('a refusal the recognizer reports itself is told once, not twice', () async {
      final engine = FakeEngine()
        ..initOk = false
        ..initError = 'error_permission';
      final problems = <DictationProblem>[];
      await (await _dictation(engine)).start(onWords: (_, _) {}, onProblem: problems.add);
      expect(problems, [DictationProblem.denied]);
    });

    test('errors during a listen end it and say what to do', () async {
      final engine = FakeEngine();
      final problems = <DictationProblem>[];
      final d = await _dictation(engine);
      await d.start(onWords: (_, _) {}, onProblem: problems.add);
      engine.onError('error_no_match', false);
      expect(d.listening, isFalse);
      await d.start(onWords: (_, _) {}, onProblem: problems.add);
      engine.onError('error_language_not_supported', true);
      await d.start(onWords: (_, _) {}, onProblem: problems.add);
      engine.onError('error_network', true);
      expect(problems, [DictationProblem.silence, DictationProblem.language, DictationProblem.offline]);
    });

    test('the recognizer ending the listen by itself (a pause) ends it here too', () async {
      final engine = FakeEngine();
      final d = await _dictation(engine);
      await d.start(onWords: (_, _) {}, onProblem: (_) {});
      expect(d.listening, isTrue);
      engine.onListening(false);
      expect(d.listening, isFalse);
    });

    test('a listen that throws is a failure, not a stuck mic', () async {
      final engine = FakeEngine()..listenFailure = StateError('busy');
      final problems = <DictationProblem>[];
      final d = await _dictation(engine);
      expect(await d.start(onWords: (_, _) {}, onProblem: problems.add), isFalse);
      expect(d.listening, isFalse);
      expect(problems, [DictationProblem.failed]);
    });

    test('languages list English then Vietnamese first', () async {
      final d = await _dictation(FakeEngine());
      expect([for (final l in await d.languages()) l.id], ['en_US', 'vi_VN', 'fr_FR']);
    });
  });

  group('dictationChoices', () {
    const en = DictationLanguage('en_US', 'English (United States)');
    const vi = DictationLanguage('vi_VN', 'Tiếng Việt (Việt Nam)');
    const fr = DictationLanguage('fr_FR', 'français (France)');

    test('English and Vietnamese always have a row; a missing one says why', () {
      final rows = dictationChoices([en], null);
      expect([for (final r in rows) r.label], ['Phone\'s language', 'English', 'Tiếng Việt']);
      expect(rows[1].id, 'en_US');
      expect(rows[2].id, isNull);
      expect(rows[2].missing, isNotNull);
    });

    test('another language already chosen keeps its row', () {
      final rows = dictationChoices([en, vi, fr], 'fr_FR');
      expect(rows.last.id, 'fr_FR');
      expect(rows.last.label, 'français (France)');
    });

    test('the language tags of some phones use a dash', () {
      final rows = dictationChoices([const DictationLanguage('vi-VN', 'Vietnamese')], null);
      expect(rows[2].id, 'vi-VN');
    });
  });

  group('DictationSession', () {
    late FakeEngine engine;
    late Dictation dictation;
    late TextEditingController input;
    late List<DictationProblem> problems;
    late DictationSession session;

    setUp(() async {
      engine = FakeEngine();
      dictation = await _dictation(engine);
      input = TextEditingController();
      problems = [];
      session = DictationSession(dictation: dictation, input: input, focus: FocusNode(), onProblem: problems.add);
    });

    tearDown(() {
      session.dispose();
      input.dispose();
    });

    test('what is heard fills the box as it is heard, and nothing else is touched', () async {
      await session.toggle();
      engine.hear('run');
      expect(input.text, 'run');
      engine.hear('run the tests');
      expect(input.text, 'run the tests');
      expect(input.selection, const TextSelection.collapsed(offset: 13));
    });

    test('words go at the cursor, with a space where one is missing, keeping the text around them', () async {
      input.value = const TextEditingValue(text: 'please  and commit', selection: TextSelection.collapsed(offset: 7));
      await session.toggle();
      engine.hear('run the tests');
      expect(input.text, 'please run the tests and commit');
    });

    test('after a space already there, no second one', () async {
      input.text = 'hello ';
      await session.toggle();
      engine.hear('there');
      expect(input.text, 'hello there');
    });

    test('a second tap ends the listen and keeps the words', () async {
      await session.toggle();
      engine.hear('go ahead', isFinal: false);
      await session.toggle();
      expect(engine.stops, 1);
      expect(session.listening, isFalse);
      expect(input.text, 'go ahead');
    });

    test('a pause ends it by itself: the mic is idle again and the words stay', () async {
      await session.toggle();
      engine.hear('go ahead', isFinal: true);
      engine.onListening(false);
      expect(session.listening, isFalse);
      expect(input.text, 'go ahead');
    });

    test('leaving the screen in the middle of a listen cancels it', () async {
      await session.toggle();
      session.dispose();
      expect(engine.cancels, 1);
      session = DictationSession(dictation: dictation, input: input, focus: FocusNode(), onProblem: problems.add);
    });

    test('only the box that started it shows a listening mic', () async {
      final other = TextEditingController();
      final second = DictationSession(dictation: dictation, input: other, focus: FocusNode(), onProblem: (_) {});
      await session.toggle();
      expect(session.listening, isTrue);
      expect(second.listening, isFalse);
      await second.toggle();
      expect(engine.listenedIn, hasLength(1), reason: 'one listen at a time');
      engine.hear('hello');
      expect(other.text, isEmpty);
      second.dispose();
      other.dispose();
    });

    test('a problem is told to the person and the mic is not left listening', () async {
      engine.initOk = false;
      engine.permitted = false;
      await session.toggle();
      expect(problems, [DictationProblem.denied]);
      expect(session.listening, isFalse);
    });
  });

  group('the mic in the session\'s composer', () {
    Future<(FakeAgentSession, FakeEngine)> pump(WidgetTester tester) async {
      final session = FakeAgentSession();
      final engine = FakeEngine();
      final dictation = await _dictation(engine);
      tester.view.physicalSize = const Size(824, 1784);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<Dictation>.value(
          value: dictation,
          child: MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(tapGuard);
      return (session, engine);
    }

    testWidgets('takes Send\'s place while the box is empty, and Send comes back with text', (tester) async {
      await pump(tester);
      expect(find.byIcon(LucideIcons.mic), findsOneWidget);
      expect(find.byIcon(LucideIcons.arrowUp), findsNothing);
      await tester.enterText(find.byType(TextField), 'fix it');
      await tester.pump();
      expect(find.byIcon(LucideIcons.mic), findsNothing);
      expect(find.byIcon(LucideIcons.arrowUp), findsOneWidget);
    });

    testWidgets('speaking fills the box and never sends; the person presses send', (tester) async {
      final (session, engine) = await pump(tester);
      await tester.tap(find.byIcon(LucideIcons.mic));
      await tester.pump();
      engine.hear('run the tests');
      await tester.pump();
      expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, 'run the tests');
      expect(session.sent, isEmpty);
      expect(find.byIcon(LucideIcons.mic), findsOneWidget, reason: 'still the stop button while it listens, though the box has text');
      await tester.tap(find.byIcon(LucideIcons.mic));
      await tester.pump();
      expect(find.byIcon(LucideIcons.arrowUp), findsOneWidget);
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.sent, ['run the tests']);
    });

    testWidgets('a dictation longer than the box scrolls with the words, so the newest are in view', (tester) async {
      final (_, engine) = await pump(tester);
      await tester.tap(find.byIcon(LucideIcons.mic));
      await tester.pump();
      engine.hear(List.generate(80, (i) => 'word$i').join(' '));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final position = tester
          .state<ScrollableState>(find.descendant(of: find.byType(EditableText).last, matching: find.byType(Scrollable)))
          .position;
      expect(position.maxScrollExtent, greaterThan(0), reason: 'more than five lines');
      expect(position.pixels, position.maxScrollExtent);
    });

    testWidgets('a long press on the mic offers the languages', (tester) async {
      await pump(tester);
      await tester.longPress(find.byIcon(LucideIcons.mic));
      await tester.pumpAndSettle();
      expect(find.text('Dictate in'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      expect(find.text('Tiếng Việt'), findsOneWidget);
      await tester.tap(find.text('Tiếng Việt'));
      await tester.pumpAndSettle();
      final dictation = tester.element(find.byType(AgentSessionScreen)).read<Dictation>();
      expect(dictation.languageId, 'vi_VN');
    });

    testWidgets('without a speech service there is no mic: the button is Send, as before', (tester) async {
      final session = FakeAgentSession();
      tester.view.physicalSize = const Size(824, 1784);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(LucideIcons.mic), findsNothing);
      expect(find.byIcon(LucideIcons.arrowUp), findsOneWidget);
    });
  });
}
