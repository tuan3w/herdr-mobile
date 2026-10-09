import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/claude_ask_driver.dart';
import 'package:herdr_mobile/data/observed/claude_log_mapper.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/observed/omp_ask_driver.dart' show AskDone, AskMismatch, AskSend, AskStep;

import 'support/fake_claude_ask.dart';

// Claude Code's question dialog, from the real captures
// (test/fixtures/prompts/claude/askfull-*) and the key table observed on
// 2.1.293 / 2.1.295. The fake in support/fake_claude_ask.dart takes the same
// keys and draws the same screens; the first group pins it to the captures.

String _screen(String name) {
  final lines = File('test/fixtures/prompts/claude/$name.txt').readAsLinesSync();
  return lines.skipWhile((l) => l.startsWith('# ')).join('\n');
}

const _color = AskQuestion(
  id: 'Color',
  question: 'Which color do you prefer?',
  options: [
    AskOption(label: 'Red', description: 'Red'),
    AskOption(label: 'Green', description: 'Green'),
    AskOption(label: 'Blue', description: 'Blue'),
  ],
);

const _fruits = AskQuestion(
  id: 'Fruits',
  question: 'Which fruits do I like?',
  multi: true,
  options: [
    AskOption(label: 'Apple', description: 'Apple'),
    AskOption(label: 'Banana', description: 'Banana'),
    AskOption(label: 'Cherry', description: 'Cherry'),
    AskOption(label: 'Date', description: 'Date'),
  ],
);

const _form = [
  AskQuestion(
    id: 'Lang',
    question: 'Which language do I prefer?',
    options: [
      AskOption(label: 'Python', description: 'Python as your preferred language'),
      AskOption(label: 'Go', description: 'Go as your preferred language'),
      AskOption(label: 'Rust', description: 'Rust as your preferred language'),
    ],
  ),
  AskQuestion(
    id: 'Extras',
    question: 'Which extras do I want?',
    multi: true,
    options: [
      AskOption(label: 'Tests', description: 'Include a test suite'),
      AskOption(label: 'Docs', description: 'Include documentation'),
      AskOption(label: 'CI', description: 'Include continuous integration setup'),
      AskOption(label: 'Lint', description: 'Include linting configuration'),
    ],
  ),
];

const _deploy = AskQuestion(
  id: 'Deploy',
  question:
      'Which of the following deployment strategies would you prefer to use for the next production release of the mobile backend service?',
  options: [
    AskOption(label: 'Blue-green deployment with automated smoke tests and an instant rollback path if errors rise'),
    AskOption(label: 'Canary'),
    AskOption(label: 'Rolling'),
  ],
);

PendingAsk _ask(List<AskQuestion> qs) => PendingAsk(toolCallId: 't', questions: qs);

/// Drives [fake] with [answers] the way the session does: read, step, send
/// (text first, then keys), until the driver says it is done.
List<AskSend> _drive(FakeClaudeAsk fake, List<AskAnswer> answers, {int max = 60}) {
  final driver = ClaudeAskDriver(_ask(fake.questions), answers);
  final sent = <AskSend>[];
  for (var i = 0; i < max; i++) {
    switch (driver.next(fake.screen())) {
      case AskDone():
        return sent;
      case AskMismatch(:final why):
        fail('mismatch after ${sent.length} steps: $why\n${fake.screen()}');
      case final AskSend step:
        sent.add(step);
        if (step.text != null) fake.paste(step.text!);
        step.keys.forEach(fake.press);
    }
  }
  fail('the driver never finished: $sent');
}

void main() {
  group('the screens', () {
    test('every captured question screen is read; the review is the review; nothing else is a dialog', () {
      final dialogs = Directory('test/fixtures/prompts/claude').listSync().whereType<File>().map((f) => f.uri.pathSegments.last).where((n) => n.startsWith('askfull-') && n.endsWith('.txt'));
      expect(dialogs, isNotEmpty);
      for (final name in dialogs) {
        final s = parseClaudeAsk(_screen(name.replaceAll('.txt', '')));
        expect(s.kind, isNot(ClaudeAskKind.none), reason: name);
        expect(looksLikeClaudeAsk(_screen(name.replaceAll('.txt', ''))), isTrue, reason: name);
      }
      for (final other in ['approval-bash', 'approval-edit', 'plan-approval', 'approvalfull-write', 'approvalfull-bash-multiline']) {
        expect(looksLikeClaudeAsk(_screen(other)), isFalse, reason: other);
      }
      expect(looksLikeClaudeAsk(''), isFalse);
    });

    test('a single choice: strip, title, rows, cursor, and the Other row', () {
      final s = parseClaudeAsk(_screen('askfull-single'));

      expect(s.kind, ClaudeAskKind.question);
      expect([for (final t in s.tabs) (t.label, t.answered)], [('Color', false)]);
      expect(s.title, 'Which color do you prefer?');
      expect(s.options.map((o) => o.label), ['Red', 'Green', 'Blue', 'Type something.']);
      expect(s.cursorNumber, 1);
      expect(s.options.any((o) => o.checked), isFalse);
    });

    test('a multi-select: checkboxes, the Submit row, and where the cursor is', () {
      final toggled = parseClaudeAsk(_screen('askfull-multi-toggled'));
      expect([for (final o in toggled.options) o.checked], [true, false, true, false, false]);
      expect(toggled.cursorNumber, 3);
      expect(toggled.tabs.single.answered, isTrue, reason: '☒');

      final submit = parseClaudeAsk(_screen('askfull-multi-submit-row'));
      expect(submit.cursorOnSubmit, isTrue);
      expect(submit.cursorNumber, 6, reason: 'the arrows visit 4 options, Other, then Submit');
      expect(submit.options.last.label, 'Elderberry', reason: 'the text typed on the Other row');
      expect(submit.options.last.checked, isTrue);

      expect(parseClaudeAsk(_screen('askfull-multi-chat')).cursorNumber, 7, reason: 'Chat about this is the 7th row the arrows reach');
    });

    test('a form: both tabs, which are answered, and the answered option is marked', () {
      final q1 = parseClaudeAsk(_screen('askfull-two-q1'));
      expect([for (final t in q1.tabs) (t.label, t.answered)], [('Lang', false), ('Extras', false)]);
      expect(q1.title, 'Which language do I prefer?');

      final back = parseClaudeAsk(_screen('askfull-two-q1-answered'));
      expect([for (final t in back.tabs) t.answered], [true, true]);
      expect(back.options[1].marked, isTrue);
      expect(back.options[1].label, 'Go');
      expect(back.cursorNumber, 1, reason: 'the cursor returns to row 1, not to the answer');
    });

    test('a question that wraps under bars, and labels and descriptions that wrap', () {
      final wrapped = parseClaudeAsk(_screen('askfull-wrap'));
      expect(wrapped.title, _deploy.question);
      expect(wrapped.options.map((o) => o.label).take(3), [_deploy.options[0].label, 'Canary', 'Rolling']);

      final tall = parseClaudeAsk(_screen('askfull-tall'));
      expect(tall.options, hasLength(5), reason: '4 options and Other: descriptions are not rows');
    });

    test('the review tab: each question with its answer, and what is missing', () {
      final done = parseClaudeAsk(_screen('askfull-two-review'));
      expect(done.kind, ClaudeAskKind.review);
      expect(done.review, [('Which language do I prefer?', 'Go'), ('Which extras do I want?', 'Tests')]);

      final missing = parseClaudeAsk(_screen('askfull-two-review-unanswered'));
      expect(missing.review, [('Which extras do I want?', 'Tests')]);
      expect(missing.reviewAnswerOf('Which language do I prefer?'), isNull);
    });
  });

  group('the fake draws what the real dialog drew', () {
    List<Object?> shape(ClaudeAskScreen s) => [
      s.kind,
      [for (final t in s.tabs) (t.label, t.answered)],
      s.title,
      [for (final o in s.options) (o.number, o.label, o.cursor, o.checked, o.marked)],
      s.cursorNumber,
      s.cursorOnSubmit,
      s.review,
    ];

    test('the first screens and the states reached by the observed keys equal the captures', () {
      final cases = <(String, FakeClaudeAsk Function())>[
        ('askfull-single', () => FakeClaudeAsk([_color])),
        ('askfull-multi', () => FakeClaudeAsk([_fruits])),
        ('askfull-two-q1', () => FakeClaudeAsk(_form)),
        ('askfull-two-q2', () => FakeClaudeAsk(_form)..press('right')),
        (
          'askfull-two-q2-toggled',
          () => FakeClaudeAsk(_form)..press('right')..press('enter'),
        ),
        (
          'askfull-two-review',
          () => FakeClaudeAsk(_form)
            ..press('down')
            ..press('enter')
            ..press('enter')
            ..press('right'),
        ),
        (
          'askfull-two-q1-answered',
          () => FakeClaudeAsk(_form)
            ..press('down')
            ..press('enter')
            ..press('enter')
            ..press('left')
            ..press('left'),
        ),
        ('askfull-single-other', () => FakeClaudeAsk([_color])..press('down')..press('down')..press('down')..paste('purple')),
        ('askfull-wrap', () => FakeClaudeAsk([_deploy])),
      ];
      for (final (name, build) in cases) {
        expect(shape(parseClaudeAsk(build().screen())), shape(parseClaudeAsk(_screen(name))), reason: name);
      }
    });
  });

  group('the driver', () {
    test('a single choice: moves to the row and enters, never a digit that could be text', () {
      final fake = FakeClaudeAsk([_color]);

      final sent = _drive(fake, const [AskAnswer(selected: [1])]);

      expect(fake.submitted, isTrue);
      expect(fake.answerOf(0), 'Green');
      expect(sent.single.keys, ['down', 'enter']);
      expect(sent.single.submits, isTrue);
    });

    test('a typed answer goes in the Other row, once, and is submitted', () {
      final fake = FakeClaudeAsk([_color]);

      final sent = _drive(fake, const [AskAnswer(custom: 'purple, with a comma')]);

      expect(fake.submitted, isTrue);
      expect(fake.answerOf(0), 'purple, with a comma');
      expect(sent.where((s) => s.text != null).single.text, 'purple, with a comma');
    });

    test('a multi-select: toggles what differs, then goes to the review and submits', () {
      final fake = FakeClaudeAsk([_fruits]);

      _drive(fake, const [AskAnswer(selected: [0, 2])]);

      expect(fake.submitted, isTrue);
      expect(fake.answerOf(0), 'Apple, Cherry');
    });

    test('a multi-select with a typed answer too', () {
      final fake = FakeClaudeAsk([_fruits]);

      _drive(fake, const [AskAnswer(selected: [0, 2], custom: 'Elderberry')]);

      expect(fake.answerOf(0), 'Apple, Cherry, Elderberry');
      expect(fake.submitted, isTrue);
    });

    test('a form: each question in its tab, then the review is checked and submitted', () {
      final fake = FakeClaudeAsk(_form);

      _drive(fake, const [AskAnswer(selected: [1]), AskAnswer(selected: [0, 2])]);

      expect(fake.submitted, isTrue);
      expect([fake.answerOf(0), fake.answerOf(1)], ['Go', 'Tests, CI']);
    });

    test('starting from a half-answered form: what was answered otherwise is answered again', () {
      final fake = FakeClaudeAsk(_form)..press('enter'); // Python, on to the second tab

      _drive(fake, const [AskAnswer(selected: [1]), AskAnswer(selected: [1])]);

      expect(fake.submitted, isTrue);
      expect([fake.answerOf(0), fake.answerOf(1)], ['Go', 'Docs']);
    });

    test('a question that wraps is still that question', () {
      final fake = FakeClaudeAsk([_deploy]);

      _drive(fake, const [AskAnswer(selected: [0])]);

      expect(fake.answerOf(0), _deploy.options[0].label);
    });

    test('from Chat about this or from the Submit row, the arrows count the rows of the dialog', () {
      for (final multi in [true, false]) {
        final q = multi ? _fruits : _color;
        final fake = FakeClaudeAsk([q]);
        // Down to the last row: Chat about this.
        for (var i = 0; i < fake.questions.single.options.length + (multi ? 2 : 1); i++) {
          fake.press('down');
        }
        expect(parseClaudeAsk(fake.screen()).cursorNumber, q.options.length + (multi ? 3 : 2), reason: 'multi $multi: the cursor is on Chat');

        _drive(fake, [AskAnswer(selected: multi ? const [0, 2] : const [1])]);

        expect(fake.submitted, isTrue, reason: 'multi $multi');
        expect(fake.answerOf(0), multi ? 'Apple, Cherry' : 'Green', reason: 'multi $multi');
      }
    });

    test('no dialog on the screen is done', () {
      expect(ClaudeAskDriver(_ask([_color]), const [AskAnswer(selected: [0])]).next('⏺ Done\n\n❯ '), isA<AskDone>());
    });

    test('another question on the screen is not answered', () {
      final other = FakeClaudeAsk([
        const AskQuestion(id: 'Color', question: 'Which animal?', options: [AskOption(label: 'Cat'), AskOption(label: 'Dog')]),
      ]);
      final step = ClaudeAskDriver(_ask([_color]), const [AskAnswer(selected: [0])]).next(other.screen());
      expect(step, isA<AskMismatch>());
    });

    test('options that are not the ones asked are not answered', () {
      final other = FakeClaudeAsk([
        const AskQuestion(id: 'Color', question: 'Which color do you prefer?', options: [AskOption(label: 'Cyan'), AskOption(label: 'Magenta'), AskOption(label: 'Black')]),
      ]);
      expect(ClaudeAskDriver(_ask([_color]), const [AskAnswer(selected: [0])]).next(other.screen()), isA<AskMismatch>());
    });

    test('text already in the Other row is never overwritten', () {
      final fake = FakeClaudeAsk([_color])
        ..press('down')
        ..press('down')
        ..press('down')
        ..paste('abc');
      final driver = ClaudeAskDriver(_ask([_color]), const [AskAnswer(custom: 'purple')]);

      expect(driver.next(fake.screen()), isA<AskMismatch>());
    });

    test('a dialog that does not react gives up instead of pressing forever', () {
      final fake = FakeClaudeAsk([_color]);
      final driver = ClaudeAskDriver(_ask([_color]), const [AskAnswer(selected: [2])]);
      final screen = fake.screen();

      AskStep? last;
      for (var i = 0; i < 6; i++) {
        last = driver.next(screen);
        if (last is! AskSend) break;
      }

      expect(last, isA<AskMismatch>());
    });

    test('a review that shows another answer sends the person back, not on', () {
      final fake = FakeClaudeAsk(_form)
        ..press('enter')
        ..press('enter')
        ..press('right');
      final driver = ClaudeAskDriver(_ask(_form), const [AskAnswer(selected: [1]), AskAnswer(selected: [0])]);

      final step = driver.next(fake.screen()) as AskSend;

      expect(step.submits, isFalse);
      expect(step.keys, ['left', 'left'], reason: 'back to the first question');
    });
  });

  group('the result Claude recorded', () {
    String? output(String log, {String tool = 'AskUserQuestion'}) {
      final m = ClaudeLogMapper();
      var s = const AgentSessionState('s');
      for (final l in File('test/fixtures/claude_logs/$log.jsonl').readAsLinesSync()) {
        for (final u in m.map(l)) {
          s = s.apply(u);
        }
      }
      return s.toolCalls.firstWhere((c) => c.name == tool).rawOutput as String?;
    }

    test('says what was chosen, in either wording, for one question or two', () {
      expect(claudeAskResultMatches(output('ask-single'), _ask([_color]), const [AskAnswer(selected: [1])]), isTrue);
      expect(claudeAskResultMatches(output('ask-multi'), _ask([_fruits]), const [AskAnswer(selected: [0, 2])]), isTrue);
      expect(claudeAskResultMatches(output('ask-other'), _ask([_color]), const [AskAnswer(custom: 'purple')]), isTrue);
    });

    test('a form with a typed answer after the labels, as Claude words it', () {
      // The questions are the ones the log itself asked.
      final m = ClaudeLogMapper();
      final lines = File('test/fixtures/claude_logs/ask-two.jsonl').readAsLinesSync();
      for (final l in lines.sublist(0, lines.indexWhere((l) => l.contains('"type":"tool_use"') && l.contains('AskUserQuestion')) + 1)) {
        m.map(l);
      }
      final ask = m.pendingAsk!;

      final given = output('ask-two');
      final go = ask.questions[0].options.indexWhere((o) => o.label == 'Go');
      final extras = ask.questions[1].options;
      final tests = extras.indexWhere((o) => o.label == 'Tests');
      final ci = extras.indexWhere((o) => o.label == 'CI');

      expect(claudeAskResultMatches(given, ask, [AskAnswer(selected: [go]), AskAnswer(selected: [tests, ci], custom: 'Docs please')]), isTrue);
      expect(claudeAskResultMatches(given, ask, [AskAnswer(selected: [go]), AskAnswer(selected: [tests, ci])]), isFalse, reason: 'the typed part is missing');
    });

    test('catches an answer that is another one', () {
      expect(claudeAskResultMatches(output('ask-single'), _ask([_color]), const [AskAnswer(selected: [0])]), isFalse);
      expect(claudeAskResultMatches(output('ask-multi'), _ask([_fruits]), const [AskAnswer(selected: [0])]), isFalse);
      expect(claudeAskResultMatches(null, _ask([_color]), const [AskAnswer(selected: [0])]), isFalse);
    });
  });
}
