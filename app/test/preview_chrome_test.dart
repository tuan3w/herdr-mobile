// A card previews what the agent did, not the input box and status bar that
// every agent CLI keeps drawing under its output.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';

List<String> rows(String text) => previewRows(text, keep: 30);

void main() {
  group('withoutAgentChrome', () {
    test('drops the input box, its placeholder and the status bar', () {
      final shown = rows('''
● Read(lib/main.dart)
  ⎿  Read 120 lines
● I will add the setting now.
╭──────────────────────────────────────╮
│ > Try "fix lint errors"              │
╰──────────────────────────────────────╯
  ? for shortcuts                      0 tokens
''');
      expect(withoutAgentChrome(shown, blocked: false), [
        '● Read(lib/main.dart)',
        '  ⎿  Read 120 lines',
        '● I will add the setting now.',
      ]);
    });

    test('drops an oh-my-pi style status line and a bare prompt', () {
      final shown = rows('''
  └ • HFRLSearch-2 Complete assignment
  ⏲ Waiting for research agents
❯
 16m > Opus 5.5 > 📁 /home/dev/workspace
''');
      expect(withoutAgentChrome(shown, blocked: false), [
        '  └ • HFRLSearch-2 Complete assignment',
        '  ⏲ Waiting for research agents',
      ]);
    });

    test('drops the working spinner hint, keeps the line above it', () {
      final shown = rows('''
● Running tests
✻ Thinking… (12s · esc to interrupt)
>
''');
      expect(withoutAgentChrome(shown, blocked: false), ['● Running tests']);
    });

    test('only takes rows off the end', () {
      final shown = rows('''
> a question the person asked earlier
● an answer
  ? for shortcuts
''');
      expect(withoutAgentChrome(shown, blocked: false), [
        '> a question the person asked earlier',
        '● an answer',
      ]);
    });

    test('a blocked agent keeps a draft-looking menu row and numbered options', () {
      final shown = rows('''
Do you want to proceed?
❯ 1. Yes
  2. No
  Esc to cancel
''');
      expect(withoutAgentChrome(shown, blocked: true), [
        'Do you want to proceed?',
        '❯ 1. Yes',
        '  2. No',
      ]);
      // Not blocked: a numbered row is still not an input.
      expect(withoutAgentChrome(shown, blocked: false), [
        'Do you want to proceed?',
        '❯ 1. Yes',
        '  2. No',
      ]);
    });

    test('a blocked agent keeps a pointer row that is not numbered', () {
      final shown = rows('''
Allow this tool?
❯ Allow once
  Deny
''');
      expect(withoutAgentChrome(shown, blocked: true), shown);
    });

    test('a pane that is all chrome keeps what it has', () {
      final shown = rows('''
> 
  ? for shortcuts
''');
      expect(withoutAgentChrome(shown, blocked: false), shown);
    });

    test('an ordinary shell stays as it is', () {
      final shown = rows('''
total 8
-rw-r--r-- 1 me me 120 notes.txt
''');
      expect(withoutAgentChrome(shown, blocked: false), shown);
    });

    test('never takes more than a bounded number of rows', () {
      final shown = [
        'real output',
        for (var i = 0; i < 12; i++) '  ? for shortcuts $i',
      ];
      expect(withoutAgentChrome(shown, blocked: false).length, 5);
    });
  });
}
