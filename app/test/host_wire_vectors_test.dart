import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/host/wire.dart';

// The golden vectors the Rust host (rust/crates/wire/tests/vectors.rs) decodes
// and re-encodes: this is the same file, read by the Dart codec, so the two
// implementations cannot drift. After a deliberate format change regenerate it
// from Rust (`cargo test -p wire --test vectors -- --ignored regenerate`) and
// this test fails until wire.dart agrees.

Uint8List fromHex(String text) =>
    Uint8List.fromList([for (var i = 0; i < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)]);

String toHex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

List<Frame> decodeAll(Uint8List bytes, int step) {
  final decoder = FrameDecoder(expectMagic: false);
  final out = <Frame>[];
  for (var i = 0; i < bytes.length; i += step) {
    decoder.add(bytes.sublist(i, i + step > bytes.length ? bytes.length : i + step), out.add);
  }
  decoder.close();
  return out;
}

void main() {
  final doc = jsonDecode(File('../rust/crates/wire/tests/vectors.json').readAsStringSync()) as Map<String, Object?>;

  test('the magic is the one Rust writes', () {
    expect(toHex(hostMagic), doc['magic_hex']);
  });

  for (final v in (doc['vectors']! as List).cast<Map<String, Object?>>()) {
    test('vector ${v['name']} decodes at every chunking and re-encodes to the same bytes', () {
      final bytes = fromHex(v['hex']! as String);
      final expected = (v['frames']! as List).cast<Map<String, Object?>>();
      for (final step in [1, 3, 4096, bytes.length]) {
        final got = decodeAll(bytes, step);
        expect(got, hasLength(expected.length), reason: 'step $step');
        final inflater = Inflater();
        final again = BytesBuilder();
        for (var i = 0; i < got.length; i++) {
          final f = got[i], e = expected[i];
          expect(f.kind.name, e['kind']);
          final flagName = switch (f.flags) {
            FrameFlags.none => '',
            FrameFlags.deflate => 'deflate',
            FrameFlags.deflateCtx => 'deflate_ctx',
          };
          expect(flagName, e['flags']);
          expect(f.stream, e['stream']);
          expect(toHex(f.payload), e['payload_hex']);
          switch (f.flags) {
            case FrameFlags.none:
              break;
            case FrameFlags.deflate:
              expect(toHex(Inflater.once(f.payload)), e['inflated_hex']);
            case FrameFlags.deflateCtx:
              expect(toHex(inflater.inflate(f.payload)), e['inflated_hex']);
          }
          again.add(encodeFrame(f));
        }
        expect(toHex(again.takeBytes()), v['hex'], reason: 're-encoding changes the bytes (step $step)');
      }
    });
  }

  for (final r in (doc['rejects']! as List).cast<Map<String, Object?>>()) {
    test('reject ${r['name']} is ${r['error']}', () {
      final bytes = fromHex(r['hex']! as String);
      expect(
        () => decodeAll(bytes, bytes.length),
        throwsA(isA<WireFormatException>().having((e) => e.name, 'name', r['error'])),
      );
    });
  }

  test(
    'what a login shell printed before the magic is skipped, and a flood of it is an error that shows the start',
    () {
      final frame = encodeFrame(Frame.json(FrameKind.hello, 0, {'proto': 1}));
      final out = <Frame>[];
      final d = FrameDecoder();
      d.add([...utf8.encode('Last login: yesterday\n'), ...hostMagic.sublist(0, 5)], out.add);
      d.add([...hostMagic.sublist(5), ...frame], out.add);
      d.close();
      expect(out.single.kind, FrameKind.hello);
      final noisy = FrameDecoder();
      expect(
        () => noisy.add(utf8.encode('welcome to the box\n') + List.filled(hostMagicSearchLimit, 0x20), out.add),
        throwsA(isA<WireFormatException>().having((e) => e.message, 'message', contains('welcome to the box'))),
      );
    },
  );

  test('credit frames carry a u32', () {
    expect(Frame.credit(3, 524288).creditBytes, 524288);
    expect(Frame(FrameKind.credit, 3, Uint8List(2)).creditBytes, isNull);
  });

  test('deflate frames inflate; a continuous stream keeps its context', () {
    final data = utf8.encode('{"pane":"p1"}' * 100);
    expect(Inflater.once(deflate(data)), data);
    expect(deflateIfSmaller(utf8.encode('short')), isNull);
    expect(deflateIfSmaller(data), isNotNull);
    expect(() => Inflater.once(Uint8List.fromList([1, 2, 3, 4])), throwsA(isA<WireFormatException>()));
  });
}
