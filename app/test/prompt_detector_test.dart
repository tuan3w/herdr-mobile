import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/prompt_detector.dart';

/// `(label, keys, needsConfirm)` per reply, for compact expectations.
typedef _R = (String, List<String>, bool);

String _fmt(_R r) => '${r.$1} | ${r.$2.join(',')} | ${r.$3 ? 'confirm' : 'plain'}';

List<String> _replies(PromptInfo p) => [
      for (final r in p.replies) _fmt((r.label, r.keys, r.needsConfirm)),
    ];

PromptInfo? _detect(String screen) => detectPrompt(screen.split('\n'));

class _Case {
  const _Case(this.name, this.screen, this.replies, {this.question});
  final String name;
  final String screen;
  final List<_R> replies;
  final String? question;
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
      ('1. Yes', ['1', 'enter'], false),
      ("2. Yes, don't ask again", ['2', 'enter'], false),
      ('3. No', ['3', 'enter'], false),
    ],
    question: 'Do you want to proceed?',
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
      ("2. Yes, don't ask again", ['2', 'enter'], false),
      ('3. No', ['3', 'enter'], false),
    ],
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
      ('2. Yes, allow all edits during this…', ['2', 'enter'], false),
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
      ('1. Yes, proceed', ['1', 'enter'], false),
      ("2. Yes, don't ask again", ['2', 'enter'], false),
      ('3. No', ['3', 'enter'], false),
    ],
    question: 'Would you like to run the following command?\n\$ git push',
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
      ("2. Yes, don't ask again", ['2', 'enter'], false),
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
      ('Allow always', ['down', 'enter'], false),
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
      ('Allow always', _enter, false),
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

    test('only the last 12 rows are looked at', () {
      final noise = List.generate(30, (i) => 'line $i').join('\n');
      final p = _detect('$noise\nDo you want to proceed?\n❯ 1. Yes\n  2. No');
      expect(p!.replies.map((r) => r.label), ['1. Yes', '2. No']);
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
