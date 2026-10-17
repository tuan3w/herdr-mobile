import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/log_picture.dart';

void main() {
  group('parseKeeperMarker', () {
    test('reads the start, the hash and the size the note says', () {
      final ref = parseKeeperMarker('[107536 bytes of data not sent; ref=4096.0123456789abcdef]')!;
      expect(ref.start, 4096);
      expect(ref.hash, '0123456789abcdef');
      expect(ref.bytes, 80652);
      expect(ref.key, 'l:0123456789abcdef');
    });

    test('also after the data: of a data URI', () {
      final ref = parseKeeperMarker('data:image/png;base64,[400 bytes of data not sent; ref=0.0123456789abcdef]')!;
      expect(ref.start, 0);
    });

    test('anything else is no reference: an old note, text around it, a short hash, upper case', () {
      for (final s in [
        '[400 bytes of data not sent]',
        '<trimmed>',
        '',
        'see [400 bytes of data not sent; ref=0.0123456789abcdef]',
        '[400 bytes of data not sent; ref=0.0123456789abcde]',
        '[400 bytes of data not sent; ref=0.0123456789ABCDEF]',
        '[400 bytes of data not sent; ref=x.0123456789abcdef]',
      ]) {
        expect(parseKeeperMarker(s), isNull, reason: s);
      }
    });
  });

  group('parseOmpBlob', () {
    test('64 lowercase hex digits after blob:sha256:', () {
      final sha = 'ab12' * 16;
      expect(parseOmpBlob('blob:sha256:$sha')!.sha256, sha);
      expect(parseOmpBlob('blob:sha256:$sha')!.key, 'o:$sha');
    });

    test('anything else is not one', () {
      for (final s in ['blob:sha256:ff', 'blob:sha256:${'AB' * 32}', 'blob:sha256:${'a' * 65}', 'data:image/png;base64,AAAA', '']) {
        expect(parseOmpBlob(s), isNull, reason: s);
      }
    });
  });
}
