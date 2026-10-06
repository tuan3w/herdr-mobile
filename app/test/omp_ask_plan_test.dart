import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/observed/omp_ask_driver.dart';

import 'support/fake_omp_ask.dart';
import 'support/omp_ask_fixtures.dart';

PendingAsk _ask(List<AskQuestion> q) => PendingAsk(toolCallId: 'call', questions: q);

/// What the dialog should have handed back for [answers]: a custom answer
/// replaces the single choice; a multi-select keeps both.
List<AskAnswer> _normalised(List<AskQuestion> qs, List<AskAnswer> answers) => [
      for (var k = 0; k < qs.length; k++)
        AskAnswer(
          selected: !qs[k].multi && (answers[k].custom?.trim().isNotEmpty ?? false)
              ? const []
              : ([...answers[k].selected]..sort()),
          custom: (answers[k].custom?.trim().isEmpty ?? true) ? null : answers[k].custom,
        ),
    ];

String _show(List<AskAnswer> a) => [for (final x in a) '${x.selected}${x.custom == null ? '' : ' "${x.custom}"'}'].join(' | ');

class _Run {
  _Run(this.steps, this.outcome);

  final List<AskStep> steps;

  /// `done`, or the mismatch text.
  final String outcome;
}

/// Plays the driver against [fake] the way the app will: read the screen, ask
/// for a step, send it, read again.
_Run _drive(
  FakeOmpAsk fake,
  List<AskQuestion> qs,
  List<AskAnswer> answers, {
  OmpAskDriver? driver,
  int limit = 120,
}) {
  final d = driver ?? OmpAskDriver(_ask(qs), answers);
  final steps = <AskStep>[];
  for (var i = 0; i < limit; i++) {
    final step = d.next(fake.screen());
    steps.add(step);
    switch (step) {
      case AskDone():
        return _Run(steps, 'done');
      case AskMismatch(:final why):
        return _Run(steps, why);
      case AskSend(:final keys, :final text, :final submits):
        expect(keys.isNotEmpty || text != null, isTrue, reason: 'an empty step');
        if (text != null) fake.paste(text);
        keys.forEach(fake.press);
        expect(fake.closed, submits, reason: 'submits must say whether the dialog ended: $step');
    }
  }
  return _Run(steps, 'no end after $limit steps');
}

void _expectAnswered(FakeOmpAsk fake, List<AskQuestion> qs, List<AskAnswer> answers, _Run run, String reason) {
  expect(run.outcome, 'done', reason: '$reason\n${run.steps.join('\n')}');
  expect(fake.cancelled, isFalse, reason: reason);
  expect(fake.submitted, isNotNull, reason: '$reason: never submitted\n${run.steps.join('\n')}');
  expect(_show(fake.submitted!), _show(_normalised(qs, answers)), reason: '$reason\n${run.steps.join('\n')}');
}

List<int> _subset(int mask, int n) => [for (var i = 0; i < n; i++) if (mask & (1 << i) != 0) i];

void main() {
  group('a single question, single choice', () {
    test('every option and a custom answer, from every cursor position', () {
      final qs = [dbQuestion];
      for (var cursor = 0; cursor <= 3; cursor++) {
        for (final want in <AskAnswer>[
          const AskAnswer(selected: [0]),
          const AskAnswer(selected: [1]),
          const AskAnswer(selected: [2]),
          const AskAnswer(custom: 'Tên khác — dùng “SQLite” trên Pi'),
        ]) {
          final fake = FakeOmpAsk(qs)..seed(0, cursor: cursor);
          final run = _drive(fake, qs, [want]);
          _expectAnswered(fake, qs, [want], run, 'cursor $cursor, ${_show([want])}');
          expect(run.steps.whereType<AskSend>().length, lessThanOrEqualTo(want.custom == null ? 1 : 3));
        }
      }
    });

    test('a yes/no from the Other row up, and with nothing in the way', () {
      final qs = [yesNoQuestion];
      for (var cursor = 0; cursor <= 2; cursor++) {
        for (final t in [0, 1]) {
          final fake = FakeOmpAsk(qs)..seed(0, cursor: cursor);
          final want = [AskAnswer(selected: [t])];
          _expectAnswered(fake, qs, want, _drive(fake, qs, want), 'cursor $cursor -> $t');
        }
      }
    });

    test('the first plan from the captured screen moves by the cursor it reads', () {
      final ask = _ask([dbQuestion]);
      const want = [AskAnswer(selected: [2])];
      expect((nextAskStep(ask, want, fixtureScreen('ask-single')) as AskSend).keys, ['down', 'down', 'enter']);
      expect((nextAskStep(ask, want, fixtureScreen('ask-single-down')) as AskSend).keys, ['down', 'enter']);
      expect((nextAskStep(ask, want, fixtureScreen('ask-single-other')) as AskSend).keys, ['up', 'enter']);
      const first = [AskAnswer(selected: [0])];
      expect((nextAskStep(ask, first, fixtureScreen('ask-single-other')) as AskSend).keys,
          ['up', 'up', 'up', 'enter']);
    });

    test('a custom answer: open the editor, type, submit; a prefilled editor is cleared first', () {
      const want = [AskAnswer(custom: 'Postgres, nhưng dùng PgBouncer')];
      final ask = _ask([dbQuestion]);
      final fromOther = nextAskStep(ask, want, fixtureScreen('ask-single-other')) as AskSend;
      expect(fromOther.keys, ['enter']);
      final empty = nextAskStep(ask, want, fixtureScreen('ask-other-editor')) as AskSend;
      expect(empty.text, 'Postgres, nhưng dùng PgBouncer');
      expect(empty.keys, isEmpty);
      final typed = nextAskStep(ask, want, fixtureScreen('ask-other-typed')) as AskSend;
      expect(typed.keys, ['enter']);
      expect(typed.submits, isTrue);
      final other = nextAskStep(ask, const [AskAnswer(custom: 'something else')], fixtureScreen('ask-other-typed'))
          as AskSend;
      expect(other.keys, ['ctrl+u']);
    });
  });

  group('a single multi-select', () {
    test('every subset, with and without a custom answer, from every cursor and from messy states', () {
      final qs = [toolsQuestion];
      final rnd = Random(7);
      var runs = 0;
      for (var mask = 0; mask < 16; mask++) {
        for (final custom in <String?>[null, 'Lint, nhưng chỉ lúc 3 giờ sáng']) {
          for (var cursor = 0; cursor <= 4; cursor++) {
            for (var mess = 0; mess < 3; mess++) {
              final fake = FakeOmpAsk(qs);
              fake.seed(
                0,
                cursor: cursor,
                selected: mess == 0 ? <int>{} : {for (var i = 0; i < 4; i++) if (rnd.nextBool()) i},
                custom: mess == 2 ? 'an old answer' : null,
              );
              final want = [AskAnswer(selected: _subset(mask, 4), custom: custom)];
              final run = _drive(fake, qs, want);
              _expectAnswered(fake, qs, want, run, 'mask $mask custom $custom cursor $cursor mess $mess');
              runs++;
            }
          }
        }
      }
      expect(runs, 480);
    });

    test('Enter never toggles: the final key is an Enter off the Other row', () {
      final qs = [toolsQuestion];
      final fake = FakeOmpAsk(qs)..seed(0, cursor: 4, selected: {0, 2});
      final run = _drive(fake, qs, const [AskAnswer(selected: [0, 2])]);
      expect((run.steps.first as AskSend).keys, ['up', 'enter']);
      expect(fake.submitted!.single.selected, [0, 2]);
    });

    test('a long answer cut with an ellipsis on the review tab still matches', () {
      final ask = _ask(releaseQuestions);
      final answers = [
        const AskAnswer(selected: [24]),
        const AskAnswer(selected: [1, 2], custom: 'tag: v2 — bản thử'),
      ];
      final screen = fixtureScreen('ask-long-review-custom');
      expect(parseAskScreen(screen).review.last.answer, endsWith('…'));
      final step = nextAskStep(ask, answers, screen) as AskSend;
      expect(step.keys, ['enter']);
      expect(step.submits, isTrue);
      final other = nextAskStep(ask, [answers[0], const AskAnswer(selected: [1, 2], custom: 'tag: v3')], screen) as AskSend;
      expect(other.keys, ['shift+tab'], reason: 'question 2 of 2 is one tab back from the review tab');
    });

    test('from the captured screens', () {
      final ask = _ask([toolsQuestion]);
      const want = [AskAnswer(selected: [0, 2])];
      // nothing ticked, cursor on Lint: tick Lint, walk to Integration tests, tick it
      expect((nextAskStep(ask, want, fixtureScreen('ask-multi')) as AskSend).keys, ['space', 'down', 'down', 'space']);
      // Lint ticked, cursor on Lint
      expect((nextAskStep(ask, want, fixtureScreen('ask-multi-one')) as AskSend).keys, ['down', 'down', 'space']);
      // both ticked, cursor on Integration tests: confirm
      final done = nextAskStep(ask, want, fixtureScreen('ask-multi-two')) as AskSend;
      expect(done.keys, ['enter']);
      expect(done.submits, isTrue);
      // on the review tab the answers match: submit
      expect((nextAskStep(ask, want, fixtureScreen('ask-multi-review')) as AskSend).keys, ['enter']);
      // the review tab shows something else: go back to the question (one tab)
      final back = nextAskStep(ask, const [AskAnswer(selected: [1])], fixtureScreen('ask-multi-review')) as AskSend;
      expect(back.keys, ['shift+tab']);
    });
  });

  group('several questions in a form', () {
    final qs = formQuestions;
    final answersets = <List<AskAnswer>>[
      const [AskAnswer(selected: [2]), AskAnswer(selected: [0, 2]), AskAnswer(custom: 'Hà Nội — dự án')],
      const [AskAnswer(selected: [0]), AskAnswer(), AskAnswer()],
      const [AskAnswer(custom: 'my own store'), AskAnswer(selected: [1, 2, 3]), AskAnswer(custom: 'x')],
      const [AskAnswer(selected: [1]), AskAnswer(selected: [0, 1, 2, 3], custom: 'and more'), AskAnswer()],
      const [AskAnswer(), AskAnswer(selected: [3]), AskAnswer(custom: 'Tên')],
    ];

    test('every answer set from every tab, with random cursors and old answers', () {
      final rnd = Random(11);
      var runs = 0;
      for (var a = 0; a < answersets.length; a++) {
        for (var tab = 0; tab <= 3; tab++) {
          for (var trial = 0; trial < 6; trial++) {
            final fake = FakeOmpAsk(qs, headers: formHeaders);
            // A chosen radio cannot be un-chosen in omp, so an old choice is only
            // seeded where the answer is a choice or a typed answer replaces it.
            final wantsChoice = answersets[a][0].selected.isNotEmpty || answersets[a][0].custom != null;
            fake.seed(0, cursor: rnd.nextInt(4), selected: wantsChoice && rnd.nextBool() ? {rnd.nextInt(3)} : <int>{});
            fake.seed(1, cursor: rnd.nextInt(5), selected: {for (var i = 0; i < 4; i++) if (rnd.nextBool()) i});
            fake.seed(2, custom: rnd.nextBool() ? 'old name' : null);
            if (trial.isOdd) fake.seed(0, custom: 'an old custom');
            fake.setTab(tab);
            final run = _drive(fake, qs, answersets[a]);
            _expectAnswered(fake, qs, answersets[a], run, 'set $a tab $tab trial $trial');
            runs++;
          }
        }
      }
      expect(runs, 120);
    });

    test('a clean run takes few round trips', () {
      final fake = FakeOmpAsk(qs, headers: formHeaders);
      final run = _drive(fake, qs, answersets[0]);
      _expectAnswered(fake, qs, answersets[0], run, 'clean');
      // choose, toggles, next, open editor, type, confirm, submit
      expect(run.steps.whereType<AskSend>().length, lessThanOrEqualTo(8), reason: run.steps.join('\n'));
    });

    test('the plan reads the step from the screen, not from what was sent before', () {
      final ask = _ask(qs);
      final a = answersets[0];
      // tab 2 of the form with the custom answer already set: confirm it by moving on
      expect((nextAskStep(ask, a, fixtureScreen('ask-form-q3-custom')) as AskSend).keys, ['tab']);
      // the review tab agrees with everything: submit
      expect((nextAskStep(ask, a, fixtureScreen('ask-form-review')) as AskSend).keys, ['enter']);
      // the review tab lists DuckDB for question 1, the user wants SQLite: go back 3 tabs, or forward 1
      final fix = nextAskStep(ask, const [AskAnswer(selected: [0]), AskAnswer(selected: [0, 2]), AskAnswer(custom: 'Hà Nội — dự án')],
          fixtureScreen('ask-form-review')) as AskSend;
      expect(fix.keys, ['tab']);
      // the editor is open on question 3 with the right text: Enter
      expect(
        (nextAskStep(ask, a, fixtureScreen('ask-form-editor-prefilled')) as AskSend).keys,
        ['enter'],
      );
      // question 1 answered DuckDB (index 2), the user wants Postgres: one up, Enter
      expect((nextAskStep(ask, const [AskAnswer(selected: [1]), AskAnswer(), AskAnswer()], fixtureScreen('ask-form-q1-answered')) as AskSend).keys,
          ['up', 'enter']);
    });
  });

  group('long lists that scroll', () {
    final qs = releaseQuestions;

    test('every one of 30 options and Other, from the top, the middle and the bottom', () {
      for (final cursor in [0, 14, 30]) {
        for (var t = 0; t <= 30; t++) {
          final a = [
            t == 30 ? const AskAnswer(custom: 'Release 99, tự nhập') : AskAnswer(selected: [t]),
            AskAnswer(selected: t.isEven ? const [0, 2] : const [1]),
          ];
          final fake = FakeOmpAsk(qs, cols: 58, headers: releaseHeaders)..seed(0, cursor: cursor);
          _expectAnswered(fake, qs, a, _drive(fake, qs, a), 'cursor $cursor target $t');
        }
      }
    });

    test('a multi-select taller than the box: ticks rows that are out of view', () {
      final big = AskQuestion(
        id: 'many',
        question: 'Which of these forty?',
        multi: true,
        options: [for (var i = 1; i <= 40; i++) AskOption(label: 'Choice $i', description: i % 7 == 0 ? 'seven' : '')],
      );
      final rnd = Random(3);
      for (var trial = 0; trial < 25; trial++) {
        final fake = FakeOmpAsk([big]);
        fake.seed(0,
            cursor: rnd.nextInt(41),
            selected: {for (var i = 0; i < 40; i++) if (rnd.nextInt(5) == 0) i},
            custom: trial % 5 == 0 ? 'old' : null);
        final want = [
          AskAnswer(
            selected: [for (var i = 0; i < 40; i++) if (rnd.nextInt(4) == 0) i],
            custom: trial % 3 == 0 ? 'also: this' : null,
          ),
        ];
        final run = _drive(fake, [big], want);
        _expectAnswered(fake, [big], want, run, 'trial $trial');
      }
    });
  });

  group('zero options', () {
    test('only a typed answer is possible; skipping moves on', () {
      final qs = formQuestions;
      final fake = FakeOmpAsk(qs, headers: formHeaders)..setTab(2);
      const want = [AskAnswer(selected: [0]), AskAnswer(), AskAnswer(custom: 'Dự án mới')];
      _expectAnswered(fake, qs, want, _drive(fake, qs, want), 'zero options');
    });

    test('a lone question with nothing to choose and nothing to type cannot be answered', () {
      final q = [const AskQuestion(id: 'a', question: 'Anything?', options: [])];
      final fake = FakeOmpAsk(q);
      final run = _drive(fake, q, const [AskAnswer()]);
      expect(run.outcome, 'nothing to answer');
      expect(fake.closed, isFalse);
    });
  });

  group('refusing to guess', () {
    test('a dialog that does not react gets two more tries, then the driver gives up', () {
      final ask = _ask([dbQuestion]);
      final d = OmpAskDriver(ask, const [AskAnswer(selected: [2])]);
      final screen = fixtureScreen('ask-single');
      expect(d.next(screen), isA<AskSend>());
      expect(d.next(screen), isA<AskSend>());
      expect(d.next(screen), isA<AskMismatch>());
    });

    test('another question on screen', () {
      final step = nextAskStep(_ask([toolsQuestion]), const [AskAnswer(selected: [0])], fixtureScreen('ask-single'));
      expect(step, isA<AskMismatch>());
    });

    test('radios where checkboxes were asked, and the other way round', () {
      final asked = AskQuestion(id: 'db', question: dbQuestion.question, options: dbQuestion.options, multi: true);
      expect(nextAskStep(_ask([asked]), const [AskAnswer(selected: [0])], fixtureScreen('ask-single')), isA<AskMismatch>());
    });

    test('a different number of tabs', () {
      final step = nextAskStep(_ask(formQuestions.sublist(0, 2)), const [AskAnswer(), AskAnswer()], fixtureScreen('ask-form-q1'));
      expect(step, isA<AskMismatch>());
    });

    test('a draft in the composer', () {
      final fake = FakeOmpAsk([dbQuestion]);
      final screen = fake.screen().replaceFirst('↑/↓ move', 'Finish or clear the current prompt to answer');
      final step = nextAskStep(_ask([dbQuestion]), const [AskAnswer(selected: [1])], screen);
      expect((step as AskMismatch).why, contains('draft'));
    });

    test('a single choice with two answers; a lone single choice with none', () {
      final ask = _ask([dbQuestion]);
      expect(nextAskStep(ask, const [AskAnswer(selected: [0, 1])], fixtureScreen('ask-single')), isA<AskMismatch>());
      expect(nextAskStep(ask, const [AskAnswer()], fixtureScreen('ask-single')), isA<AskMismatch>());
    });

    test('no dialog on screen is Done; a different dialog is not an ask', () {
      final ask = _ask([dbQuestion]);
      const a = [AskAnswer(selected: [1])];
      expect(nextAskStep(ask, a, 'just a prompt\n π > Haiku'), isA<AskDone>());
      expect(nextAskStep(ask, a, fixtureScreen('approval-bash')), isA<AskDone>());
    });

    test('a review that never matches stops after two fixes instead of looping', () {
      // The fake shows the real review, but the driver is told a label that cannot match
      // (its text differs from what omp draws).
      final lying = [
        AskQuestion(id: 'tools', question: toolsQuestion.question, multi: true, options: [
          const AskOption(label: 'Lint'),
          const AskOption(label: 'Unit tests'),
          const AskOption(label: 'Integration tests'),
          const AskOption(label: 'Type checks'),
        ]),
      ];
      final d = OmpAskDriver(_ask(lying), const [AskAnswer(selected: [3])]);
      final fake = FakeOmpAsk([toolsQuestion]);
      final run = _drive(fake, [toolsQuestion], const [AskAnswer(selected: [3])], driver: d);
      expect(run.outcome, isNot('done'));
      expect(fake.submitted, isNull);
    });
  });
}
