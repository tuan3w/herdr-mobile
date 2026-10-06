import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_quick_phrases_store.dart';

Future<QuickPhrases> _loaded([MemoryQuickPhrasesStore? store]) async {
  final phrases = QuickPhrases(store ?? MemoryQuickPhrasesStore());
  await phrases.load();
  return phrases;
}

void main() {
  group('QuickPhrases', () {
    test('starts with the defaults when nothing was saved', () async {
      expect((await _loaded()).phrases, QuickPhrases.defaults);
    });

    test('an unreadable store gives the defaults, never throws', () async {
      final store = MemoryQuickPhrasesStore()..readFailure = StateError('disk gone');
      expect((await _loaded(store)).phrases, QuickPhrases.defaults);
    });

    test('a saved empty list stays empty: deleting everything is a choice', () async {
      expect((await _loaded(MemoryQuickPhrasesStore([]))).phrases, isEmpty);
    });

    test('add, edit and delete are saved and survive a reload', () async {
      final store = MemoryQuickPhrasesStore();
      final phrases = await _loaded(store);

      expect(await phrases.add('  squash the commits '), isTrue);
      expect(await phrases.replace('continue', 'keep going'), isTrue);
      await phrases.remove('run the tests');

      final expected = ['keep going', 'yes, go ahead', 'explain what you changed', 'squash the commits'];
      expect(phrases.phrases, expected);
      expect(store.saved, expected);
      expect((await _loaded(store)).phrases, expected);
    });

    test('an edit keeps its place in the row', () async {
      final phrases = await _loaded();
      await phrases.replace('yes, go ahead', 'ok, do it');
      expect(phrases.phrases[1], 'ok, do it');
      expect(phrases.phrases.length, QuickPhrases.defaults.length);
    });

    test('text is folded to one trimmed line and cut to 80 characters', () {
      expect(QuickPhrases.clean('  run \n the\ttests  '), 'run the tests');
      final long = 'Tiếng Việt có dấu ' * 10;
      final cut = QuickPhrases.clean(long);
      expect(cut.runes.length, lessThanOrEqualTo(QuickPhrases.maxLength));
      expect(cut, long.trim().substring(0, cut.length));
      // Two code units per character must not be split in half.
      final emoji = QuickPhrases.clean('🚀' * 100);
      expect(emoji.runes.length, QuickPhrases.maxLength);
    });

    test('empties and repeats are refused, with the reason', () async {
      final phrases = await _loaded();
      expect(phrases.problem('   \n'), PhraseProblem.empty);
      expect(phrases.problem(' continue '), PhraseProblem.duplicate);
      expect(await phrases.add('continue'), isFalse);
      expect(await phrases.replace('run the tests', 'continue'), isFalse);
      expect(phrases.phrases, QuickPhrases.defaults);
      // Saving an edit that changes nothing is fine.
      expect(phrases.problem('continue', replacing: 'continue'), isNull);
    });

    test('the list never holds more than 12', () async {
      final phrases = await _loaded(MemoryQuickPhrasesStore([]));
      for (var i = 0; i < QuickPhrases.maxCount; i++) {
        expect(await phrases.add('phrase $i'), isTrue);
      }
      expect(phrases.problem('one too many'), PhraseProblem.full);
      expect(await phrases.add('one too many'), isFalse);
      expect(phrases.phrases, hasLength(QuickPhrases.maxCount));
      // A full list can still be edited.
      expect(phrases.problem('phrase 0 again', replacing: 'phrase 0'), isNull);
    });

    test('what was saved is cleaned on the way in', () async {
      final store = MemoryQuickPhrasesStore([
        ' a ',
        '',
        'a',
        'b\nc',
        for (var i = 0; i < 20; i++) 'p$i',
      ]);
      final phrases = (await _loaded(store)).phrases;
      expect(phrases.take(3), ['a', 'b c', 'p0']);
      expect(phrases, hasLength(QuickPhrases.maxCount));
    });

    test('a failing write still changes the list in memory', () async {
      final store = MemoryQuickPhrasesStore()..writeFailure = StateError('read-only');
      final phrases = await _loaded(store);
      await phrases.add('keep going');
      expect(phrases.phrases.last, 'keep going');
    });

    test('listeners hear about every change', () async {
      final phrases = await _loaded();
      var heard = 0;
      phrases.addListener(() => heard++);
      await phrases.add('one');
      await phrases.remove('one');
      await phrases.remove('not there');
      expect(heard, 2);
    });
  });

  group('PrefsQuickPhrasesStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips under quickPhrases.v1', () async {
      final store = PrefsQuickPhrasesStore();
      expect(await store.read(), isNull);
      await store.write(['continue', 'Tiếng Việt']);
      expect(await store.read(), ['continue', 'Tiếng Việt']);
      expect((await SharedPreferences.getInstance()).getString('quickPhrases.v1'), isNotNull);
    });

    test('garbage reads as never saved', () async {
      SharedPreferences.setMockInitialValues({'quickPhrases.v1': 'not json {'});
      expect(await PrefsQuickPhrasesStore().read(), isNull);
      SharedPreferences.setMockInitialValues({'quickPhrases.v1': '{"a": 1}'});
      expect(await PrefsQuickPhrasesStore().read(), isNull);
    });

    test('entries that are not text are dropped', () async {
      SharedPreferences.setMockInitialValues({'quickPhrases.v1': '["ok", 3, null, "fine"]'});
      expect(await PrefsQuickPhrasesStore().read(), ['ok', 'fine']);
    });
  });
}
