import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/command_risk.dart' show standingPermission;
import 'package:herdr_mobile/data/repositories/prompt_detector.dart';

/// `(label, keys, needsConfirm)` per reply, for compact expectations.
typedef _R = (String, List<String>, bool);

String _fmt(_R r) => '${r.$1} | ${r.$2.join(',')} | ${r.$3 ? 'confirm' : 'plain'}';

List<String> _replies(PromptInfo p) => [
      for (final r in p.replies) _fmt((r.label, r.keys, r.needsConfirm)),
    ];

PromptInfo? _detect(String screen) => detectPrompt(screen.split('\n'));

class _Case {
  const _Case(this.name, this.screen, this.replies, {this.question, this.subject = '', this.risks});
  final String name;
  final String screen;
  final List<_R> replies;
  final String? question;
  final String subject;

  /// `QuickReply.risk` per reply, when the case pins the reasons.
  final List<String?>? risks;
}

const _enter = ['enter'];

const _positives = <_Case>[
  _Case(
    'Claude Code bash permission',
    '''
 Bash command

   git push origin main
   Push to remote

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for git push commands in /home/u/proj
   3. No, and tell Claude what to do differently (esc)
''',
    [
      ('1. Yes', ['1', 'enter'], true),
      ("2. Yes, don't ask again", ['2', 'enter'], true),
      ('3. No', ['3', 'enter'], false),
    ],
    question: 'Do you want to proceed?',
    subject: 'git push origin main\nPush to remote',
    risks: ['pushes to a remote', standingPermission, null],
  ),
  _Case(
    'Claude Code boxed permission with footer hints',
    '''
╭──────────────────────────────────────────────╮
│ Bash command                                 │
│                                              │
│   npm test                                   │
│   Run the tests                              │
│                                              │
│ Do you want to proceed?                      │
│ ❯ 1. Yes                                     │
│   2. Yes, and don't ask again for npm commands │
│   3. No, and tell Claude what to do differently (esc) │
╰──────────────────────────────────────────────╯
  Esc to cancel · Tab to amend · ctrl+e to explain
''',
    [
      ('1. Yes', ['1', 'enter'], false),
      ("2. Yes, don't ask again", ['2', 'enter'], true),
      ('3. No', ['3', 'enter'], false),
    ],
    question: 'Do you want to proceed?',
    subject: 'npm test\nRun the tests',
  ),
  _Case(
    'Claude Code file edit with two options and the cursor on the second',
    '''
 Edit file
 lib/main.dart

 Do you want to make this edit to main.dart?
   1. Yes
 ❯ 2. No, and tell Claude what to do differently (esc)
''',
    [
      ('1. Yes', ['1', 'enter'], false),
      ('2. No', ['2', 'enter'], false),
    ],
  ),
  _Case(
    'Claude Code edit with a shift+tab option hint',
    '''
 Do you want to make this edit to a.dart?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No, and tell Claude what to do differently (esc)
''',
    [
      ('1. Yes', ['1', 'enter'], false),
      ('2. Yes, allow all edits during this…', ['2', 'enter'], true),
      ('3. No', ['3', 'enter'], false),
    ],
  ),
  _Case(
    'Claude Code trust prompt',
    '''
 Do you trust the files in this folder?

 /home/u/proj

 ❯ 1. Yes, proceed
   2. No, exit

 Enter to confirm · Esc to exit
''',
    [
      ('1. Yes, proceed', ['1', 'enter'], false),
      ('2. No, exit', ['2', 'enter'], false),
    ],
    question: 'Do you trust the files in this folder?',
    subject: '/home/u/proj',
  ),
  _Case(
    'Claude Code question with option descriptions',
    '''
 ☐ Database
 Which database should we use?
 ❯ 1. PostgreSQL
      Relational, strong consistency
   2. SQLite
      Embedded, zero setup
   3. Other

 Enter to select · ↑/↓ to navigate · Esc to cancel
''',
    [
      ('1. PostgreSQL', ['1', 'enter'], false),
      ('2. SQLite', ['2', 'enter'], false),
      ('3. Other', ['3', 'enter'], false),
    ],
    question: 'Which database should we use?',
  ),
  _Case(
    'Codex approval: pointer, hotkey hints, command under the question',
    '''
  Would you like to run the following command?

  Reason: needs network access

  \$ git push

› 1. Yes, proceed (y)
  2. Yes, and don't ask again for this command (a)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
''',
    [
      ('1. Yes, proceed', ['1', 'enter'], true),
      ("2. Yes, don't ask again", ['2', 'enter'], true),
      ('3. No', ['3', 'enter'], false),
    ],
    question: 'Would you like to run the following command?',
    subject: '\$ git push',
    risks: ['pushes to a remote', standingPermission, null],
  ),
  _Case(
    'wrapped option text stays one option',
    '''
Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again for
     git commit commands in /x
  3. No
''',
    [
      ('1. Yes', ['1', 'enter'], false),
      ("2. Yes, don't ask again", ['2', 'enter'], true),
      ('3. No', ['3', 'enter'], false),
    ],
  ),
  _Case(
    'five options (worst case for chips)',
    '''
Which model?
❯ 1. opus
  2. sonnet
  3. haiku
  4. gpt-5
  5. none
''',
    [
      ('1. opus', ['1', 'enter'], false),
      ('2. sonnet', ['2', 'enter'], false),
      ('3. haiku', ['3', 'enter'], false),
      ('4. gpt-5', ['4', 'enter'], false),
      ('5. none', ['5', 'enter'], false),
    ],
  ),
  _Case(
    'numbered menu with ) separators and no pointer but a question',
    '''
Choose an action:
1) Retry
2) Skip
3) Abort
''',
    [
      ('1. Retry', ['1', 'enter'], false),
      ('2. Skip', ['2', 'enter'], false),
      ('3. Abort', ['3', 'enter'], false),
    ],
  ),
  _Case(
    'output before the menu does not matter, only what is at the bottom',
    '''
1. an old list
2. from earlier output
Done editing, now:
Do you want to proceed?
❯ 1. Yes
  2. No
''',
    [
      ('1. Yes', ['1', 'enter'], false),
      ('2. No', ['2', 'enter'], false),
    ],
  ),
  // ---- destructive handling
  _Case(
    'destructive command above marks the affirmative options, never No',
    '''
 Bash command
   rm -rf build/
   Remove the build directory

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for rm commands in /x
   3. No, and tell Claude what to do differently (esc)
''',
    [
      ('1. Yes', ['1', 'enter'], true),
      ("2. Yes, don't ask again", ['2', 'enter'], true),
      ('3. No', ['3', 'enter'], false),
    ],
    subject: 'rm -rf build/\nRemove the build directory',
    risks: ['deletes files', standingPermission, null],
  ),
  _Case(
    'destructive option text',
    '''
Which cleanup?
❯ 1. Delete all branches
  2. Keep them
''',
    [
      ('1. Delete all branches', ['1', 'enter'], true),
      ('2. Keep them', ['2', 'enter'], false),
    ],
  ),
  _Case(
    'force push',
    '''
 git push --force origin main
 Do you want to proceed?
 ❯ 1. Yes
   2. No
''',
    [
      ('1. Yes', ['1', 'enter'], true),
      ('2. No', ['2', 'enter'], false),
    ],
    risks: ['force-pushes', null],
    subject: 'git push --force origin main',
  ),
  // ---- inline prompts
  _Case('[y/N] (overwrite counts as destructive)', 'Overwrite config.json? [y/N]\n', [
    ('Yes', ['y', 'enter'], true),
    ('No', ['n', 'enter'], false),
  ]),
  _Case('(y/n)', 'Install dependencies? (y/n) ', [
    ('Yes', ['y', 'enter'], false),
    ('No', ['n', 'enter'], false),
  ]),
  _Case('[Y/n]', 'Proceed with installation [Y/n]: ', [
    ('Yes', ['y', 'enter'], false),
    ('No', ['n', 'enter'], false),
  ]),
  _Case('uppercase (Y/N)', 'Apply the patch (Y/N)?', [
    ('Yes', ['y', 'enter'], false),
    ('No', ['n', 'enter'], false),
  ]),
  _Case(
    'ssh host key (yes/no) needs the whole word',
    'Are you sure you want to continue connecting (yes/no/[fingerprint])? ',
    [
      ('Yes', ['y', 'e', 's', 'enter'], false),
      ('No', ['n', 'o', 'enter'], false),
    ],
  ),
  _Case(
    'destructive row above an inline prompt marks only Yes',
    'This will DROP TABLE users and delete every row.\nContinue? [y/N]',
    [
      ('Yes', ['y', 'enter'], true),
      ('No', ['n', 'enter'], false),
    ],
    question: 'This will DROP TABLE users and delete every row.\nContinue? [y/N]',
  ),
  _Case(
    'inline prompt followed by a hint row',
    'Remove 3 files? [y/N]\n  (esc to cancel)',
    [
      ('Yes', ['y', 'enter'], true),
      ('No', ['n', 'enter'], false),
    ],
  ),
  // ---- press enter
  _Case('Press Enter to continue', 'Installed.\nPress Enter to continue', [
    ('Enter', _enter, false),
  ]),
  _Case('press any key', 'Update complete\nPress any key to continue...', [
    ('Enter', _enter, false),
  ]),
  // ---- un-numbered menus
  _Case(
    'pointer menu, cursor on first',
    '''
Allow this tool call?
❯ Allow once
  Allow always
  Deny
''',
    [
      ('Allow once', _enter, false),
      ('Allow always', ['down', 'enter'], true),
      ('Deny', ['down', 'down', 'enter'], false),
    ],
    question: 'Allow this tool call?',
  ),
  _Case(
    'pointer menu, cursor in the middle walks both ways',
    '''
Allow this tool call?
  Allow once
❯ Allow always
  Deny
''',
    [
      ('Allow once', ['up', 'enter'], false),
      ('Allow always', _enter, true),
      ('Deny', ['down', 'enter'], false),
    ],
  ),
  _Case(
    'pointer menu with a destructive question',
    '''
Allow bash: rm -rf node_modules?
❯ Allow once
  Deny
''',
    [
      ('Allow once', _enter, true),
      ('Deny', ['down', 'enter'], false),
    ],
  ),
  _Case(
    'radio menu',
    '''
Pick a mode?
○ Fast
● Careful
○ Thorough
''',
    [
      ('Fast', ['up', 'enter'], false),
      ('Careful', _enter, false),
      ('Thorough', ['down', 'enter'], false),
    ],
  ),
];

const _negatives = <String, String>{
  'empty': '',
  'only blank rows': '\n   \n\n',
  'shell prompt': 'user@host:~/proj\$ ',
  'a README list that scrolled past': '''
Here are the steps:
1. Install
2. Build
3. Run
All done, tell me if you want changes.
''',
  'a README list at the bottom without a question': '''
I made these changes
1. Install
2. Build
3. Run
''',
  'a list with a quote marker and no question': '''
Notes
> 1. Install
  2. Build
''',
  'a long prose paragraph then a list': '''
There are a few things worth knowing before we continue with the refactor.
1. First thing
2. Second thing
''',
  'list not starting at 1': '''
Which?
2. two
3. three
''',
  'gap in numbering': '''
Which?
1. one
3. three
''',
  'a single option': '''
Do you want to proceed?
❯ 1. Yes
''',
  'two pointers': '''
Which?
❯ 1. one
❯ 2. two
''',
  'question without options': 'Do you want to proceed?',
  'a press-enter hint that is not last': '''
Press Enter to continue
and then some more output
''',
  'a y/n that is not last': '''
Overwrite? [y/N]
y
Overwritten 3 files.
''',
  '(yes/no) in prose': 'Should I document the (yes/no) syntax in the README for new users',
  'Claude working footer only': '✻ Thinking… (esc to interrupt)',
  'codex confirm dialog without a menu':
      'Press enter to confirm or esc to cancel',
  'menu followed by an unrelated line': '''
Do you want to proceed?
❯ 1. Yes
  2. No
Compiling the project for production now with all optimisations
''',
  'more than nine options': '''
Pick one?
❯ 1. a
  2. b
  3. c
  4. d
  5. e
  6. f
  7. g
  8. h
  9. i
  10. j
''',
  'unaligned bullet rows are not a pointer menu': '''
Next steps:
❯ run the tests
 deploy
''',
  'tall prose under a pointer': '''
Summary:
❯ This sentence is far too long to be a choice in a menu and so it is prose text
  Second
''',
  'radio without a selection': '''
Pick?
○ A
○ B
''',
  'radio with two selected': '''
Pick?
● A
● B
''',
};

void main() {
  group('detectPrompt', () {
    for (final c in _positives) {
      test(c.name, () {
        final p = _detect(c.screen);
        expect(p, isNotNull, reason: 'no prompt found');
        expect(_replies(p!), c.replies.map(_fmt).toList());
        if (c.question != null) expect(p.question, c.question);
        expect(p.question, isNotEmpty);
        expect(p.subject, c.subject);
        if (c.risks != null) expect([for (final r in p.replies) r.risk], c.risks);
        for (final r in p.replies) {
          expect(r.risk == null || r.needsConfirm, isTrue, reason: '${r.label}: a reason needs the confirm');
        }
      });
    }

    _negatives.forEach((name, screen) {
      test('no prompt: $name', () => expect(_detect(screen), isNull));
    });

    test('labels are capped', () {
      final p = _detect('''
Which?
❯ 1. ${'very long option text ' * 6}
  2. short
''');
      expect(p!.replies.first.label.length, lessThanOrEqualTo(40));
      expect(p.replies.first.label, endsWith('…'));
    });

    // The window is what keeps old output out of a prompt's reading. What it
    // drops of a command's own rows must not make the command look whole:
    // the rows left (5 of a 12-row command) fit the card, and `rm -rf /` was in
    // the first of them.
    test('rows the window dropped from a long command make it "long", not whole', () {
      final command = ['rm -rf /', for (var i = 2; i <= 12; i++) 'step $i'];
      String screen(List<String> rows) => [
            ' Bash command',
            ...rows.map((r) => '   $r'),
            ' Do you want to proceed?',
            ' ❯ 1. Yes',
            '   2. Yes, then B',
            '   3. Yes, then C',
            '   4. Yes, then D',
            '   5. Yes, then E',
            '   6. No',
          ].join('\n');
      // 12 rows fit exactly when the command has 4: nothing was dropped.
      final whole = _detect(screen(['echo one', 'echo two', 'echo three', 'echo four']))!;
      expect(whole.subject.split('\n'), ['echo one', 'echo two', 'echo three', 'echo four']);
      expect(whole.replies.first.needsConfirm, isFalse);
      // 12 command rows: the window keeps the last 5 of them and the question.
      final cut = _detect(screen(command))!;
      expect(cut.subject, isNot(contains('rm -rf')));
      expect(cut.replies.first.risk, longCommand);
      expect(cut.replies.last.needsConfirm, isFalse, reason: 'declining is always safe');
    });

    test('a Vietnamese question and options survive', () {
      final p = _detect('''
Bạn có muốn tiếp tục không?
❯ 1. Có
  2. Không, hãy làm khác đi
''');
      expect(p!.question, 'Bạn có muốn tiếp tục không?');
      expect(p.replies.map((r) => r.label), ['1. Có', '2. Không, hãy làm khác đi']);
    });

    test('a menu inside a box with side bars reads the same as without', () {
      const plain = '''
Do you want to proceed?
❯ 1. Yes
  2. No
''';
      final boxed = plain
          .trimRight()
          .split('\n')
          .map((l) => '│ ${l.padRight(30)} │')
          .join('\n');
      expect(_detect(boxed), _detect(plain));
    });

    test('is a pure function of its rows (equal input, equal output)', () {
      const s = 'Do you want to proceed?\n❯ 1. Yes\n  2. No';
      expect(_detect(s), _detect(s));
      expect(_detect(s).hashCode, _detect(s).hashCode);
    });
  });

  group('subject', () {
    const menu = '''
 Do you want to proceed?
 ❯ 1. Yes
   2. No
''';

    String subjectOf(String above) => _detect('$above$menu')!.subject;

    test('Claude MCP tool use: the call and its description', () {
      final p = _detect('''
 Tool use

   playwright - navigate (MCP)(url: "https://example.com")
   Navigate the browser to a URL

 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for playwright - navigate commands in /x
   3. No, and tell Claude what to do differently (esc)
''')!;
      expect(p.question, 'Do you want to proceed?');
      expect(p.subject, 'playwright - navigate (MCP)(url: "https://example.com")\nNavigate the browser to a URL');
      expect([for (final r in p.replies) r.risk], [null, standingPermission, null]);
    });

    test('Claude fetch: the URL and what Claude wants with it', () {
      final p = _detect('''
 Fetch

   https://example.com/docs
   Claude wants to fetch content from example.com

 Do you want to allow Claude to fetch this content?
 ❯ 1. Yes
   2. No, and tell Claude what to do differently (esc)
''')!;
      expect(p.question, 'Do you want to allow Claude to fetch this content?');
      expect(p.subject, 'https://example.com/docs\nClaude wants to fetch content from example.com');
      expect(p.replies.any((r) => r.needsConfirm), isFalse);
    });

    test('a long command whose header scrolled out still gets a subject, capped at 6 rows and marked', () {
      final p = _detect([
        ' Bash command',
        for (var i = 1; i <= 9; i++) '   part $i',
        ' Do you want to proceed?',
        ' ❯ 1. Yes',
        '   2. No',
        '   3. Not now',
      ].join('\n'))!;
      // Twelve rows fit: "Bash command" and "part 1" are gone; the block now
      // starts at the top of what is visible. Eight rows, six shown, the last
      // of them marked.
      expect(p.subject, [for (var i = 2; i <= 6; i++) 'part $i', 'part 7…'].join('\n'));
      expect(p.replies.map((r) => r.risk), [longCommand, null, null]);
      expect(p.replies.map((r) => r.needsConfirm), [true, false, false]);
    });

    test('exactly six rows are shown whole and are not "long"', () {
      final p = _detect([
        ' Bash command',
        for (var i = 1; i <= 6; i++) '   part $i',
        ' Do you want to proceed?',
        ' ❯ 1. Yes',
        '   2. No',
      ].join('\n'))!;
      expect(p.subject, [for (var i = 1; i <= 6; i++) 'part $i'].join('\n'));
      expect(p.replies.any((r) => r.needsConfirm), isFalse);
    });

    test('a row over 160 characters is cut with a mark, and the answer says the command is long', () {
      final p = _detect(' Bash command\n   echo ${'a' * 300}\n   Print it\n$menu')!;
      final rows = p.subject.split('\n');
      expect(rows.first.length, 160);
      expect(rows.first, endsWith('…'));
      expect(rows.last, 'Print it');
      expect(p.replies.map((r) => r.risk), [longCommand, null]);
    });

    test('a row as long as the previews allow was probably cut there: marked, and long', () {
      // The previews keep 160 characters of a row, indentation included.
      final p = _detect(' Bash command\n   ${'a' * 157}\n$menu')!;
      expect(p.subject, '${'a' * 157}…');
      expect(p.replies.map((r) => r.risk), [longCommand, null]);
      // A row that fits with room to spare is not.
      final short = _detect(' Bash command\n   ${'a' * 120}\n$menu')!;
      expect(short.subject, 'a' * 120);
      expect(short.replies.any((r) => r.needsConfirm), isFalse);
    });

    test('a dangerous tail the card cannot show still gates, with its own reason', () {
      // In the cut part of one row.
      final row = _detect(' Bash command\n   echo ${'a' * 300} && git -C . push -f\n$menu')!;
      expect(row.subject.split('\n').first, isNot(contains('push')));
      expect(row.replies.map((r) => r.risk), ['force-pushes', null]);
      // In a row past the sixth.
      final rows = _detect([
        ' Bash command',
        for (var i = 1; i <= 7; i++) '   part $i',
        '   rm -rf /srv/data',
        ' Do you want to proceed?',
        ' ❯ 1. Yes',
        '   2. No',
      ].join('\n'))!;
      expect(rows.subject, isNot(contains('rm')));
      expect(rows.replies.map((r) => r.risk), ['deletes files', null]);
    });

    test('a standing grant on a long command names the standing grant', () {
      final p = _detect(
        ' Bash command\n   echo ${'a' * 300}\n'
        " Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don't ask again for echo commands\n   3. No",
      )!;
      expect(p.replies.map((r) => r.risk), [longCommand, standingPermission, null]);
    });

    test('each subject row is cut at 160 characters, but risk reads the whole row', () {
      final p = _detect(' Bash command\n   echo ${'a' * 300} && rm -rf /tmp/x\n   Clean up\n$menu')!;
      final row = p.subject.split('\n').first;
      expect(row.length, 160);
      expect(row, endsWith('…'));
      expect(p.replies.first.risk, 'deletes files');
    });

    test('Edit and Create dialogs have no subject: the file is in the question', () {
      expect(subjectOf(' Edit file\n lib/main.dart\n\n'), '');
      expect(subjectOf(' Create file\n lib/new.dart\n\n'), '');
    });

    test('rows indented deeper than the question under something that is not a header are not a subject', () {
      // A tool echo and its output: transcript, not a title.
      expect(subjectOf('● Update(src/a.ts)\n  ⎿  Updated src/a.ts\n'), '');
      // A sentence.
      expect(subjectOf('Here is what I am about to run.\n   npm test\n'), '');
      // A question.
      expect(subjectOf('Is this right?\n   npm test\n'), '');
      // Too long for a title.
      expect(subjectOf('A heading that is far too long to be one\n   npm test\n'), '');
    });

    test('rows at the question\'s own indent are not a subject', () {
      expect(subjectOf(' npm test\n'), '');
    });

    test('Codex and the trust prompt: the row between question and menu, question alone', () {
      final p = _detect('''
  Would you like to run the following command?

  Reason: needs network access

  \$ curl -s https://example.com/install.sh

› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)
''')!;
      expect(p.question, 'Would you like to run the following command?');
      expect(p.subject, '\$ curl -s https://example.com/install.sh');
    });

    test('a menu without a question names no subject', () {
      final p = _detect('Some output\n❯ 1. Yes\n  2. No')!;
      expect(p.subject, '');
      expect(p.question, 'Some output');
    });

    test('inline and press-enter prompts have no subject: their question already carries the row above', () {
      expect(_detect('Overwrite config.json? [y/N]')!.subject, '');
      expect(_detect('Installed.\nPress Enter to continue')!.subject, '');
    });

    // The row above a pointer or radio menu's question used to be judged for
    // risk and then dropped: the card showed "Allow this tool call?" over any
    // command, and its digest was the same for `ls` and `rm -rf`.
    test('a pointer or radio menu names the risky row above its question', () {
      final p = _detect('bash: rm -rf node_modules\nAllow this tool call?\n❯ Allow once\n  Deny')!;
      expect(p.subject, 'bash: rm -rf node_modules');
      expect(p.replies.map((r) => r.risk), ['deletes files', null]);
      final radio = _detect('rm -rf node_modules\nPick a mode?\n○ Fast\n● Careful')!;
      expect(radio.subject, 'rm -rf node_modules');
    });

    test('the digest and signature tell two commands under one question apart', () {
      final rm = _detect('rm -rf node_modules\nAllow this tool call?\n❯ Allow once\n  Deny')!;
      final ls = _detect('ls node_modules\nAllow this tool call?\n❯ Allow once\n  Deny')!;
      expect(rm, isNot(ls));
      expect(rm.subject, isNot(ls.subject));
    });

    test('a numbered menu names the risky row above its question too', () {
      final p = _detect('git push --force origin main\nDo you want to proceed?\n❯ 1. Yes\n  2. No')!;
      expect(p.subject, 'git push --force origin main');
    });

    test('a row above the question that flags nothing is scrollback, not a subject', () {
      expect(_detect('Done editing, now:\nAllow this tool call?\n❯ Allow once\n  Deny')!.subject, '');
      expect(_detect('ls node_modules\nAllow this tool call?\n❯ Allow once\n  Deny')!.subject, '');
      // A diff above an edit dialog is deeper than the question: output.
      final p = _detect('Here is the diff for lib/a.dart.\n   10 - rm -rf build\n Do you want to make this edit?\n ❯ 1. Yes\n   2. No')!;
      expect(p.subject, '');
      expect(p.replies.first.needsConfirm, isTrue, reason: 'judged, even though not shown');
    });
  });

  group('risk', () {
    String? risk(String screen, [int reply = 0]) => _detect(screen)!.replies[reply].risk;

    const claude = '''
 Do you want to proceed?
 ❯ 1. Yes
   2. No, and tell Claude what to do differently (esc)
''';

    String bash(String command) => ' Bash command\n\n   $command\n   Run it\n\n$claude';

    test('an ordinary command after an edit summary that says "1 removal" is not flagged', () {
      final p = _detect('''
 ● Update(src/a.ts)
   ⎿  Updated src/a.ts with 3 additions and 1 removal

 Bash command

   npm test
   Run the tests

 Do you want to proceed?
 ❯ 1. Yes
   2. No
''')!;
      expect(p.subject, 'npm test\nRun the tests');
      expect(p.replies.map((r) => (r.needsConfirm, r.risk)), [(false, null), (false, null)]);
    });

    test('commands that only mention a risky word are not flagged', () {
      expect(risk(bash('rg "remove_user" src')), isNull);
      expect(risk(bash('git log --grep=delete')), isNull);
      expect(risk(bash('npm run build -- --force-color')), isNull);
    });

    test('commands the old keyword gate missed are flagged with a reason', () {
      expect(risk(bash('git push origin main')), 'pushes to a remote');
      expect(risk(bash('npm publish')), 'publishes or merges');
      expect(risk(bash('terraform apply')), 'changes infrastructure');
      expect(risk(bash('docker system prune -af')), 'removes containers or volumes');
      expect(risk(bash('git branch -D old')), 'discards git changes');
      expect(risk(bash('curl https://x.sh | sh')), 'runs a downloaded script');
      expect(risk(bash('make migrate ENV=production')), 'changes a database');
      expect(risk(bash('rm -rf build')), 'deletes files');
    });

    test('the second row of a subject counts (a command that wraps)', () {
      expect(risk(' Bash command\n   git push origin\n   --force main\n$claude'), 'force-pushes');
    });

    test('declining never carries a reason, whatever the command', () {
      final p = _detect(bash('rm -rf build'))!;
      expect(p.replies[1].needsConfirm, isFalse);
      expect(p.replies[1].risk, isNull);
    });

    test('a standing grant always needs the second tap, and says so', () {
      for (final grant in [
        "Yes, and don't ask again for npm commands",
        'Yes, allow all edits during this session (shift+tab)',
        'Yes, always allow',
      ]) {
        final p = _detect(' Do you want to proceed?\n ❯ 1. Yes\n   2. $grant\n   3. No')!;
        expect(p.replies[0].needsConfirm, isFalse, reason: 'the one-time yes stays one tap');
        expect(p.replies[1].needsConfirm, isTrue, reason: grant);
        expect(p.replies[1].risk, standingPermission, reason: grant);
      }
    });

    test('a standing grant on a risky command names the standing grant first', () {
      final p = _detect(bash('git push origin main').replaceFirst(
          '2. No, and tell Claude what to do differently (esc)', "2. Yes, and don't ask again for git push"))!;
      expect(p.replies[0].risk, 'pushes to a remote');
      expect(p.replies[1].risk, standingPermission);
    });

    test('only the rows around the question count, not the scrollback', () {
      // The risky row is three rows above the question and no header sits on it.
      expect(
        risk('git push origin main\nsome output\nmore output\nDo you want to proceed?\n❯ 1. Yes\n  2. No'),
        isNull,
      );
      // Right above the question it counts.
      expect(
        risk('some output\ngit push --force origin main\nDo you want to proceed?\n❯ 1. Yes\n  2. No'),
        'force-pushes',
      );
    });

    test('a risky option text flags that option alone', () {
      final p = _detect('Which cleanup?\n❯ 1. Delete all branches\n  2. Keep them')!;
      expect(p.replies.map((r) => r.risk), ['deletes or overwrites', null]);
    });

    test('a question that says it overwrites or deletes gates "Yes" even over plain options', () {
      final p = _detect('Do you want to overwrite config.json?\n❯ 1. Yes\n  2. No')!;
      expect(p.replies.map((r) => r.risk), ['deletes or overwrites', null]);
      expect(p.replies.map((r) => r.needsConfirm), [true, false]);
      final remove = _detect(' Do you want to remove the 3 stale branches?\n ❯ 1. Yes\n   2. No')!;
      expect(remove.replies.first.risk, 'deletes or overwrites');
    });

    test('a file name that contains a risky word is not a risky question', () {
      final p = _detect('Do you want to make this edit to delete_user.dart?\n❯ 1. Yes\n  2. No')!;
      expect(p.replies.any((r) => r.needsConfirm), isFalse);
    });

    test('with no subject the row above the question is read as a sentence too', () {
      expect(
        risk('I will delete the old build output.\nDo you want to proceed?\n❯ 1. Yes\n  2. No'),
        'deletes or overwrites',
      );
      // Two rows up is not read.
      expect(
        risk('I will delete the old build output.\nnpm test\nDo you want to proceed?\n❯ 1. Yes\n  2. No'),
        isNull,
      );
    });

    test('a subject row is a command: its description does not flag, its command does', () {
      expect(risk(' Bash command\n   ls build\n   Remove old output from the listing\n\n$claude'), isNull);
      expect(risk(' Bash command\n   rm -rf build\n   List the build directory\n\n$claude'), 'deletes files');
    });

    test('a command reason in the subject beats a sentence reason in the question', () {
      final p = _detect(
        ' Bash command\n   git push origin main\n   Push\n\n Do you want to delete the remote?\n ❯ 1. Yes\n   2. No',
      )!;
      expect(p.replies.first.risk, 'pushes to a remote');
    });

    test('a pointer-menu question that says it deletes gates the affirmative options', () {
      final p = _detect('Which files should be deleted?\n❯ Allow once\n  Deny')!;
      expect(p.replies.map((r) => r.risk), ['deletes or overwrites', null]);
    });

    test('the pointer menu reads the question and the row above it as a command', () {
      final p = _detect('Bash: git push origin main\nAllow this command?\n❯ Allow once\n  Deny')!;
      expect(p.replies.map((r) => r.risk), ['pushes to a remote', null]);
      // Two rows up is out of scope.
      final far = _detect('rm -rf build/\nnpm test\nAllow this command?\n❯ Allow once\n  Deny')!;
      expect(far.replies.any((r) => r.needsConfirm), isFalse);
    });

    test('Allow always in a pointer menu is a standing grant', () {
      final p = _detect('Allow this tool call?\n❯ Allow once\n  Allow always\n  Deny')!;
      expect(p.replies.map((r) => r.risk), [null, standingPermission, null]);
    });

    test('inline: the last row and the one before it, Yes only', () {
      final p = _detect('Running: git push origin main\nContinue? [y/N]')!;
      expect(p.replies.map((r) => r.risk), ['pushes to a remote', null]);
      final far = _detect('rm -rf build\nsome output\nmore output\nContinue? [y/N]')!;
      expect(far.replies.any((r) => r.needsConfirm), isFalse);
    });
  });

  group('model', () {
    test('a subject takes part in equality', () {
      const a = PromptInfo(question: 'q', replies: [QuickReply(label: 'a', keys: ['1'])], subject: 'x');
      const b = PromptInfo(question: 'q', replies: [QuickReply(label: 'a', keys: ['1'])], subject: 'y');
      expect(a, isNot(b));
      expect(a.hashCode, isNot(b.hashCode));
    });

    test('a risk takes part in equality and needs the confirm flag', () {
      const a = QuickReply(label: 'a', keys: ['1'], needsConfirm: true, risk: 'x');
      const b = QuickReply(label: 'a', keys: ['1'], needsConfirm: true, risk: 'y');
      expect(a, isNot(b));
      expect(() => QuickReply(label: 'a', keys: const ['1'], risk: 'x'), throwsAssertionError);
    });
  });

  group('Claude Code 2.1 command dialog (dashed rules)', () {
    // The layout of a real 2.1.293 screen (test/fixtures/prompts/claude/): the
    // command sits between two dashed rules, at the same indent as the
    // question, under a description.
    String dialog({String header = ' Bash command', String command = ' touch /tmp/x.txt', String note = ''}) => '''
$header
 Tip: auto mode handles these prompts for you
 Create empty file x.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
$command
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
$note Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for: touch
   3. No
''';

    test('the command is the subject, without the description and the tip', () {
      final p = _detect(dialog())!;
      expect(p.question, 'Do you want to proceed?');
      expect(p.subject, 'touch /tmp/x.txt');
    });

    test('a note between the rule and the question does not hide it', () {
      final p = _detect(dialog(note: ' This command requires approval\n'))!;
      expect(p.subject, 'touch /tmp/x.txt');
    });

    test('a subagent\'s title (after the dot) is still a title', () {
      expect(_detect(dialog(header: ' Bash command · from the general-purpose agent'))!.subject, 'touch /tmp/x.txt');
    });

    test('a dangerous command is judged from the subject and needs its second tap', () {
      final p = _detect(dialog(command: ' rm -rf /tmp/build'))!;
      expect(p.replies.first.needsConfirm, isTrue);
    });

    test('a dialog about a file keeps its diff out of the subject', () {
      final p = _detect('''
 Edit file
 note.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 1 -rm -rf /
 2 +hello there
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to make this edit to note.txt?
 ❯ 1. Yes
   2. No
''')!;
      expect(p.subject, isEmpty);
      expect(p.replies.first.needsConfirm, isFalse, reason: 'the removed text is not a command');
    });

    test('a command row of dashes behind the bar is the command, not a rule that hides the rows above it', () {
      final p = _detect('''
 Bash command
 Create a file
${'╌' * 53}
 │ rm -rf ~/work; cat <<'EOF'
 │ Done
 │ ${'╌' * 8}
 │ EOF
 │ echo ok
${'╌' * 53}
 Do you want to proceed?
 ❯ 1. Yes
   2. No
''')!;
      expect(p.subject, contains('rm -rf ~/work'));
      expect(p.replies.first.needsConfirm, isTrue, reason: 'the dangerous row is judged, whatever follows');
    });

    test('a preview never shows the stand-in of a rule', () {
      expect(isDashedRule(cleanPreviewRow('╌' * 30)!), isTrue);
      expect(cleanPreviewRow('╌╌╌'), isNull, reason: 'a short run is not a rule');
      expect(isDashedRule(cleanPreviewRow('──────────')??''), isFalse);
    });
  });

  group('Codex approval', () {
    test('a command that wraps is read whole, after its reason', () {
      final p = _detect('''
  Would you like to run the following command?

  Environment: local

  Reason: need network

  \$ rm -rf ~/work &&
    echo done

› 1. Yes, proceed (y)
  2. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
''')!;
      expect(p.subject, contains('rm -rf ~/work'));
      expect(p.subject, contains('echo done'));
      expect(p.subject, isNot(contains('Reason')));
    });
  });

  group('Codex question tool', () {
    test('a digit alone answers, because an enter after it would answer the next question', () {
      final p = _detect('''
  Question 1/2 (2 unanswered)
  Which room is the desk in?

  › 1. Office (Recommended)  The desk is in the office.
    2. Bedroom               The desk is in the bedroom.

  tab to add notes | enter to submit answer | esc to interrupt
''')!;
      expect(p.question, '1 of 2 · Which room is the desk in?', reason: 'the card is one question of a form');
      expect(p.replies.map((r) => r.keys), [['1'], ['2']]);
    });
  });

  group('cleanPreviewRow', () {
    test('strips side bars, keeps indentation, drops rules and blanks', () {
      expect(cleanPreviewRow('│   hello   │'), '  hello');
      expect(cleanPreviewRow('╭────────╮'), isNull);
      expect(cleanPreviewRow('   '), isNull);
      expect(cleanPreviewRow('trailing   '), 'trailing');
      expect(cleanPreviewRow('---'), isNull);
      expect(cleanPreviewRow('- item'), '- item');
    });
  });
}
