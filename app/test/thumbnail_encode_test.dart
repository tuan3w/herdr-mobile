import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/image_decode.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';

import 'support/files_support.dart' show makePng;
import 'support/photo_support.dart';

// The thumbnail the disk cache keeps is made by the REAL engine and encoder (the
// folder tests inject stand-ins): a thumbnail that cannot be made or read back
// is never kept, and the folder then costs a read at every visit.

bool _isPng(Uint8List b) => b.length > 4 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
bool _isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

void main() {
  testWidgets('a decoded thumbnail is encoded as PNG or JPEG, and reads back at its size', (tester) async {
    await tester.runAsync(() async {
      final image = await paintBitmap(240, 180);
      addTearDown(image.dispose);

      final png = await encodeThumbnail(image, png: true);
      final jpeg = await encodeThumbnail(image, png: false);
      expect(_isPng(png!), isTrue, reason: 'a source that may be see-through keeps its alpha');
      expect(_isJpeg(jpeg!), isTrue);

      for (final bytes in [png, jpeg]) {
        final back = await decodeImageFit(bytes, maxWidth: 240, maxHeight: 240);
        expect((back.width, back.height), (240, 180));
        // The corner mark is where it was (not flipped, not channel-swapped):
        // the top-left square is white, the bottom-right is not.
        final data = (await back.image.toByteData())!;
        int px(int x, int y) => data.getUint32((y * 240 + x) * 4);
        expect(px(5, 5) & 0xFFFFFF00, greaterThan(0xE0E0E000), reason: 'white corner mark, top left');
        expect(px(230, 170) & 0xFFFFFF00, lessThan(0xE0E0E000));
        back.dispose();
      }
    });
  });

  testWidgets('makeThumbnail shrinks a big picture to 240 px and keeps an opaque one a JPEG', (tester) async {
    final original = await makePng(tester, 1200, 800);
    final thumb = await tester.runAsync(() => makeThumbnail(original));
    expect(thumb, isNotNull);
    final back = await tester.runAsync(() => decodeImageFit(thumb!, maxWidth: 1000, maxHeight: 1000));
    expect(back!.width, 240);
    expect(back.height, 160);
    expect(thumb!.length, lessThan(original.length), reason: 'a thumbnail is smaller than what it came from');
    back.dispose();
  });

  testWidgets('bytes that are not a picture make no thumbnail: it throws, so nothing bad is kept', (tester) async {
    final outcome = await tester.runAsync(() async {
      try {
        await makeThumbnail(Uint8List.fromList([1, 2, 3, 4]));
        return 'made one';
      } on Object {
        return 'threw';
      }
    });
    expect(outcome, 'threw');
  });
}
