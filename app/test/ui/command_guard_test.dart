// A `/command` the agent does not list is held once before it goes (a typo
// would be a message to the model, and a turn), and a command just picked shows
// what it takes after it in the field.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/data/repositories/command_source.dart';
import 'package:herdr_mobile/data/repositories/slash_usage.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/composer/command_model.dart';

import '../support/fake_agent_session.dart';
import 'history_support.dart';

class _Source extends ChangeNotifier implements CommandSource {
  _Source(this.commands, {this.agent = 'omp'});

  @override
  final String? agent;

  @override
  List<SlashCommand> commands;

  @override
  void ensureLoaded() {}
}

class _Store implements SlashUsageStore {
  SlashUsageMemory memory = const SlashUsageMemory();

  @override
  Future<SlashUsageMemory> read() async => memory;

  @override
  Future<void> write(SlashUsageMemory value) async => memory = value;
}

const _review = SlashCommand('review', 'Review a change', SlashSource.builtIn, hint: '<pr number>');
const _compact = SlashCommand('compact', 'Compact the context', SlashSource.builtIn);
const _skill = SlashCommand('write', 'A skill', SlashSource.builtIn, trigger: r'$', hint: '<topic>');

void main() {
  group('unknownCommand', () {
    CommandPaletteModel model({List<SlashCommand> commands = const [_review, _compact], String? agent = 'omp'}) {
      final m = CommandPaletteModel(source: _Source(commands, agent: agent));
      addTearDown(m.dispose);
      return m;
    }

    test('names a /word the agent does not list, with or without arguments', () {
      final m = model();
      expect(m.unknownCommand('/clera'), 'clera');
      expect(m.unknownCommand('/clera now please'), 'clera');
      expect(m.unknownCommand('  /revue 12  '), 'revue');
    });

    test('is null for what the agent lists, in any case, and for the commands every terminal takes', () {
      final m = model();
      expect(m.unknownCommand('/review 12'), isNull);
      expect(m.unknownCommand('/Compact'), isNull);
      for (final word in ['clear', 'new', 'help', 'exit', 'quit']) {
        expect(m.unknownCommand('/$word'), isNull, reason: word);
      }
    });

    test('is null for what is not a command: text, a path, a dollar sentence', () {
      final m = model();
      expect(m.unknownCommand('please review it'), isNull);
      expect(m.unknownCommand('/usr/bin/env python'), isNull, reason: 'a path has no space after its first word');
      expect(m.unknownCommand(r'$PATH is wrong'), isNull);
      expect(m.unknownCommand(''), isNull);
    });

    test('is null while nothing can be said: no list yet, or no agent', () {
      expect(model(commands: const []).unknownCommand('/clera'), isNull, reason: 'the list has not arrived');
      expect(model(commands: const [_skill]).unknownCommand('/clera'), isNull, reason: 'no slash command at all');
      expect(model(agent: null).unknownCommand('/clera'), isNull);
    });

    test('is null for a word the person sent before or pinned', () async {
      final usage = SlashUsage(_Store());
      await usage.record('omp', 'ship');
      await usage.togglePin('omp', 'deploy');
      final m = CommandPaletteModel(source: _Source(const [_review]), usage: usage);
      addTearDown(m.dispose);
      expect(m.unknownCommand('/ship it'), isNull);
      expect(m.unknownCommand('/deploy'), isNull);
      expect(m.unknownCommand('/other'), 'other');
    });
  });

  group('hintFor', () {
    CommandPaletteModel model() {
      final m = CommandPaletteModel(source: _Source(const [_review, _compact, _skill]));
      addTearDown(m.dispose);
      return m;
    }

    test('is what the command takes, while the field holds just the command and its space', () {
      final m = model();
      expect(m.hintFor('/review '), '<pr number>');
      expect(m.hintFor(r'$write '), '<topic>');
    });

    test('is gone with the first character after it, and before the space', () {
      final m = model();
      expect(m.hintFor('/review 1'), isNull);
      expect(m.hintFor('/review'), isNull);
      expect(m.hintFor('/review  '), isNull);
    });

    test('is nothing for a command without a hint, an unknown word or plain text', () {
      final m = model();
      expect(m.hintFor('/compact '), isNull, reason: 'nothing is made up');
      expect(m.hintFor('/nothing '), isNull);
      expect(m.hintFor('review '), isNull);
    });
  });

  group('in a chat', () {
    FakeAgentSession session() => FakeAgentSession(
      agent: 'omp',
      agentLabel: 'omp',
      state: stateWith(
        items: [userMsg('u', 'earlier prompt')],
        commands: const [
          AcpCommand(name: 'review', description: 'Review a change', inputHint: '<pr number>'),
          AcpCommand(name: 'compact', description: 'Compact the context'),
        ],
      ),
    );

    Future<HistoryEnv> open(WidgetTester tester, FakeAgentSession s) async {
      final e = await historyEnv();
      await pumpUnder(tester, e, AgentSessionScreen(key: ObjectKey(s), session: s));
      return e;
    }

    Finder field() => find.byType(TextField).last;

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(field(), text);
      await tester.pump();
    }

    Future<void> send(WidgetTester tester) async {
      // The keyboard's send key: the arrow is a stop while the agent works.
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await settleHistory(tester, 3);
    }

    String fieldText(WidgetTester tester) => tester.widget<TextField>(field()).controller!.text;

    /// What the field draws: its text, and the ghost hint after it.
    String fieldSpan(WidgetTester tester) => tester
        .widget<TextField>(field())
        .controller!
        .buildTextSpan(context: tester.element(field()), withComposing: false)
        .toPlainText();

    testWidgets('an unlisted /word is held: not sent, kept in the field, and said once', (tester) async {
      final s = session();
      final e = await open(tester, s);
      await type(tester, '/clera now');
      await send(tester);

      expect(s.sent, isEmpty);
      expect(fieldText(tester), '/clera now', reason: 'nothing is lost');
      expect(find.textContaining('/clera is not', findRichText: true), findsOneWidget);
      expect(find.textContaining('is not one of omp', findRichText: true), findsOneWidget);
      expect(find.text('Send as message'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('Send as message sends it as typed, once, and the note goes', (tester) async {
      final s = session();
      final e = await open(tester, s);
      await type(tester, '/clera now');
      await send(tester);

      await tester.tap(find.text('Send as message'));
      await settleHistory(tester, 3);
      expect(s.sent, ['/clera now']);
      expect(find.text('Send as message'), findsNothing);
      expect(fieldText(tester), isEmpty);

      // Typed again, it is held again: the choice was for that send.
      await type(tester, '/clera now');
      await send(tester);
      expect(s.sent, hasLength(1));
      expect(find.text('Send as message'), findsOneWidget);
      await e.tearDown(tester);
    });

    testWidgets('changing the text takes the note away; a fixed command goes without one', (tester) async {
      final s = session();
      final e = await open(tester, s);
      await type(tester, '/revue 12');
      await send(tester);
      expect(find.text('Send as message'), findsOneWidget);

      await type(tester, '/review 12');
      expect(find.text('Send as message'), findsNothing);
      await send(tester);
      expect(s.sent, ['/review 12']);
      await e.tearDown(tester);
    });

    for (final line in ['/compact', '/usr/bin/env x', 'hello there']) {
      testWidgets('"$line", listed or not a command, is sent without a word', (tester) async {
        final s = session();
        final e = await open(tester, s);
        await type(tester, line);
        await send(tester);
        expect(find.text('Send as message'), findsNothing);
        expect(s.sent, [line]);
        await e.tearDown(tester);
      });
    }

    testWidgets('a command just picked shows what it takes after it, until the first character', (tester) async {
      final s = session();
      final e = await open(tester, s);
      await type(tester, '/rev');
      await tester.tap(find.textContaining('/review', findRichText: true).first);
      await tester.pump();
      expect(fieldText(tester), '/review ');
      expect(fieldSpan(tester), '/review <pr number>', reason: 'drawn after the command');
      expect(fieldText(tester), '/review ', reason: 'the hint is not in the field: it is not sent or selected');

      await type(tester, '/review 1');
      expect(fieldSpan(tester), '/review 1');

      // A command that advertised no hint gets none made up.
      await type(tester, '/compact ');
      expect(fieldSpan(tester), '/compact ');
      await e.tearDown(tester);
    });
  });
}
