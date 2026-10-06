import 'dart:convert';
import 'dart:typed_data';

/// The photo details worth showing next to a picture, read from its EXIF.
class ExifInfo {
  const ExifInfo({
    this.orientation,
    this.taken,
    this.camera,
    this.lens,
    this.settings,
  });

  /// EXIF orientation 1..8 (tag 0x0112), null when absent or out of range.
  final int? orientation;

  /// When the photo was taken, as the camera's local wall-clock time (not UTC).
  final DateTime? taken;

  /// `Make Model`, with the make dropped when the model already starts with it.
  final String? camera;

  /// The lens model.
  final String? lens;

  /// One line such as `f/1.8 · 1/120 s · ISO 100 · 5.4 mm`.
  final String? settings;

  bool get isEmpty =>
      orientation == null &&
      taken == null &&
      camera == null &&
      lens == null &&
      settings == null;
}

/// Only this much of the input is ever examined.
const int _maxBytes = 256 * 1024;

/// EXIF only needs IFD0 and the Exif sub-IFD; a few extra hops are tolerated.
const int _maxIfds = 4;

/// Real cameras write well under a hundred entries per directory.
const int _maxEntries = 512;

/// Longest text value read; make/model/lens are far shorter.
const int _maxTextBytes = 512;

const int _tagOrientation = 0x0112;
const int _tagMake = 0x010F;
const int _tagModel = 0x0110;
const int _tagDateTime = 0x0132;
const int _tagExifIfd = 0x8769;
const int _tagExposureTime = 0x829A;
const int _tagFNumber = 0x829D;
const int _tagIso = 0x8827;
const int _tagDateOriginal = 0x9003;
const int _tagDateDigitized = 0x9004;
const int _tagFocalLength = 0x920A;
const int _tagLensModel = 0xA434;

const Set<int> _wanted = {
  _tagOrientation,
  _tagMake,
  _tagModel,
  _tagDateTime,
  _tagExposureTime,
  _tagFNumber,
  _tagIso,
  _tagDateOriginal,
  _tagDateDigitized,
  _tagFocalLength,
  _tagLensModel,
};

/// Reads the EXIF of a JPEG (APP1 `Exif\0\0` segment), a PNG (`eXIf` chunk) or
/// a WebP (RIFF `EXIF` chunk).
///
/// Returns null when the bytes carry no EXIF, or none of the fields of
/// [ExifInfo]. Never throws: every read is bounds-checked, loops are cut off,
/// and only the first 256 KiB of [bytes] is looked at.
ExifInfo? readExif(Uint8List bytes) {
  final data = bytes.length > _maxBytes
      ? Uint8List.sublistView(bytes, 0, _maxBytes)
      : bytes;
  final tiff = _locateTiff(data);
  if (tiff == null) return null;
  final info = _Tiff.parse(tiff)?.info();
  return info == null || info.isEmpty ? null : info;
}

const List<int> _exifPrefix = [0x45, 0x78, 0x69, 0x66, 0, 0]; // Exif\0\0

bool _startsWith(Uint8List d, int at, List<int> prefix) {
  if (at < 0 || at + prefix.length > d.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (d[at + i] != prefix[i]) return false;
  }
  return true;
}

int _u16be(Uint8List d, int at) => (d[at] << 8) | d[at + 1];

int _u32be(Uint8List d, int at) =>
    (d[at] << 24) | (d[at + 1] << 16) | (d[at + 2] << 8) | d[at + 3];

int _u32le(Uint8List d, int at) =>
    d[at] | (d[at + 1] << 8) | (d[at + 2] << 16) | (d[at + 3] << 24);

/// The TIFF structure inside whichever container [d] is, or null.
Uint8List? _locateTiff(Uint8List d) {
  if (d.length >= 2 && d[0] == 0xFF && d[1] == 0xD8) return _fromJpeg(d);
  if (_startsWith(d, 0, const [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
  ])) {
    return _fromPng(d);
  }
  if (_startsWith(d, 0, const [0x52, 0x49, 0x46, 0x46]) &&
      _startsWith(d, 8, const [0x57, 0x45, 0x42, 0x50])) {
    return _fromWebp(d);
  }
  return null;
}

/// Strips the optional `Exif\0\0` prefix from a chunk payload.
Uint8List _unprefixed(Uint8List payload) => _startsWith(payload, 0, _exifPrefix)
    ? Uint8List.sublistView(payload, _exifPrefix.length)
    : payload;

Uint8List? _fromJpeg(Uint8List d) {
  var pos = 2;
  while (pos + 4 <= d.length) {
    if (d[pos] != 0xFF) return null;
    final marker = d[pos + 1];
    if (marker == 0xFF) {
      pos++; // fill byte
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      pos += 2; // markers without a length
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null; // image data starts
    final length = _u16be(d, pos + 2);
    if (length < 2) return null;
    final start = pos + 4;
    final end = pos + 2 + length < d.length ? pos + 2 + length : d.length;
    if (marker == 0xE1 && end > start && _startsWith(d, start, _exifPrefix)) {
      return Uint8List.sublistView(d, start + _exifPrefix.length, end);
    }
    pos += 2 + length;
  }
  return null;
}

Uint8List? _fromPng(Uint8List d) {
  var pos = 8;
  while (pos + 8 <= d.length) {
    final length = _u32be(d, pos);
    final start = pos + 8;
    final end = start + length < d.length ? start + length : d.length;
    if (_startsWith(d, pos + 4, const [0x65, 0x58, 0x49, 0x66])) {
      // eXIf
      return _unprefixed(Uint8List.sublistView(d, start, end));
    }
    pos = start + length + 4; // data + CRC
  }
  return null;
}

Uint8List? _fromWebp(Uint8List d) {
  var pos = 12;
  while (pos + 8 <= d.length) {
    final length = _u32le(d, pos + 4);
    final start = pos + 8;
    final end = start + length < d.length ? start + length : d.length;
    if (_startsWith(d, pos, const [0x45, 0x58, 0x49, 0x46])) {
      // EXIF
      return _unprefixed(Uint8List.sublistView(d, start, end));
    }
    pos = start + length + (length & 1); // chunks are padded to even sizes
  }
  return null;
}

/// Where one IFD entry's values live inside the TIFF bytes.
class _Entry {
  const _Entry(this.type, this.count, this.start);
  final int type;
  final int count;

  /// Absolute offset of the first value; always inside the TIFF bytes.
  final int start;
}

class _Tiff {
  _Tiff._(this._d, this._little);

  final Uint8List _d;
  final bool _little;
  final Map<int, _Entry> _entries = {};

  static _Tiff? parse(Uint8List d) {
    if (d.length < 8) return null;
    final bool little;
    if (d[0] == 0x49 && d[1] == 0x49) {
      little = true;
    } else if (d[0] == 0x4D && d[1] == 0x4D) {
      little = false;
    } else {
      return null;
    }
    final tiff = _Tiff._(d, little);
    if (tiff._u16(2) != 42) return null;
    final first = tiff._u32(4);
    if (first == null) return null;
    tiff._walk(first);
    return tiff;
  }

  int? _u16(int at) {
    if (at < 0 || at + 2 > _d.length) return null;
    return _little ? _d[at] | (_d[at + 1] << 8) : _u16be(_d, at);
  }

  int? _u32(int at) {
    if (at < 0 || at + 4 > _d.length) return null;
    return _little ? _u32le(_d, at) : _u32be(_d, at);
  }

  /// Reads IFD0, then the Exif sub-IFD it points at. The "next IFD" link is
  /// ignored (it only leads to the thumbnail), and each offset is read once.
  void _walk(int first) {
    final queue = <int>[first];
    final seen = <int>{};
    while (queue.isNotEmpty && seen.length < _maxIfds) {
      final at = queue.removeLast();
      if (!seen.add(at)) continue;
      final pointer = _readIfd(at);
      if (pointer != null) queue.add(pointer);
    }
  }

  /// Collects the wanted entries of the IFD at [at]; returns the Exif IFD
  /// offset when the directory holds one.
  int? _readIfd(int at) {
    final count = _u16(at);
    if (count == null) return null;
    int? exifIfd;
    final n = count < _maxEntries ? count : _maxEntries;
    for (var i = 0; i < n; i++) {
      final e = at + 2 + i * 12;
      final tag = _u16(e);
      final type = _u16(e + 2);
      final cnt = _u32(e + 4);
      if (tag == null || type == null || cnt == null) return exifIfd;
      if (tag == _tagExifIfd) {
        if (cnt >= 1 && (type == 4 || type == 3)) {
          exifIfd = _scalar(e + 8, type);
        }
        continue;
      }
      if (!_wanted.contains(tag) || _entries.containsKey(tag)) continue;
      final size = _typeSize(type);
      if (size == 0 || cnt == 0) continue;
      final total = size * cnt;
      final int start;
      if (total <= 4) {
        start = e + 8;
      } else {
        final offset = _u32(e + 8);
        if (offset == null) continue;
        start = offset;
      }
      if (start < 0 || start + total > _d.length) continue;
      _entries[tag] = _Entry(type, cnt, start);
    }
    return exifIfd;
  }

  int? _scalar(int at, int type) => type == 3 ? _u16(at) : _u32(at);

  static int _typeSize(int type) => switch (type) {
    1 || 2 || 6 || 7 => 1,
    3 || 8 => 2,
    4 || 9 || 11 => 4,
    5 || 10 || 12 => 8,
    _ => 0,
  };

  /// First unsigned integer value of a BYTE/SHORT/LONG entry.
  int? _int(int tag) {
    final e = _entries[tag];
    if (e == null) return null;
    return switch (e.type) {
      1 => _d[e.start],
      3 => _u16(e.start),
      4 => _u32(e.start),
      _ => null,
    };
  }

  /// First value of a RATIONAL/SRATIONAL entry; null for a zero denominator.
  double? _rational(int tag) {
    final e = _entries[tag];
    if (e == null || (e.type != 5 && e.type != 10)) return null;
    final signed = e.type == 10;
    final num = _u32(e.start);
    final den = _u32(e.start + 4);
    if (num == null || den == null) return null;
    final n = signed ? num.toSigned(32) : num;
    final d = signed ? den.toSigned(32) : den;
    if (d == 0) return null;
    return n / d;
  }

  String? _text(int tag) {
    final e = _entries[tag];
    if (e == null || e.type != 2) return null;
    final length = e.count < _maxTextBytes ? e.count : _maxTextBytes;
    final raw = <int>[
      for (var i = 0; i < length; i++)
        if (_d[e.start + i] != 0) _d[e.start + i],
    ];
    final text = utf8.decode(raw, allowMalformed: true).trim();
    return text.isEmpty ? null : text;
  }

  DateTime? _date(int tag) {
    final text = _text(tag);
    if (text == null) return null;
    final m = _dateRe.firstMatch(text);
    if (m == null) return null;
    final v = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
    final date = DateTime(v[0], v[1], v[2], v[3], v[4], v[5]);
    // A rolled-over value (month 13, day 0, Feb 30...) is not a real date.
    final real =
        date.year == v[0] &&
        date.month == v[1] &&
        date.day == v[2] &&
        date.hour == v[3] &&
        date.minute == v[4] &&
        date.second == v[5];
    return real && v[0] > 0 ? date : null;
  }

  static final RegExp _dateRe = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  );

  ExifInfo info() {
    final orientation = _int(_tagOrientation);
    return ExifInfo(
      orientation: orientation != null && orientation >= 1 && orientation <= 8
          ? orientation
          : null,
      taken:
          _date(_tagDateOriginal) ??
          _date(_tagDateDigitized) ??
          _date(_tagDateTime),
      camera: _camera(_text(_tagMake), _text(_tagModel)),
      lens: _text(_tagLensModel),
      settings: _settings(),
    );
  }

  static String? _camera(String? make, String? model) {
    if (make == null) return model;
    if (model == null) return make;
    return model.toLowerCase().startsWith(make.toLowerCase())
        ? model
        : '$make $model';
  }

  String? _settings() {
    final parts = <String>[];
    final f = _rational(_tagFNumber);
    if (f != null && f > 0) parts.add('f/${_oneDecimal(f)}');
    final t = _rational(_tagExposureTime);
    if (t != null && t > 0) parts.add(_exposure(t));
    final iso = _int(_tagIso);
    if (iso != null && iso > 0) parts.add('ISO $iso');
    final mm = _rational(_tagFocalLength);
    if (mm != null && mm > 0) parts.add('${_oneDecimal(mm)} mm');
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static String _oneDecimal(double v) {
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
  }

  static String _exposure(double t) {
    if (t < 1) {
      final n = (1 / t).round();
      if (n > 1) return '1/$n s';
    }
    return '${_oneDecimal(t)} s';
  }
}
