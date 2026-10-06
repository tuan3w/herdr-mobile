import 'dart:typed_data';

/// Whether a picture may have see-through pixels, decided from its header
/// alone (no decode): a PNG with an alpha colour type or a `tRNS` chunk, a GIF
/// (it may), a WebP flagged with alpha. A JPEG or a BMP never does. A false
/// positive only shows a checkerboard behind an opaque picture, where it is
/// not seen.
bool mayHaveTransparency(Uint8List b) {
  if (_is(b, 0, const [0x89, 0x50, 0x4E, 0x47])) return _pngAlpha(b);
  if (_is(b, 0, const [0x47, 0x49, 0x46, 0x38])) return true;
  if (_is(b, 0, const [0x52, 0x49, 0x46, 0x46]) && _is(b, 8, const [0x57, 0x45, 0x42, 0x50])) return _webpAlpha(b);
  return false;
}

bool _pngAlpha(Uint8List b) {
  // 8 signature bytes, then chunks: length(4) type(4) data crc(4). IHDR's
  // colour type is the 10th byte of its data.
  if (b.length < 26) return false;
  final colour = b[25];
  if (colour == 4 || colour == 6) return true;
  var at = 8;
  for (var hops = 0; hops < 64 && at + 8 <= b.length; hops++) {
    final length = (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    if (_is(b, at + 4, const [0x74, 0x52, 0x4E, 0x53])) return true; // tRNS
    if (_is(b, at + 4, const [0x49, 0x44, 0x41, 0x54])) return false; // IDAT: pixels start
    final next = at + 12 + length;
    if (next <= at || next > b.length) return false;
    at = next;
  }
  return false;
}

bool _webpAlpha(Uint8List b) {
  if (b.length < 25) return false;
  if (_is(b, 12, const [0x56, 0x50, 0x38, 0x58])) return b[20] & 0x10 != 0; // VP8X: alpha flag
  if (_is(b, 12, const [0x56, 0x50, 0x38, 0x4C])) return b[24] & 0x10 != 0; // VP8L: alpha_is_used
  return false;
}

bool _is(Uint8List b, int at, List<int> magic) {
  if (b.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[at + i] != magic[i]) return false;
  }
  return true;
}
