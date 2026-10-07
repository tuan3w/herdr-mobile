import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/sent_phrases.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_quick_phrases_store.dart';
import 'support/memory_sent_phrases_store.dart';

Future<SentPhrases> _loaded([MemorySentPhrasesStore? store]) async {
  final sent = SentPhrases(store ?? MemorySentPhrasesStore());
  await sent.load();
  return sent;
}

Future<void> _send(SentPhrases sent, String text, [int times = 1]) async {
  for (var i = 0; i < times; i++) {
    await sent.learn(text);
  }
}

void main() {
  group('SentPhrases', () {
    test('a message becomes a chip on its second send, not its first', () async {
      final sent = await _loaded();
      await _send(sent, 'run the tests');
      expect(sent.chips(), isEmpty, reason: 'once is where a secret or a one-off path lives');
      await _send(sent, 'run the tests');
      expect(sent.chips(), ['run the tests']);
    });

    test('the most sent comes first, then the latest', () async {
      final sent = await _loaded();
      await _send(sent, 'create pr', 2);
      await _send(sent, 'continue', 5);
      await _send(sent, 'commit', 2);
      expect(sent.chips(), ['continue', 'commit', 'create pr']);
    });

    test('case does not make two messages, and the latest spelling is shown', () async {
      final sent = await _loaded();
      await _send(sent, 'Continue');
      await _send(sent, 'continue');
      expect(sent.chips(), ['continue']);
    });

    test('at most 3 are offered, and not what the person already has as a phrase', () async {
      final sent = await _loaded();
      for (final m in ['a1', 'b2', 'c3', 'd4', 'continue']) {
        await _send(sent, m, 2);
      }
      expect(sent.chips(), hasLength(SentPhrases.maxChips));
      await _send(sent, 'continue', 5);
      expect(sent.chips(except: ['Continue']), isNot(contains('continue')));
    });

    test('text that may hold a secret or is not a phrase is never learned', () async {
      final sent = await _loaded();
      final refused = [
        'a\nb',
        'x' * (QuickPhrases.maxLength + 1),
        'use https://example.com/a for it',
        'token sk-abcdefghijklmnopqrstuvwxyz0123',
        '/compact',
        'k',
        '   ',
      ];
      for (final text in refused) {
        await _send(sent, text, 3);
      }
      expect(sent.tracked, 0);
      expect(sent.chips(), isEmpty);
    });

    test('turned off, it learns nothing and offers nothing; turned on, what it knew is back', () async {
      final sent = await _loaded();
      await _send(sent, 'continue', 2);
      await sent.setEnabled(false);
      await _send(sent, 'commit', 2);
      expect(sent.chips(), isEmpty);
      await sent.setEnabled(true);
      expect(sent.chips(), ['continue'], reason: 'nothing was learned while it was off');
    });

    test('forget empties it and is saved', () async {
      final store = MemorySentPhrasesStore();
      final sent = await _loaded(store);
      await _send(sent, 'continue', 3);
      await sent.forget();
      expect(sent.tracked, 0);
      expect(store.saved.entries, isEmpty);
      expect((await _loaded(store)).chips(), isEmpty);
    });

    test('what was learned survives a restart, including the setting', () async {
      final store = MemorySentPhrasesStore();
      final sent = await _loaded(store);
      await _send(sent, 'continue', 2);
      await sent.setEnabled(false);
      final again = await _loaded(store);
      expect(again.enabled, isFalse);
      await again.setEnabled(true);
      expect(again.chips(), ['continue']);
    });

    test('only the most useful 300 are kept: the often sent outlive the once sent', () async {
      final sent = await _loaded();
      await _send(sent, 'continue', 3);
      for (var i = 0; i < SentPhrases.maxTracked + 50; i++) {
        await _send(sent, 'one off message $i');
      }
      expect(sent.tracked, SentPhrases.maxTracked);
      expect(sent.chips(), ['continue']);
    });

    test('a failing write never throws and the chips still work', () async {
      final store = MemorySentPhrasesStore()..writeFailure = StateError('disk full');
      final sent = await _loaded(store);
      await _send(sent, 'continue', 2);
      expect(sent.chips(), ['continue']);
    });

    test('listeners hear about what changes the chips', () async {
      final sent = await _loaded();
      var heard = 0;
      sent.addListener(() => heard++);
      await _send(sent, 'continue', 2);
      await sent.setEnabled(false);
      await sent.forget();
      expect(heard, 4);
    });
  });

  group('quickChips', () {
    test('your own list stays first once you changed it', () {
      expect(
        quickChips(phrases: ['mine', 'other'], untouched: false, learned: ['learned']),
        ['mine', 'other', 'learned'],
      );
    });

    test('while the shipped list is untouched, what you really send goes first', () {
      expect(
        quickChips(phrases: QuickPhrases.defaults, untouched: true, learned: ['create pr']),
        ['create pr', ...QuickPhrases.defaults],
      );
    });

    test('a phrase that is also learned shows once, where the order puts it first', () {
      expect(
        quickChips(phrases: ['Continue', 'b'], untouched: true, learned: ['continue']),
        ['continue', 'b'],
      );
    });
  });

  group('QuickPhrases.untouched', () {
    test('is true until the person edits the list', () async {
      SharedPreferences.setMockInitialValues({});
      final phrases = QuickPhrases(MemoryQuickPhrasesStore());
      await phrases.load();
      expect(phrases.untouched, isTrue);
      await phrases.add('ship it');
      expect(phrases.untouched, isFalse);
    });

    test('a list saved earlier is the person\'s own', () async {
      final phrases = QuickPhrases(MemoryQuickPhrasesStore(['mine']));
      await phrases.load();
      expect(phrases.untouched, isFalse);
    });
  });

  group('PrefsSentPhrasesStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('round-trips what was learned and the switch', () async {
      final store = PrefsSentPhrasesStore();
      await store.write(const SentPhrasesSnapshot(enabled: false, entries: [SentPhrase('continue', 3, 7)]));
      final read = await store.read();
      expect(read.enabled, isFalse);
      expect(read.entries.single.text, 'continue');
      expect(read.entries.single.count, 3);
      expect(read.entries.single.last, 7);
    });

    test('garbage reads as nothing learned, learning on', () async {
      SharedPreferences.setMockInitialValues({'sentPhrases.v1': '{not json'});
      final read = await PrefsSentPhrasesStore().read();
      expect(read.entries, isEmpty);
      expect(read.enabled, isTrue);
    });
  });
}
