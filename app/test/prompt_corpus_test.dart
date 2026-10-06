import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/prompt_detector.dart';

/// Real screens captured from agents (`tool/capture-prompt.sh`), one file per
/// screen under `test/fixtures/prompts/<agent>/`, each with the answer the
/// detector is expected to give in `<name>.expected` beside it.
///
/// `UPDATE_EXPECTED=1 flutter test test/prompt_corpus_test.dart` writes the
/// expected files from what the detector says now. Read each one against its
/// screen before committing: a wrong answer written down is still wrong.
const _dir = 'test/fixtures/prompts';

/// Rows the app asks herdr for (`PanePreviews.readLines`).
const _readRows = 24;

final _update = Platform.environment['UPDATE_EXPECTED'] == '1';

final _header = RegExp(r'^# ([a-z_]+): ?(.*)$');

/// A fixture split into its `# key: value` header and the screen under it.
({Map<String, String> header, String screen}) splitFixture(String text) {
  final header = <String, String>{};
  final lines = text.split('\n');
  var i = 0;
  for (; i < lines.length; i++) {
    final m = _header.firstMatch(lines[i]);
    if (m == null) break;
    header[m[1]!] = m[2]!;
  }
  return (header: header, screen: lines.skip(i).join('\n'));
}

/// What the detector made of [screen], as text that diffs well.
String renderPrompt(PromptInfo? prompt) {
  if (prompt == null) return 'no prompt\n';
  final out = StringBuffer('question:\n');
  for (final line in prompt.question.split('\n')) {
    out.writeln('  $line');
  }
  if (prompt.subject.isNotEmpty) {
    out.writeln('subject:');
    for (final line in prompt.subject.split('\n')) {
      out.writeln('  $line');
    }
  }
  out.writeln('replies:');
  for (final r in prompt.replies) {
    final confirm = r.needsConfirm ? r.risk ?? 'yes' : 'no';
    out.writeln('  ${r.label} | keys: ${r.keys.join(' ')} | confirm: $confirm');
  }
  return out.toString();
}

List<File> _files(String suffix) {
  final dir = Directory(_dir);
  if (!dir.existsSync()) return const [];
  return [
    for (final e in dir.listSync(recursive: true))
      if (e is File && e.path.endsWith(suffix)) e,
  ]..sort((a, b) => a.path.compareTo(b.path));
}

String _stem(File f) => f.path.substring(0, f.path.length - f.path.split('.').last.length - 1);

void main() {
  final fixtures = _files('.txt');

  test('the corpus is not empty', () {
    expect(fixtures, isNotEmpty, reason: 'no fixtures under $_dir');
  });

  test('every .expected belongs to a fixture', () {
    final stems = {for (final f in fixtures) _stem(f)};
    final orphans = [
      for (final e in _files('.expected'))
        if (!stems.contains(_stem(e))) e.path,
    ];
    expect(orphans, isEmpty, reason: 'delete these or restore their .txt');
  });

  group('fixtures', () {
    for (final file in fixtures) {
      final id = file.path.substring(_dir.length + 1);
      test(id, () {
        final (:header, :screen) = splitFixture(file.readAsStringSync());
        final agent = file.parent.path.split(Platform.pathSeparator).last;
        expect(header['agent'], agent, reason: 'filed under the wrong agent');

        final actual = renderPrompt(detectPrompt(previewRows(screen, keep: _readRows)));
        final expectedFile = File('${_stem(file)}.expected');
        if (_update) {
          expectedFile.writeAsStringSync(actual);
          return;
        }
        if (!expectedFile.existsSync()) {
          fail(
            '${expectedFile.path} is missing. Create it with\n'
            '  cd app && UPDATE_EXPECTED=1 flutter test test/prompt_corpus_test.dart\n'
            'and read it against the screen before committing:\n$actual',
          );
        }
        expect(actual, expectedFile.readAsStringSync(), reason: id);
      });
    }
  });

  group('the helpers', () {
    test('a header ends at the first row that is not one', () {
      final s = splitFixture('# agent: claude\n# herdr: 0.9.3\n# a heading in the screen\n body\n');

      expect(s.header, {'agent': 'claude', 'herdr': '0.9.3'});
      expect(s.screen, '# a heading in the screen\n body\n');
    });

    test('a screen without a header is all screen', () {
      final s = splitFixture('one\ntwo');

      expect(s.header, isEmpty);
      expect(s.screen, 'one\ntwo');
    });

    test('a prompt renders its question, subject and one line per reply', () {
      final text = renderPrompt(const PromptInfo(
        question: 'Run it?\nTwo lines',
        subject: 'git push\nPush it',
        replies: [
          QuickReply(label: '1. Yes', keys: ['1', 'enter'], needsConfirm: true, risk: 'pushes to a remote'),
          QuickReply(label: '2. No', keys: ['esc'], needsConfirm: true),
          QuickReply(label: '3. Maybe', keys: ['3']),
        ],
      ));

      expect(
        text,
        'question:\n'
        '  Run it?\n'
        '  Two lines\n'
        'subject:\n'
        '  git push\n'
        '  Push it\n'
        'replies:\n'
        '  1. Yes | keys: 1 enter | confirm: pushes to a remote\n'
        '  2. No | keys: esc | confirm: yes\n'
        '  3. Maybe | keys: 3 | confirm: no\n',
      );
      expect(
        renderPrompt(const PromptInfo(question: 'q', replies: [QuickReply(label: 'a', keys: ['1'])])),
        'question:\n  q\nreplies:\n  a | keys: 1 | confirm: no\n',
        reason: 'no subject, no subject section',
      );
      expect(renderPrompt(null), 'no prompt\n');
    });
  });
}
