import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/words/error_words.dart';

void main() {
  group('describeError', () {
    test('a herdr error shows its message without the code', () {
      final words = describeError(const HerdrApiException('invalid_request', 'Folder is read-only.'));
      expect(words, 'Folder is read-only.');
    });

    test('a known code gets a sentence of its own, an empty message a fixed one', () {
      expect(describeError(const HerdrApiException('pane_not_found', 'pane p9 not found')), isNot(contains('p9')));
      expect(describeError(const HerdrApiException('error', '')), isNotEmpty);
    });

    test('a dropped connection names the machine and says what to do', () {
      final words = describeError(const HerdrTransportException('socket closed'), machine: 'studio');
      expect(words, contains('studio'));
      expect(words, contains('Retry'));
      expect(words, isNot(contains('socket')));
    });

    test('a fatal failure keeps its message, which says what to change', () {
      expect(
        describeError(const HerdrTransportException('The host key changed.', fatal: true)),
        'The host key changed.',
      );
    });

    test('a timeout names the machine', () {
      expect(describeError(TimeoutException('x'), machine: 'studio'), contains('studio'));
    });

    test('anything else is a fixed sentence, never the type or the text', () {
      final words = describeError(const FormatException('bad bytes at 4'));
      expect(words, isNot(contains('FormatException')));
      expect(words, isNot(contains('bad bytes')));
    });

    test('without a machine name it still reads', () {
      expect(describeError(const HerdrTransportException('x')), contains('the machine'));
    });
  });
}
