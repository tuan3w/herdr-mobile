import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/files/file_format.dart';
import 'package:herdr_mobile/ui/features/files/file_kind.dart';
import 'package:herdr_mobile/ui/features/files/text_document.dart';

Uint8List _b(List<int> bytes) => Uint8List.fromList(bytes);
Uint8List _s(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  group('file kind', () {
    test('by name', () {
      expect(typeForName('main.dart').kind, FileKind.text);
      expect(typeForName('Makefile').kind, FileKind.text);
      expect(typeForName('README.MD').kind, FileKind.markdown);
      expect(typeForName('package.json').kind, FileKind.json);
      expect(typeForName('Photo.JPEG').kind, FileKind.image);
      expect(typeForName('logo.svg').kind, FileKind.svg);
      expect(typeForName('paper.pdf').kind, FileKind.pdf);
      expect(typeForName('app.apk').kind, FileKind.binary);
      expect(typeForName('.gitignore').kind, FileKind.text, reason: 'a dotfile has no extension');
      expect(typeForName('archive.').kind, FileKind.text);
    });

    test('magic bytes beat the name', () {
      final png = _b([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]);
      expect(detectType('mystery', png).kind, FileKind.image);
      expect(detectType('mystery.txt', png).label, 'PNG image');
      expect(detectType('x.dat', _b([0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10])).label, 'JPEG image');
      expect(detectType('x', _s('GIF89a....')).kind, FileKind.image);
      expect(detectType('x', _b([...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits])).label, 'WebP image');
      expect(detectType('x', _s('%PDF-1.7\n')).kind, FileKind.pdf);
      expect(detectType('x', _b([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0])).label, 'Executable (ELF)');
      expect(detectType('x', _b([0x50, 0x4B, 3, 4, 0, 0])).label, 'ZIP archive');
    });

    test('"BM" at the start of a text file is not a bitmap', () {
      expect(detectType('notes.txt', _s('BM is a prefix of many words, nothing more')).kind, FileKind.text);
      final bmp = _b([0x42, 0x4D, 0x36, 0, 0, 0, 0, 0, 0, 0, 0x36, 0, 0, 0]);
      expect(detectType('x.bmp', bmp).kind, FileKind.image);
    });

    test('a NUL byte makes text binary; the name cannot promise text over it', () {
      expect(detectType('data.txt', _b([65, 66, 0, 67])).kind, FileKind.binary);
      expect(detectType('data.json', _b([123, 0, 125])).label, 'Binary data');
      expect(detectType('blob.bin', _b([1, 2, 0, 3])).label, 'BIN file');
    });

    test('text under an image, pdf or binary name is text (an HTML error saved as .png)', () {
      expect(detectType('broken.png', _s('<html>Not Found</html>')).kind, FileKind.text);
      expect(detectType('x.pdf', _s('plain words')).kind, FileKind.text);
      expect(detectType('x.bin', _s('plain words')).kind, FileKind.text);
    });

    test('names still choose among kinds of text', () {
      expect(detectType('a.md', _s('# hi')).kind, FileKind.markdown);
      expect(detectType('a.json', _s('{}')).kind, FileKind.json);
      expect(detectType('a.svg', _s('<svg/>')).kind, FileKind.svg);
    });

    test('an empty file is text, whatever it is called', () {
      expect(detectType('empty.png', Uint8List(0)).kind, FileKind.text);
      expect(detectType('empty.zip', Uint8List(0)).label, 'Empty file');
    });

    test('invalid UTF-8 in volume is binary; a few bad bytes in text are not', () {
      final latin1 = _b(List.generate(200, (i) => 0xE9 + (i % 6)));
      expect(detectType('x', latin1).kind, FileKind.binary);
      expect(detectType('x', _b([...utf8.encode('hello world, '), 0xE9, ...utf8.encode(' café')])).kind, FileKind.text);
    });

    test('Vietnamese and CJK are text', () {
      expect(detectType('x', _s('Đường dẫn: 日本語のメモ ✓')).kind, FileKind.text);
    });

    test('a read that stops mid-character is not mistaken for damaged text', () {
      final bytes = _s('${'é' * 100}€');
      final cut = Uint8List.sublistView(bytes, 0, bytes.length - 1); // half of €
      expect(looksBinary(cut), isFalse);
      expect(utf8SafeLength(cut), cut.length - 2, reason: 'the 2 bytes of the unfinished €');
      expect(utf8SafeLength(bytes), bytes.length);
      expect(utf8SafeLength(_b([0x61, 0xF0, 0x9F])), 1, reason: 'unfinished 4-byte sequence');
      expect(utf8SafeLength(_b([0x61, 0x80, 0x80, 0x80])), 4, reason: 'stray continuation bytes are just invalid');
    });
  });

  group('TextDocument', () {
    test('splits lines, drops \\r, and has no phantom last line', () {
      final d = TextDocument()..append(_s('one\r\ntwo\nthree\n'), last: true);
      expect(d.lines, ['one', 'two', 'three']);
      expect(d.lineCount, 3);
    });

    test('keeps a final line without newline', () {
      final d = TextDocument()..append(_s('a\nb'), last: true);
      expect(d.lines, ['a', 'b']);
    });

    test('pieces may split a line, a multi-byte character and a CRLF anywhere', () {
      const text = 'héllo wörld\r\nĐường dẫn\r\n日本語\nend';
      final bytes = _s(text);
      for (var cut1 = 0; cut1 < bytes.length; cut1 += 3) {
        for (var cut2 = cut1; cut2 < bytes.length; cut2 += 5) {
          final d = TextDocument()
            ..append(Uint8List.sublistView(bytes, 0, cut1))
            ..append(Uint8List.sublistView(bytes, cut1, cut2))
            ..append(Uint8List.sublistView(bytes, cut2), last: true);
          expect(d.lines, ['héllo wörld', 'Đường dẫn', '日本語', 'end'], reason: 'cuts $cut1/$cut2');
          expect(d.bytes, bytes.length);
        }
      }
    });

    test('invalid UTF-8 becomes U+FFFD instead of throwing; a dangling lead byte at the end too', () {
      final d = TextDocument()..append(_b([0x61, 0xFF, 0x62, 0xE2, 0x82]), last: true);
      expect(d.lines.single, 'a\uFFFDb\uFFFD');
    });

    test('a trailing partial character waits for the next piece', () {
      final euro = _s('€'); // 3 bytes
      final d = TextDocument()..append(_b([...'ab'.codeUnits, euro[0], euro[1]]));
      expect(d.lines.single, 'ab');
      d.append(_b([euro[2], ...'cd'.codeUnits]), last: true);
      expect(d.lines.single, 'ab€cd');
    });

    test('a BOM is not text', () {
      final d = TextDocument()..append(_b([0xEF, 0xBB, 0xBF, ...'hi'.codeUnits]), last: true);
      expect(d.lines.single, 'hi');
    });

    test('maxColumns counts tabs as four and wide glyphs as two', () {
      final d = TextDocument()..append(_s('ab\n\tx\n日本語\nplain text here\n'), last: true);
      expect(d.maxColumns, 15);
      expect(TextDocument.widthOf('\t\t'), 8);
      expect(TextDocument.widthOf('日本'), 4);
      expect(TextDocument.expandTabs('a\tb'), 'a    b');
    });

    test('maxColumns updates when a later piece extends the open line', () {
      final d = TextDocument()
        ..append(_s('short\nlong lin'))
        ..append(_s('e that goes on'), last: true);
      expect(d.maxColumns, 'long line that goes on'.length);
    });

    test('empty documents', () {
      final d = TextDocument()..append(Uint8List(0), last: true);
      expect(d.isEmpty, isTrue);
      expect(d.text, '');
    });

    test('text round-trips with tabs intact (copying gives the original)', () {
      final d = TextDocument()..append(_s('a\tb\n\tc\n'), last: true);
      expect(d.text, 'a\tb\n\tc');
    });
  });

  group('formatting', () {
    test('bytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(1024), '1 KB');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(12 * 1024 * 1024), '12 MB');
      expect(formatBytes(5 * 1024 * 1024 * 1024 * 1024 * 1024), '5120 TB');
      expect(formatBytes(null), 'Unknown size');
    });

    test('relative time', () {
      final now = DateTime(2026, 5, 20, 12, 0);
      expect(formatModified(now.subtract(const Duration(seconds: 20)), now: now), 'Just now');
      expect(formatModified(now.add(const Duration(hours: 1)), now: now), 'Just now', reason: 'clock skew');
      expect(formatModified(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(formatModified(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(formatModified(DateTime(2026, 5, 19, 23, 30), now: now), 'Yesterday');
      expect(formatModified(DateTime(2026, 5, 16), now: now), '4 d ago');
      expect(formatModified(DateTime(2026, 4, 2), now: now), 'Apr 2');
      expect(formatModified(DateTime(2025, 12, 31), now: now), 'Dec 31, 2025');
      expect(formatModified(null), '');
    });

    test('permissions and digit grouping', () {
      expect(formatPermissions(0x81A4), 'rw-r--r--');
      expect(formatPermissions(0x41ED), 'rwxr-xr-x');
      expect(formatPermissions(null), '');
      expect(groupDigits(1234567), '1,234,567');
      expect(groupDigits(12), '12');
      expect(groupDigits(5000), '5,000');
    });
  });
}
