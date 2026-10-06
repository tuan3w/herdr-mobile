import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';

import 'support/all_texts.dart';
import 'support/corpus.dart';
import 'support/md_dump.dart';

/// Per-case structure expectations (`corpus/*.case`): the parser's output as
/// the canonical dump, and the healing cases of `remend` plus ours.
void main() {
  final cases = loadCorpus(corpusDir);

  test('the corpus is loaded', () {
    expect(cases.length, greaterThan(150));
    expect(cases.where((c) => c.isHeal).length, greaterThan(60));
  });

  group('parse', () {
    for (final c in cases.where((c) => !c.isHeal)) {
      test(c.toString(), () {
        final doc = parseMd(c.input, softBreaksAsNewlines: !c.softSpace);
        expect(dumpDocument(doc), c.expect);
      });
    }
  });

  group('heal', () {
    for (final c in cases.where((c) => c.isHeal)) {
      test(c.toString(), () {
        final healed = healTail(c.input);
        expect(healed, c.expect);
        final display = c.display;
        if (display != null) {
          expect(dumpDocument(parseMd(healed)), display);
        }
      });
    }

    test('healing is idempotent on every corpus healing case', () {
      for (final c in cases.where((c) => c.isHeal)) {
        expect(healTail(c.expect), c.expect, reason: c.toString());
      }
    });

    test('healing never throws and never grows a text by more than closers',
        () {
      // Every prefix of every corpus text: the contract of a display-only step.
      for (final t in allCorpusTexts().where((t) => t.text.length < 1500)) {
        for (var p = 1; p <= t.text.length; p++) {
          final prefix = t.text.substring(0, p);
          final healed = healTail(prefix);
          expect(healed.length, lessThanOrEqualTo(prefix.length + 12),
              reason: '${t.name} @$p');
          // Parsing the healed text must not throw either, and one pass is
          // complete: healing again adds nothing (it may only drop more of an
          // ambiguous partial closing fence).
          parseMd(healed);
          expect(healTail(healed).length, lessThanOrEqualTo(healed.length),
              reason: '${t.name} @$p: ${prefix.replaceAll('\n', '⏎')}');
        }
      }
    });

    test('a healed prefix never shows a marker the finished text does not', () {
      // The point of healing: no `**`, backtick, `~~`, `](` or `![` in
      // the visible text of a half-written message unless the finished
      // message shows it too.
      const marks = ['**', '`', '~~', '](', '![', '__'];
      var checked = 0;
      for (final t in allCorpusTexts().where((t) => t.text.length > 400)) {
        final finished = parseMd(t.text).plainText;
        for (var p = 1; p <= t.text.length; p++) {
          final shown = parseMd(healTail(t.text.substring(0, p))).plainText;
          for (final m in marks) {
            if (shown.contains(m) && !finished.contains(m)) {
              fail('${t.name} @$p shows "$m": ${shown.split('\n').lastWhere((l) => l.contains(m))}');
            }
          }
          checked++;
        }
      }
      expect(checked, greaterThan(5000));
    });
  });
}
