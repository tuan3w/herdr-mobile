import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/exif.dart';

/// One IFD entry to assemble: [type] is the TIFF type, [data] the raw value
/// bytes already in the file's byte order.
class _Tag {
  _Tag(this.tag, this.type, this.count, this.data);
  final int tag;
  final int type;
  final int count;
  final List<int> data;
}

List<int> _u16(int v, bool le) =>
    le ? [v & 0xFF, (v >> 8) & 0xFF] : [(v >> 8) & 0xFF, v & 0xFF];

List<int> _u32(int v, bool le) {
  final b = [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  return le ? b.reversed.toList() : b;
}

typedef _TagMaker = _Tag Function(bool le);

_TagMaker _short(int tag, int v) =>
    (le) => _Tag(tag, 3, 1, _u16(v, le));

_TagMaker _long(int tag, int v) =>
    (le) => _Tag(tag, 4, 1, _u32(v, le));

_TagMaker _ascii(int tag, String s) =>
    (le) => _Tag(tag, 2, s.length + 1, [...s.codeUnits, 0]);

_TagMaker _rational(int tag, int n, int d) =>
    (le) => _Tag(tag, 5, 1, [..._u32(n, le), ..._u32(d, le)]);

_TagMaker _srational(int tag, int n, int d) =>
    (le) => _Tag(tag, 10, 1, [..._u32(n & 0xFFFFFFFF, le), ..._u32(d, le)]);

/// A TIFF block: header, IFD0 (plus an Exif sub-IFD when [exif] is not empty),
/// then the out-of-line values.
Uint8List _tiff({
  bool le = true,
  List<_TagMaker> ifd0 = const [],
  List<_TagMaker> exif = const [],
  bool selfLoop = false,
}) {
  final zero = [for (final m in ifd0) m(le)];
  final one = [for (final m in exif) m(le)];
  final pointer = exif.isEmpty ? 0 : 1;
  final ifd0Size = 2 + (zero.length + pointer) * 12 + 4;
  final ifd1Size = one.isEmpty ? 0 : 2 + one.length * 12 + 4;
  const ifd0At = 8;
  final ifd1At = ifd0At + ifd0Size;
  final dataAt = ifd1At + ifd1Size;
  final out = <int>[
    ...(le ? [0x49, 0x49] : [0x4D, 0x4D]),
    ..._u16(42, le),
    ..._u32(ifd0At, le),
  ];
  final data = <int>[];

  List<int> entry(_Tag t) {
    final bytes = <int>[
      ..._u16(t.tag, le),
      ..._u16(t.type, le),
      ..._u32(t.count, le),
    ];
    if (t.data.length <= 4) {
      return [...bytes, ...t.data, ...List.filled(4 - t.data.length, 0)];
    }
    bytes.addAll(_u32(dataAt + data.length, le));
    data.addAll(t.data);
    if (data.length.isOdd) data.add(0);
    return bytes;
  }

  out.addAll(_u16(zero.length + pointer, le));
  for (final t in zero) {
    out.addAll(entry(t));
  }
  if (pointer == 1) {
    out.addAll(entry(_Tag(0x8769, 4, 1, _u32(ifd1At, le))));
  }
  out.addAll(_u32(selfLoop ? ifd0At : 0, le));
  if (one.isNotEmpty) {
    out.addAll(_u16(one.length, le));
    for (final t in one) {
      out.addAll(entry(t));
    }
    out.addAll(_u32(selfLoop ? ifd1At : 0, le));
  }
  return Uint8List.fromList([...out, ...data]);
}

const _exifHead = [0x45, 0x78, 0x69, 0x66, 0, 0];

Uint8List _jpeg(Uint8List tiff, {List<List<int>> before = const []}) {
  final payload = [..._exifHead, ...tiff];
  return Uint8List.fromList([
    0xFF, 0xD8,
    for (final seg in before) ...seg,
    0xFF, 0xE1, ..._u16(payload.length + 2, false), ...payload,
    0xFF, 0xD9, //
  ]);
}

Uint8List _png(Uint8List tiff) {
  List<int> chunk(String type, List<int> body) => [
    ..._u32(body.length, false),
    ...type.codeUnits,
    ...body,
    0, 0, 0, 0, // CRC is not checked
  ];
  return Uint8List.fromList([
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    ...chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0]),
    ...chunk('eXIf', tiff),
    ...chunk('IEND', const []),
  ]);
}

Uint8List _webp(Uint8List tiff, {bool prefix = false}) {
  final body = [if (prefix) ..._exifHead, ...tiff];
  final chunks = [
    ...'VP8X'.codeUnits,
    ..._u32(10, true),
    ...List.filled(10, 0),
    ...'EXIF'.codeUnits,
    ..._u32(body.length, true),
    ...body,
    if (body.length.isOdd) 0,
  ];
  return Uint8List.fromList([
    ...'RIFF'.codeUnits,
    ..._u32(chunks.length + 4, true),
    ...'WEBP'.codeUnits,
    ...chunks,
  ]);
}

ExifInfo _read(
  List<_TagMaker> ifd0, {
  List<_TagMaker> exif = const [],
  bool le = true,
}) => readExif(_jpeg(_tiff(le: le, ifd0: ifd0, exif: exif)))!;

void main() {
  group('byte order', () {
    for (final le in [true, false]) {
      test(le ? 'little endian' : 'big endian', () {
        final info = _read(
          [
            _short(0x0112, 6),
            _ascii(0x010F, 'Canon'),
            _ascii(0x0110, 'Canon EOS R5'),
          ],
          exif: [
            _ascii(0x9003, '2024:03:09 14:05:59'),
            _rational(0x829D, 18, 10),
            _rational(0x829A, 1, 120),
            _short(0x8827, 100),
            _rational(0x920A, 54, 10),
            _ascii(0xA434, 'RF24-105mm F4 L IS USM'),
          ],
          le: le,
        );
        expect(info.orientation, 6);
        expect(info.taken, DateTime(2024, 3, 9, 14, 5, 59));
        expect(info.taken!.isUtc, isFalse);
        expect(info.camera, 'Canon EOS R5');
        expect(info.lens, 'RF24-105mm F4 L IS USM');
        expect(info.settings, 'f/1.8 · 1/120 s · ISO 100 · 5.4 mm');
        expect(info.isEmpty, isFalse);
      });
    }
  });

  group('orientation', () {
    for (var o = 1; o <= 8; o++) {
      test('$o is kept', () {
        expect(_read([_short(0x0112, o)]).orientation, o);
      });
    }
    for (final o in [0, 9, 65535]) {
      test('$o is null', () {
        final info = readExif(
          _jpeg(_tiff(ifd0: [_short(0x0112, o), _ascii(0x0110, 'X')])),
        )!;
        expect(info.orientation, isNull);
        expect(info.camera, 'X');
      });
    }
    test('orientation stored as LONG is read', () {
      expect(_read([_long(0x0112, 3)]).orientation, 3);
    });
  });

  group('camera', () {
    test('make is dropped when the model starts with it', () {
      expect(
        _read([_ascii(0x010F, 'Canon'), _ascii(0x0110, 'Canon EOS R5')]).camera,
        'Canon EOS R5',
      );
    });
    test('make and model are joined otherwise', () {
      expect(
        _read([_ascii(0x010F, 'Apple'), _ascii(0x0110, 'iPhone 15 Pro')])
            .camera,
        'Apple iPhone 15 Pro',
      );
    });
    test('make alone, model alone', () {
      expect(_read([_ascii(0x010F, 'Leica')]).camera, 'Leica');
      expect(_read([_ascii(0x0110, 'Q3')]).camera, 'Q3');
    });
    test('blank values are absent; padding is trimmed', () {
      final info = _read([
        _ascii(0x010F, '   '),
        _ascii(0x0110, '  Pixel 8  '),
      ]);
      expect(info.camera, 'Pixel 8');
      expect(
        readExif(
          _jpeg(
            _tiff(
              ifd0: [
                _ascii(0x010F, '  '),
                _ascii(0x0110, ''),
                _short(0x0112, 1),
              ],
            ),
          ),
        )!.camera,
        isNull,
      );
    });
    test('NULs inside the value are removed', () {
      final info = _read([_ascii(0x0110, 'Pi\u0000xel\u0000 8')]);
      expect(info.camera, 'Pixel 8');
    });
  });

  group('settings', () {
    String? settings(List<_TagMaker> exif) =>
        _read([_short(0x0112, 1)], exif: exif).settings;

    test('full line', () {
      expect(
        settings([
          _rational(0x829D, 9, 5),
          _rational(0x829A, 1, 120),
          _short(0x8827, 100),
          _rational(0x920A, 27, 5),
        ]),
        'f/1.8 · 1/120 s · ISO 100 · 5.4 mm',
      );
    });
    test('whole f-number and focal length drop the decimal', () {
      expect(
        settings([_rational(0x829D, 2, 1), _rational(0x920A, 24, 1)]),
        'f/2 · 24 mm',
      );
    });
    test('f-number rounds to one decimal', () {
      expect(settings([_rational(0x829D, 28, 10)]), 'f/2.8');
      expect(settings([_rational(0x829D, 23, 10)]), 'f/2.3');
    });
    test('exposure of 2 s and 1.5 s', () {
      expect(settings([_rational(0x829A, 2, 1)]), '2 s');
      expect(settings([_rational(0x829A, 3, 2)]), '1.5 s');
    });
    test('exposure under a second is 1/N with N rounded', () {
      expect(settings([_rational(0x829A, 1, 4000)]), '1/4000 s');
      expect(settings([_rational(0x829A, 2, 5)]), '1/3 s'); // 2.5 rounds up
      expect(settings([_rational(0x829A, 3, 10)]), '1/3 s'); // 3.33
    });
    test('absent parts are skipped', () {
      expect(
        settings([_short(0x8827, 400), _rational(0x829D, 14, 10)]),
        'f/1.4 · ISO 400',
      );
      expect(settings([_short(0x8827, 64)]), 'ISO 64');
    });
    test('ISO stored as LONG', () {
      expect(settings([_long(0x8827, 12800)]), 'ISO 12800');
    });
    test('null when all absent', () {
      expect(settings([_ascii(0xA434, 'Lens')]), isNull);
    });
    test('zero denominator and zero values are ignored', () {
      expect(
        settings([
          _rational(0x829D, 1, 0),
          _rational(0x829A, 0, 1),
          _short(0x8827, 0),
          _rational(0x920A, 5, 0),
        ]),
        isNull,
      );
    });
    test('SRATIONAL is read; negative is ignored', () {
      expect(settings([_srational(0x829D, 14, 10)]), 'f/1.4');
      expect(settings([_srational(0x829D, -14, 10)]), isNull);
    });
  });

  group('taken', () {
    ExifInfo withDates(List<_TagMaker> ifd0, List<_TagMaker> exif) =>
        _read([_short(0x0112, 1), ...ifd0], exif: exif);

    test('DateTimeOriginal wins over digitized and DateTime', () {
      final info = withDates(
        [_ascii(0x0132, '2020:01:01 01:01:01')],
        [
          _ascii(0x9004, '2021:02:02 02:02:02'),
          _ascii(0x9003, '2022:03:03 03:03:03'),
        ],
      );
      expect(info.taken, DateTime(2022, 3, 3, 3, 3, 3));
    });
    test('falls back to digitized, then to DateTime', () {
      expect(
        withDates(
          [_ascii(0x0132, '2020:01:01 01:01:01')],
          [_ascii(0x9004, '2021:02:02 02:02:02')],
        ).taken,
        DateTime(2021, 2, 2, 2, 2, 2),
      );
      expect(
        withDates([_ascii(0x0132, '2020:01:01 01:01:01')], const []).taken,
        DateTime(2020, 1, 1, 1, 1, 1),
      );
    });
    test('an invalid original falls through to a valid one', () {
      expect(
        withDates(
          [_ascii(0x0132, '2020:01:01 01:01:01')],
          [_ascii(0x9003, '0000:00:00 00:00:00')],
        ).taken,
        DateTime(2020, 1, 1, 1, 1, 1),
      );
    });
    for (final bad in [
      '0000:00:00 00:00:00',
      '2024:13:01 00:00:00',
      '2024:02:30 00:00:00',
      '2024:01:01 25:00:00',
      '2024-01-01 10:00:00',
      'not a date',
      '',
    ]) {
      test('"$bad" is null', () {
        expect(withDates(const [], [_ascii(0x9003, bad)]).taken, isNull);
      });
    }
  });

  group('containers', () {
    final tiff = _tiff(
      le: false,
      ifd0: [_short(0x0112, 8), _ascii(0x0110, 'Model Z')],
      exif: [_rational(0x829D, 4, 1)],
    );
    void expectFixture(ExifInfo? info) {
      expect(info, isNotNull);
      expect(info!.orientation, 8);
      expect(info.camera, 'Model Z');
      expect(info.settings, 'f/4');
    }

    test('jpeg', () => expectFixture(readExif(_jpeg(tiff))));
    test('png eXIf chunk', () => expectFixture(readExif(_png(tiff))));
    test('webp EXIF chunk', () => expectFixture(readExif(_webp(tiff))));
    test(
      'webp EXIF chunk with Exif prefix',
      () => expectFixture(readExif(_webp(tiff, prefix: true))),
    );

    test('jpeg with other APPn segments before the EXIF one', () {
      List<int> app(int marker, List<int> body) => [
        0xFF,
        marker,
        ..._u16(body.length + 2, false),
        ...body,
      ];
      final bytes = _jpeg(
        tiff,
        before: [
          app(0xE0, [...'JFIF'.codeUnits, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]),
          app(0xE1, [...'http://ns.adobe.com/xap/1.0/'.codeUnits, 0, 60, 60]),
          app(0xE2, List.filled(40, 7)),
          [0xFF, 0xFF], // fill bytes between segments are legal
          app(0xED, [...'Photoshop 3.0'.codeUnits, 0]),
        ],
      );
      expectFixture(readExif(bytes));
    });

    test('jpeg whose image data starts before any EXIF has none', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xDA, 0, 4, 0, 0, 1, 2, 3, 4, //
        ..._jpeg(tiff).sublist(2),
      ]);
      expect(readExif(bytes), isNull);
    });

    test('only the first 256 KiB are examined', () {
      final bytes = _jpeg(
        tiff,
        before: [
          [0xFF, 0xE2, 0xFF, 0xFF, ...List.filled(0xFFFF - 2, 0)],
          [0xFF, 0xE2, 0xFF, 0xFF, ...List.filled(0xFFFF - 2, 0)],
          [0xFF, 0xE2, 0xFF, 0xFF, ...List.filled(0xFFFF - 2, 0)],
          [0xFF, 0xE2, 0xFF, 0xFF, ...List.filled(0xFFFF - 2, 0)],
        ],
      );
      expect(bytes.length, greaterThan(256 * 1024));
      expect(readExif(bytes), isNull);
    });

    test('no EXIF at all', () {
      expect(readExif(Uint8List(0)), isNull);
      expect(readExif(Uint8List.fromList([1, 2, 3])), isNull);
      expect(readExif(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9])), isNull);
      expect(
        readExif(
          Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 0, 0, 0xFF, 0xD9]),
        ),
        isNull,
      );
    });

    test('EXIF holding none of the fields is null', () {
      expect(
        readExif(_jpeg(_tiff(ifd0: [_ascii(0x010E, 'a description')]))),
        isNull,
      );
      expect(readExif(_jpeg(_tiff())), isNull);
    });

    test('values stored inline (<= 4 bytes) and at an offset both work', () {
      final info = _read([
        _ascii(0x010F, 'xyz'), // 4 bytes with the NUL: inline
        _ascii(0x0110, 'abcdefgh'), // out of line
      ]);
      expect(info.camera, 'xyz abcdefgh');
    });
  });

  group('hostile input', () {
    final tiff = _tiff(
      ifd0: [
        _short(0x0112, 3),
        _ascii(0x010F, 'Make'),
        _ascii(0x0110, 'A long enough model name'),
      ],
      exif: [
        _ascii(0x9003, '2024:03:09 14:05:59'),
        _rational(0x829D, 18, 10),
        _rational(0x829A, 1, 120),
        _short(0x8827, 100),
        _rational(0x920A, 54, 10),
      ],
    );

    test('a truncated segment at every length never throws', () {
      for (final build in [_jpeg, _png, _webp]) {
        final full = build(tiff);
        expect(readExif(full), isNotNull);
        for (var n = 0; n <= full.length; n++) {
          final cut = Uint8List.sublistView(full, 0, n);
          expect(() => readExif(cut), returnsNormally, reason: 'length $n');
        }
      }
    });

    test('a truncated big-endian TIFF never throws either', () {
      final be = _tiff(
        le: false,
        ifd0: [_ascii(0x0110, 'A long enough model name')],
        exif: [_rational(0x829D, 18, 10)],
      );
      final jpeg = _jpeg(be);
      for (var n = 0; n <= jpeg.length; n++) {
        final cut = Uint8List.sublistView(jpeg, 0, n);
        expect(() => readExif(cut), returnsNormally, reason: 'length $n');
      }
    });

    test('IFDs whose next-pointers loop to themselves terminate', () {
      final looping = _tiff(
        ifd0: [_short(0x0112, 2)],
        exif: [_rational(0x829D, 4, 1)],
        selfLoop: true,
      );
      final info = readExif(_jpeg(looping));
      expect(info!.orientation, 2);
      expect(info.settings, 'f/4');
    });

    test('an Exif IFD pointer back to IFD0 terminates', () {
      // IFD0 with a single ExifIFD entry pointing at offset 8 (itself).
      final bytes = Uint8List.fromList([
        0x49, 0x49, 42, 0, 8, 0, 0, 0, //
        1, 0, 0x69, 0x87, 4, 0, 1, 0, 0, 0, 8, 0, 0, 0, //
        8, 0, 0, 0,
      ]);
      expect(readExif(_jpeg(bytes)), isNull);
    });

    test('a huge entry count and wild offsets are bounds checked', () {
      final bytes = Uint8List.fromList([
        0x4D, 0x4D, 0, 42, 0, 0, 0, 8, //
        0xFF, 0xFF, // 65535 entries, only one present
        0x01, 0x10, 0, 2, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0,
      ]);
      expect(() => readExif(_jpeg(bytes)), returnsNormally);
      expect(readExif(_jpeg(bytes)), isNull);
    });

    test('an IFD offset past the end is ignored', () {
      final bytes = Uint8List.fromList([
        0x49,
        0x49,
        42,
        0,
        0xFF,
        0xFF,
        0xFF,
        0x7F,
      ]);
      expect(readExif(_jpeg(bytes)), isNull);
    });

    test('random garbage and corrupted fixtures never throw', () {
      final rnd = Random(7);
      for (var i = 0; i < 300; i++) {
        final junk = Uint8List.fromList(
          List.generate(rnd.nextInt(400), (_) => rnd.nextInt(256)),
        );
        expect(() => readExif(junk), returnsNormally);
      }
      for (final build in [_jpeg, _png, _webp]) {
        final base = build(tiff);
        for (var i = 0; i < 400; i++) {
          final bytes = Uint8List.fromList(base);
          for (var k = 0; k < 3; k++) {
            bytes[rnd.nextInt(bytes.length)] = rnd.nextInt(256);
          }
          expect(() => readExif(bytes), returnsNormally);
        }
      }
    });
  });
}
