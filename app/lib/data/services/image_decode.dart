import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// A decoded image plus what the file really contained.
class DecodedImage {
  DecodedImage({required this.image, required this.width, required this.height, required this.downscaled});

  final ui.Image image;

  /// Pixel size of the file as it is meant to be seen (EXIF orientation
  /// applied: a phone photo stored 4000 x 3000 and flagged "rotate 90" is
  /// 3000 x 4000), not of [image] (which may have been shrunk).
  final int width;
  final int height;

  /// [image] has fewer pixels than the file.
  final bool downscaled;

  /// Bytes the decoded bitmap holds.
  int get bitmapBytes => image.width * image.height * 4;

  void dispose() => image.dispose();
}

/// Decodes [bytes], shrinking the longest side to [maxDimension] while
/// decoding (the full bitmap is never allocated). Throws when the bytes are not
/// an image the engine can read.
typedef ImageDecoder = Future<DecodedImage> Function(Uint8List bytes, {required int maxDimension});

/// Decodes [bytes] so the result fits inside [maxWidth] x [maxHeight] pixels
/// (aspect kept, never enlarged), shrinking while it decodes.
typedef FitDecoder = Future<DecodedImage> Function(Uint8List bytes, {required int maxWidth, required int maxHeight});

Future<DecodedImage> decodeImageBytes(Uint8List bytes, {required int maxDimension}) =>
    decodeImageFit(bytes, maxWidth: maxDimension, maxHeight: maxDimension);

/// The engine's codec applies the EXIF orientation of a JPEG (the descriptor
/// already reports the rotated size), so [DecodedImage.width] is the size the
/// person sees. A target size is taken in those rotated terms too.
Future<DecodedImage> decodeImageFit(Uint8List bytes, {required int maxWidth, required int maxHeight}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  try {
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    final scale = fitScaleWithin(w, h, maxWidth, maxHeight);
    final shrink = scale < 1;
    codec = await descriptor.instantiateCodec(
      // One side is enough: the engine keeps the aspect for the other.
      targetWidth: shrink ? math.max(1, (w * scale).round()) : null,
    );
    final frame = await codec.getNextFrame();
    return DecodedImage(image: frame.image, width: w, height: h, downscaled: shrink);
  } finally {
    codec?.dispose();
    descriptor?.dispose();
    buffer.dispose();
  }
}

/// The factor (at most 1) that makes a [width] x [height] picture fit in
/// [maxWidth] x [maxHeight].
double fitScaleWithin(int width, int height, int maxWidth, int maxHeight) {
  if (width <= 0 || height <= 0) return 1;
  return math.min(1.0, math.min(maxWidth / width, maxHeight / height));
}
