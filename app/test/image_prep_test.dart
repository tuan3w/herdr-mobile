// Pictures to attach: decoded by the engine, downscaled, re-encoded as JPEG of
// about 1 MB with no metadata. The inputs are generated here.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:image/image.dart' as img;

/// A [w]x[h] picture of noise (the worst case for a JPEG: nothing to
/// compress), from a fixed seed.
img.Image _noise(int w, int h, {int numChannels = 3, int alpha = 255}) {
  final bytes = Uint8List(w * h * numChannels);
  var s = 0x2545F491;
  for (var i = 0; i < bytes.length; i++) {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = (s >> 16) & 0xff;
  }
  if (numChannels == 4) {
    for (var i = 3; i < bytes.length; i += 4) {
      bytes[i] = alpha;
    }
  }
  return img.Image.fromBytes(width: w, height: h, bytes: bytes.buffer, numChannels: numChannels);
}

bool _isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xff && b[1] == 0xd8 && b[b.length - 2] == 0xff && b[b.length - 1] == 0xd9;

bool _contains(Uint8List haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

void main() {
  group('prepareImage', () {
    test('a big photo ends as a JPEG of at most 1568 px on its long side and about 1 MB', () async {
      final photo = img.encodeJpg(_noise(3000, 2000), quality: 95);
      expect(photo.lengthInBytes, greaterThan(maxImageBytes), reason: 'the input is bigger than what we send');

      final out = await prepareImage(photo);

      expect(out.mimeType, 'image/jpeg');
      expect(_isJpeg(out.bytes), isTrue);
      expect(out.bytes.lengthInBytes, lessThanOrEqualTo(maxImageBytes));
      expect(out.width, 1568);
      expect(out.height, 1045, reason: '2000 x 1568/3000, aspect kept');
      final decoded = img.decodeJpg(out.bytes)!;
      expect(decoded.width, out.width);
      expect(decoded.height, out.height);
    });

    test('a portrait photo is limited on its height', () async {
      final out = await prepareImage(img.encodePng(_noise(900, 2400)));
      expect(out.height, 1568);
      expect(out.width, 588, reason: '900 x 1568/2400');
      expect(out.bytes.lengthInBytes, lessThanOrEqualTo(maxImageBytes));
    });

    test('a small picture keeps its size', () async {
      final out = await prepareImage(img.encodePng(_noise(400, 300)));
      expect(out.width, 400);
      expect(out.height, 300);
      expect(_isJpeg(out.bytes), isTrue);
    });

    test('quality, then size, step down until it fits the budget', () async {
      final noisy = img.encodePng(_noise(1500, 1500));
      final out = await prepareImage(noisy, maxBytes: 150 * 1024);
      expect(out.bytes.lengthInBytes, lessThanOrEqualTo(150 * 1024));
      expect(out.width, lessThanOrEqualTo(1500));
      expect(out.width, out.height, reason: 'still square');
      expect(_isJpeg(out.bytes), isTrue);
    });

    test('transparency is flattened onto white', () async {
      // Fully transparent red: invisible on the page, so white in a JPEG.
      final bytes = Uint8List(32 * 32 * 4);
      for (var i = 0; i < bytes.length; i += 4) {
        bytes[i] = 255;
      }
      final png = img.encodePng(img.Image.fromBytes(width: 32, height: 32, bytes: bytes.buffer, numChannels: 4));

      final out = await prepareImage(png);

      final p = img.decodeJpg(out.bytes)!.getPixel(16, 16);
      expect(p.r, greaterThan(240));
      expect(p.g, greaterThan(240));
      expect(p.b, greaterThan(240));
    });

    test('metadata does not survive: no EXIF block (and so no GPS position)', () async {
      final source = _noise(300, 200);
      source.exif.imageIfd.make = 'SecretPhone';
      source.exif.imageIfd.software = 'where-I-live';
      final jpeg = img.encodeJpg(source, quality: 90);
      expect(_contains(jpeg, ascii.encode('Exif')), isTrue, reason: 'the input does carry EXIF');
      expect(_contains(jpeg, ascii.encode('SecretPhone')), isTrue);

      final out = await prepareImage(jpeg);

      expect(_contains(out.bytes, ascii.encode('Exif')), isFalse);
      expect(_contains(out.bytes, ascii.encode('SecretPhone')), isFalse);
      expect(_contains(out.bytes, ascii.encode('where-I-live')), isFalse);
    });

    test('a photo taken sideways (EXIF orientation 6) comes out upright, since the EXIF is dropped', () async {
      // Observed with the desktop engine; the phone's engine is the same
      // codec family but this is UNVERIFIED on a device.
      final source = _noise(300, 200);
      source.exif.imageIfd.orientation = 6;

      final out = await prepareImage(img.encodeJpg(source, quality: 90));

      expect(out.width, 200);
      expect(out.height, 300);
    });

    test('the block carries the bytes as base64 with the JPEG mime type', () async {
      final out = await prepareImage(img.encodePng(_noise(64, 64)));
      final block = out.toBlock();
      expect(block.mimeType, 'image/jpeg');
      expect(base64Decode(block.data), out.bytes);
      expect(block.toJson()['type'], 'image');
    });

    test('input over 25 MB is refused before anything is decoded, with a plain message', () async {
      await expectLater(
        prepareImage(Uint8List(maxImageInputBytes + 1)),
        throwsA(isA<ImagePrepException>().having((e) => e.message, 'message', contains('25 MB'))),
      );
      // Exactly at the limit is not refused for its size (it is not a picture, which is another message).
      await expectLater(
        prepareImage(Uint8List(maxImageInputBytes)),
        throwsA(isA<ImagePrepException>().having((e) => e.message, 'message', isNot(contains('25 MB')))),
      );
    });

    test('bytes that are no picture, and no bytes, are refused', () async {
      await expectLater(
        prepareImage(Uint8List.fromList(utf8.encode('this is a text file, not a picture'))),
        throwsA(isA<ImagePrepException>().having((e) => e.message, 'message', contains('Could not read'))),
      );
      await expectLater(prepareImage(Uint8List(0)), throwsA(isA<ImagePrepException>()));
    });
  });
}
