/// Texts for rendering tests and the PNG review: the worst cases for the
/// Markdown renderer, the corpus messages and the answers real agents wrote
/// (the `markdown` scenario traces).
library;

import 'all_texts.dart';
import 'corpus.dart';
import 'traces.dart';

/// Real agent answers: the `agent_message_chunk` text of every `markdown`
/// trace (omp, claude, codex).
List<({String name, String text})> realAnswers() => [
  for (final m in loadTraceMessages(tracesDir))
    if (m.name.contains('/markdown.jsonl')) (name: m.name, text: m.chunks.join()),
];

/// The hand-written corpus messages (`corpus/messages/*.md`).
List<({String name, String text})> corpusMessages() => loadMessages('$corpusDir/messages');

/// A message of at least [chars] characters made by repeating the corpus
/// answers, as one document.
String bigMessage(int chars) {
  final pieces = [
    for (final c in loadCorpus(corpusDir))
      if (c.file == 'agent.case') c.input,
    for (final m in corpusMessages()) m.text,
  ];
  final b = StringBuffer();
  var i = 0;
  while (b.length < chars) {
    b
      ..write(pieces[i++ % pieces.length])
      ..write('\n\n');
  }
  return b.toString();
}

/// The worst-case set (`herdr-screen-check`): 1 000-line code, 40-column table, 300-item list, five
/// levels of nesting, Vietnamese, RTL, bidi overrides and control characters.
Map<String, String> worstCases() => {
  'code1000': _code1000(),
  'table40': _table(40, 24),
  'list300': [for (var i = 1; i <= 300; i++) '- item $i with **bold**, `code` and a [link](https://example.com/$i)'].join('\n'),
  'nesting5': _nesting(),
  'vietnamese': _vietnamese(),
  'rtl': _rtl(),
  'bidi': _bidi(),
};

String _code1000() {
  final b = StringBuffer('Here is the whole file:\n\n```dart\n');
  for (var i = 1; i <= 1000; i++) {
    b.writeln(switch (i % 5) {
      0 => '  // line $i: a comment that goes on and on and on so the line is longer than a phone is wide',
      1 => 'class Thing$i extends Base<String> {',
      2 => "  final String name = 'thing $i';",
      3 => '  int get count => $i * 2 + 1;',
      _ => '}',
    });
  }
  b.write('```\n\nThat is all of it.');
  return b.toString();
}

String _table(int columns, int rows) {
  final head = [for (var c = 1; c <= columns; c++) 'Col $c'];
  final b = StringBuffer('| ${head.join(' | ')} |\n');
  b.writeln('| ${[for (var c = 0; c < columns; c++) c == 0 ? ':--' : (c.isEven ? '--:' : ':-:')].join(' | ')} |');
  for (var r = 1; r <= rows; r++) {
    b.writeln('| ${[for (var c = 1; c <= columns; c++) c == 1 ? 'row $r, a longer first cell that wraps' : '${r * c}.${c % 10}'].join(' | ')} |');
  }
  return 'A wide table follows.\n\n$b\nAfter the table.';
}

String _nesting() => '''
Five levels of structure:

1. Level one, ordered
   - Level two, bullet with `code` and **bold**
     1. Level three, ordered again
        - Level four, bullet
          > Level five: a quote inside the list with a [link](https://example.com/deep)
          >
          > ```sh
          > echo "code inside a quote inside five levels"
          > ```
        - Level four, second
     2. Level three, second
   - Level two, second
2. Level one, second

   A continuation paragraph under item two.

   ```text
   code in a list item
   ```

- [x] a finished task
- [ ] an open task
  - [ ] a nested open task

> [!WARNING]
> An alert with a list:
> - first
> - second
''';

String _vietnamese() => '''
## Sửa lỗi phân tích cú pháp ngày tháng

Tôi đã tìm thấy nguyên nhân: hàm `parseLocale` chuyển chuỗi sang chữ thường **trước khi** chuẩn hóa, nên "Hà Nội" thành "ha noi" và mất dấu. Các tệp liên quan: `lib/locale/parse.dart:42` và `test/locale_test.dart`.

- Đường dẫn dài: `lib/ui/features/trình_xem/tệp_nguồn_rất_dài_với_nhiều_ký_tự_tiếng_Việt.dart:128`
- Ghi chú: Nguyễn Thị Thanh Hương đã xác nhận rằng ổn định rồi.

| Thành phố | Dân số | Ghi chú |
| --- | ---: | --- |
| Hà Nội | 8.435.000 | thủ đô |
| Thành phố Hồ Chí Minh | 9.320.000 | đông dân nhất |
''';

String _rtl() => '''
## تقرير الأخطاء

وجدت المشكلة في الملف `lib/main.dart:10`: الدالة تعيد قيمة خاطئة عندما يكون النص بالعربية، مثل «مرحبا بالعالم» و **نص غامق** و [رابط](https://example.com/ar).

- بند أول بالعربية
- בדיקה בעברית: זהו משפט קצר
- item mixing English then عربى

> اقتباس باللغة العربية

| الاسم | القيمة |
| --- | --- |
| مفتاح | ١٢٣ |
''';

String _bidi() => '''
A paragraph with an override \u202Egnp.exe\u202C inside, and a zero width\u200B space.

A link whose target hides something: [click here](https://example.com/\u202Egpj.fdp) and a label with an RTL override \u202Etxet.

```sh
echo "safe"\u202E # reversed from here
rm -rf \u0007\u001B[31m/tmp/x
```

Inline `code\u202Ehidden` too.
''';
