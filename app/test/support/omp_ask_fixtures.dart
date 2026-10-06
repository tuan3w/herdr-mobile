import 'dart:io';

import 'package:herdr_mobile/data/observed/observed_contracts.dart';

import 'fake_omp_ask.dart';

/// The questions behind the captured screens in `test/fixtures/prompts/omp/`
/// (the tool calls the real omp was given), and the key sequences that led to
/// each capture.

final dbQuestion = AskQuestion(
  id: 'db',
  question: 'Which database should the project use?',
  options: const [
    AskOption(label: 'SQLite', description: 'Single file, zero setup, good for local tools'),
    AskOption(label: 'Postgres', description: 'Full server, best for concurrent writes and large data sets'),
    AskOption(label: 'DuckDB', description: 'Embedded columnar engine for analytics queries'),
  ],
  recommended: 0,
);

const toolsQuestion = AskQuestion(
  id: 'tools',
  question: 'Which tools should the pipeline run?',
  multi: true,
  options: [
    AskOption(label: 'Lint', description: 'Static checks on every commit'),
    AskOption(label: 'Unit tests', description: 'Fast tests, under a minute'),
    AskOption(
      label: 'Integration tests',
      description: 'Needs a database container and takes several minutes on a cold CI runner, so schedule it nightly',
    ),
    AskOption(label: 'Type check'),
  ],
);

const formQuestions = [
  AskQuestion(
    id: 'storage',
    question: 'Where should data live?',
    recommended: 1,
    options: [
      AskOption(label: 'SQLite', description: 'Single file'),
      AskOption(label: 'Postgres', description: 'Server with concurrent writes'),
      AskOption(label: 'DuckDB', description: 'Analytics engine'),
    ],
  ),
  AskQuestion(
    id: 'extras',
    question: 'Which extras do you want?',
    multi: true,
    options: [
      AskOption(label: 'Docker image'),
      AskOption(label: 'CI workflow'),
      AskOption(label: 'Changelog'),
      AskOption(label: 'Pre-commit hooks'),
    ],
  ),
  AskQuestion(id: 'name', question: 'What should the project be called?', options: []),
];
const formHeaders = {0: 'Storage'};

const _hotel = 'Hotel (use `hotel.cfg`)';

final narrowList = AskQuestion(
  id: 'pick',
  question: 'Pick a target for the release, considering the long list below?',
  recommended: 7,
  options: const [
    AskOption(label: 'Alpha'),
    AskOption(label: 'Bravo'),
    AskOption(
      label: 'Charlie with a considerably longer label that wraps over several lines in a narrow pane',
      description:
          'A very long description that keeps going and going so that it needs more than two rows when wrapped in a narrow pane like this one',
    ),
    AskOption(label: 'Delta'),
    AskOption(label: 'Echo'),
    AskOption(label: 'Foxtrot'),
    AskOption(label: 'Golf'),
    AskOption(label: _hotel),
    AskOption(label: 'India'),
    AskOption(label: 'Juliet'),
    AskOption(label: 'Kilo'),
    AskOption(label: 'Lima'),
    AskOption(label: 'Mike'),
    AskOption(label: 'Tiếng Việt có dấu: Đà Nẵng'),
  ],
);

final releaseQuestions = [
  AskQuestion(
    id: 'pick',
    question: 'Pick a release number?',
    recommended: 14,
    options: [
      for (var i = 1; i <= 29; i++)
        AskOption(
          label: i == 4
              ? 'Release 04 with a considerably longer label that wraps over several lines in a narrow pane'
              : 'Release ${i.toString().padLeft(2, '0')}',
        ),
      const AskOption(label: 'Tiếng Việt có dấu: Đà Nẵng'),
    ],
  ),
  const AskQuestion(
    id: 'flags',
    question: 'Which flags?',
    multi: true,
    options: [AskOption(label: 'Dry run'), AskOption(label: 'Tag'), AskOption(label: 'Sign')],
  ),
];
const releaseHeaders = {1: 'Release flags and other long things'};

const yesNoQuestion = AskQuestion(
  id: 'write_approval',
  question: "Approve writing hello.txt with content 'hello omq'?",
  options: [AskOption(label: 'Yes'), AskOption(label: 'No')],
);

/// One capture: the fixture file, how the fake is built, and what to press.
class AskCapture {
  const AskCapture(this.fixture, this.questions, this.steps, {this.cols = 119, this.headers = const {}});

  final String fixture;
  final List<AskQuestion> questions;

  /// Herdr key names, or `paste:<text>`.
  final List<String> steps;
  final int cols;
  final Map<int, String> headers;

  FakeOmpAsk build() {
    final fake = FakeOmpAsk(questions, cols: cols, headers: headers);
    for (final s in steps) {
      s.startsWith('paste:') ? fake.paste(s.substring(6)) : fake.press(s);
    }
    return fake;
  }
}

List<String> _repeat(String key, int n) => List.filled(n, key);

final askCaptures = <AskCapture>[
  AskCapture('ask-single', [dbQuestion], []),
  AskCapture('ask-single-down', [dbQuestion], ['down']),
  AskCapture('ask-single-other', [dbQuestion], ['down', 'down', 'down']),
  AskCapture('ask-other-editor', [dbQuestion], ['down', 'down', 'down', 'enter']),
  AskCapture('ask-other-typed', [dbQuestion], ['down', 'down', 'down', 'enter', 'paste:Postgres, nhưng dùng PgBouncer']),
  AskCapture('ask-yesno', [yesNoQuestion], []),
  AskCapture('ask-multi', [toolsQuestion], []),
  AskCapture('ask-multi-one', [toolsQuestion], ['space']),
  AskCapture('ask-multi-two', [toolsQuestion], ['space', 'down', 'down', 'space']),
  AskCapture('ask-multi-review', [toolsQuestion], ['space', 'down', 'down', 'space', 'tab']),
  AskCapture('ask-form-q1', formQuestions, [], headers: formHeaders),
  AskCapture('ask-form-q2', formQuestions, ['down', 'enter'], headers: formHeaders),
  AskCapture(
    'ask-form-q2-toggled',
    formQuestions,
    ['down', 'enter', 'space', 'down', 'down', 'space'],
    headers: formHeaders,
  ),
  AskCapture(
    'ask-form-q3',
    formQuestions,
    ['down', 'enter', 'space', 'down', 'down', 'space', 'enter'],
    headers: formHeaders,
  ),
  AskCapture(
    'ask-form-review',
    formQuestions,
    [
      'down', 'enter', 'space', 'down', 'down', 'space', 'enter',
      'enter', 'paste:abc def', 'ctrl+u', 'paste:Hà Nội — dự án', 'enter',
    ],
    headers: formHeaders,
  ),
  AskCapture(
    'ask-form-q3-custom',
    formQuestions,
    [
      'down', 'enter', 'space', 'down', 'down', 'space', 'enter',
      'enter', 'paste:abc def', 'ctrl+u', 'paste:Hà Nội — dự án', 'enter',
      'shift+tab',
    ],
    headers: formHeaders,
  ),
  AskCapture(
    'ask-form-editor-prefilled',
    formQuestions,
    [
      'down', 'enter', 'space', 'down', 'down', 'space', 'enter',
      'enter', 'paste:abc def', 'ctrl+u', 'paste:Hà Nội — dự án', 'enter',
      'shift+tab', 'enter',
    ],
    headers: formHeaders,
  ),
  AskCapture(
    'ask-form-q1-answered',
    formQuestions,
    [
      'down', 'enter', 'space', 'down', 'down', 'space', 'enter',
      'enter', 'paste:abc def', 'ctrl+u', 'paste:Hà Nội — dự án', 'enter',
      'shift+tab', 'enter', 'esc', 'shift+tab', 'shift+tab',
    ],
    headers: formHeaders,
  ),
  AskCapture('ask-long-narrow', [narrowList], [], cols: 58),
  AskCapture('ask-long-narrow-expanded', [narrowList], ['ctrl+o'], cols: 58),
  AskCapture('ask-long-scroll', releaseQuestions, [], cols: 58, headers: releaseHeaders),
  AskCapture('ask-long-scroll-down', releaseQuestions, _repeat('down', 7), cols: 58, headers: releaseHeaders),
  AskCapture('ask-long-scroll-bottom', releaseQuestions, _repeat('down', 27), cols: 58, headers: releaseHeaders),
  AskCapture('ask-long-flags', releaseQuestions, [..._repeat('down', 27), 'tab'], cols: 58, headers: releaseHeaders),
  AskCapture(
    'ask-long-review-unanswered',
    releaseQuestions,
    [..._repeat('down', 27), 'tab', 'tab'],
    cols: 58,
    headers: releaseHeaders,
  ),
  // The phone's driver on a real omp: scrambled by hand, then the key plan.
  AskCapture(
    'ask-long-review-custom',
    releaseQuestions,
    [
      'down', 'down', 'down', 'enter', 'space', 'tab',
      'tab', ..._repeat('down', 7), 'enter',
      'space', 'down', 'space', 'down', 'space',
      'down', 'enter', 'paste:tag: v2 — bản thử', 'enter',
    ],
    cols: 58,
    headers: releaseHeaders,
  ),
];

// ---------------------------------------------------------------- fixtures

const fixtureDir = 'test/fixtures/prompts/omp';

final _ansi = RegExp(r'\x1B\[[0-9;:?<=>]*[ -/]*[@-~]');

/// The screen part of fixture [name] (header removed), ANSI kept.
String fixtureScreen(String name) {
  final lines = File('$fixtureDir/$name.txt').readAsLinesSync();
  return lines.skipWhile((l) => l.startsWith('# ')).join('\n');
}

/// The header of fixture [name] as key/value pairs.
Map<String, String> fixtureHeader(String name) {
  final out = <String, String>{};
  for (final l in File('$fixtureDir/$name.txt').readAsLinesSync()) {
    final m = RegExp(r'^# ([a-z_]+): ?(.*)$').firstMatch(l);
    if (m == null) break;
    out[m[1]!] = m[2]!;
  }
  return out;
}

/// The last titled box of fixture [name], plain text, trailing spaces trimmed.
List<String> fixtureDialog(String name) {
  final lines = [for (final l in fixtureScreen(name).split('\n')) l.replaceAll('\r', '').replaceAll(_ansi, '').trimRight()];
  final top = lines.lastIndexWhere((l) => l.startsWith('╭─ '));
  final bottom = lines.indexWhere((l) => l.startsWith('╰'), top);
  return lines.sublist(top, bottom + 1);
}
