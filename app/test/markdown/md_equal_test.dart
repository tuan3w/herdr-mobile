import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';

import 'support/all_texts.dart';

void main() {
  test('every corpus text equals its own second parse, block for block', () {
    for (final t in allCorpusTexts()) {
      final a = parseMd(t.text).blocks;
      final b = parseMd(t.text).blocks;
      expect(a.length, b.length, reason: t.name);
      for (var i = 0; i < a.length; i++) {
        expect(mdBlocksEqual(a[i], b[i]), isTrue, reason: '${t.name} block $i');
      }
    }
  });

  test('a change anywhere in a block is a difference', () {
    bool same(String a, String b) => mdBlocksEqual(parseMd(a).blocks.single, parseMd(b).blocks.single);
    expect(same('plain text', 'plain text'), isTrue);
    expect(same('plain text', 'plain test'), isFalse);
    expect(same('**bold**', '*bold*'), isFalse);
    expect(same('[a](https://x.dev)', '[a](https://y.dev)'), isFalse);
    expect(same('# a', '## a'), isFalse);
    expect(same('- a\n- b', '- a\n- c'), isFalse);
    expect(same('- a', '- [ ] a'), isFalse);
    expect(same('- [ ] a', '- [x] a'), isFalse);
    expect(same('1. a', '3. a'), isFalse);
    expect(same('> a', '> > a'), isFalse);
    expect(same('> [!NOTE]\n> a', '> [!TIP]\n> a'), isFalse);
    expect(same('```dart\nx\n```', '```js\nx\n```'), isFalse);
    expect(same('| a |\n|---|\n| 1 |', '| a |\n|:--|\n| 1 |'), isFalse);
    expect(same('| a |\n|---|\n| 1 |', '| a |\n|---|\n| 2 |'), isFalse);
    expect(same('![x](a.png)', '![x](b.png)'), isFalse);
    expect(mdBlocksEqual(parseMd('text').blocks.single, parseMd('---').blocks.single), isFalse);
  });
}
