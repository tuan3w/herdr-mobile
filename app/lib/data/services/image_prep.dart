import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../acp/acp_models.dart';

/// The file extensions of the pictures the phone prepares and the agents take
/// (lower case, no dot). One list for the Files tab, the viewer and the paste
/// into a terminal. HEIC is not in it: the phone does not prepare it, and no
/// agent was seen to take a pasted HEIC path (unverified).
const pictureExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

/// The largest picture the phone reads (bytes): a camera photo is a few MB.
const maxImageInputBytes = 25 * 1024 * 1024;

/// The longest side an attached picture keeps (px): what the agents' vision
/// models take without resizing themselves.
const maxImageEdge = 1568;

/// The most an attached picture weighs after preparing (bytes), about 1 MB.
const maxImageBytes = 1024 * 1024;

/// A source picture with more pixels than this is refused: a PNG has to be
/// decoded whole, and 150 MP is 600 MB of pixels.
const maxImagePixels = 150 * 1000 * 1000;

/// A picture that cannot be attached; [message] is for the person.
class ImagePrepException implements Exception {
  const ImagePrepException(this.message);

  final String message;

  @override
  String toString() => 'ImagePrepException($message)';
}

/// A picture ready to send: JPEG, at most [maxImageEdge] px on its long side
/// and about [maxImageBytes], with no metadata (no EXIF, so no GPS position).
class PreparedImage {
  const PreparedImage({required this.bytes, required this.width, required this.height});

  final Uint8List bytes;
  final int width;
  final int height;
  String get mimeType => 'image/jpeg';

  /// The prompt block (the agent takes base64).
  ImageBlock toBlock() => ImageBlock(data: base64Encode(bytes), mimeType: mimeType);
}

/// Decodes [input] (any format the engine reads: JPEG, PNG, WebP, GIF, BMP,
/// HEIF where the platform has it; an animation keeps its first frame),
/// downscales it so the long side is at most [maxEdge], and re-encodes it as
/// JPEG of at most [maxBytes], lowering the quality (85, 75, ... 35) and then
/// the size before it gives up. Transparency is flattened onto white.
/// Re-encoding drops every metadata block.
///
/// The decode and downscale run in the engine's codec (native, off the UI
/// isolate; the JPEG decoder scales while it decodes, so a 12 MP photo never
/// exists at full size in Dart); the JPEG encoding runs in a worker isolate.
/// Never blocks a frame.
///
/// Throws [ImagePrepException] for input over [maxImageInputBytes] or
/// [maxImagePixels], and for bytes no codec reads.
Future<PreparedImage> prepareImage(Uint8List input, {int maxEdge = maxImageEdge, int maxBytes = maxImageBytes}) async {
  if (input.isEmpty) throw const ImagePrepException('That file is empty.');
  if (input.lengthInBytes > maxImageInputBytes) {
    throw const ImagePrepException('That picture is larger than 25 MB. Pick a smaller one.');
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(input);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } on Object {
      throw const ImagePrepException('Could not read that picture. Use a JPEG, PNG or WebP.');
    }
    final width = descriptor.width;
    final height = descriptor.height;
    if (width <= 0 || height <= 0) throw const ImagePrepException('Could not read that picture.');
    if (width * height > maxImagePixels) {
      throw const ImagePrepException('That picture has too many pixels (over 150 megapixels).');
    }
    final long = width > height ? width : height;
    final scale = long > maxEdge ? maxEdge / long : 1.0;
    final targetWidth = scale < 1 ? (width * scale).round().clamp(1, maxEdge) : null;
    final targetHeight = scale < 1 ? (height * scale).round().clamp(1, maxEdge) : null;
    ByteData? rgba;
    try {
      codec = await descriptor.instantiateCodec(targetWidth: targetWidth, targetHeight: targetHeight);
      image = (await codec.getNextFrame()).image;
      rgba = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    } on Object {
      throw const ImagePrepException('Could not read that picture. Use a JPEG, PNG or WebP.');
    }
    if (rgba == null) throw const ImagePrepException('Could not read that picture.');
    final w = image.width;
    final h = image.height;
    final job = _Job(TransferableTypedData.fromList([rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes)]), w, h, maxBytes);
    final done = await Isolate.run(() => _encode(job));
    return PreparedImage(bytes: done.bytes.materialize().asUint8List(), width: done.width, height: done.height);
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

class _Job {
  const _Job(this.rgba, this.width, this.height, this.maxBytes);

  final TransferableTypedData rgba;
  final int width;
  final int height;
  final int maxBytes;
}

class _Done {
  const _Done(this.bytes, this.width, this.height);

  final TransferableTypedData bytes;
  final int width;
  final int height;
}

const _qualities = [85, 75, 65, 55, 45, 35];

/// In the worker: flatten, then encode at falling quality; when even the
/// lowest is too big, shrink by a fifth and start again.
_Done _encode(_Job job) {
  final rgba = job.rgba.materialize().asUint8List();
  final pixels = job.width * job.height;
  final rgb = Uint8List(pixels * 3);
  for (var i = 0, o = 0; i < pixels * 4; i += 4, o += 3) {
    final a = rgba[i + 3];
    if (a == 255) {
      rgb[o] = rgba[i];
      rgb[o + 1] = rgba[i + 1];
      rgb[o + 2] = rgba[i + 2];
    } else {
      // Straight alpha over white.
      final back = 255 * (255 - a);
      rgb[o] = (rgba[i] * a + back) ~/ 255;
      rgb[o + 1] = (rgba[i + 1] * a + back) ~/ 255;
      rgb[o + 2] = (rgba[i + 2] * a + back) ~/ 255;
    }
  }
  var image = img.Image.fromBytes(width: job.width, height: job.height, bytes: rgb.buffer, numChannels: 3);
  while (true) {
    Uint8List? last;
    for (final q in _qualities) {
      last = img.encodeJpg(image, quality: q);
      if (last.lengthInBytes <= job.maxBytes) {
        return _Done(TransferableTypedData.fromList([last]), image.width, image.height);
      }
    }
    final w = (image.width * 0.8).round();
    final h = (image.height * 0.8).round();
    if (w < 16 || h < 16) {
      // Cannot get smaller; send what the lowest quality made.
      return _Done(TransferableTypedData.fromList([last!]), image.width, image.height);
    }
    image = img.copyResize(image, width: w, height: h, interpolation: img.Interpolation.average);
  }
}
