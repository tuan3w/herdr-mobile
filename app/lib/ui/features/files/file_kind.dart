import 'dart:convert';
import 'dart:typed_data';

/// How the viewer shows a file.
enum FileKind {
  /// Source, logs, config and anything else that reads as text.
  text,
  markdown,
  json,
  image,

  /// Vector image: text on disk, but there is nothing here to draw it.
  svg,
  pdf,

  /// Anything else that is not text: shown as an info card with a hex preview.
  binary,
}

/// A file's [kind] and the plain-language [label] shown on its info card.
class FileType {
  const FileType(this.kind, this.label);

  final FileKind kind;
  final String label;

  @override
  bool operator ==(Object other) => other is FileType && other.kind == kind && other.label == label;

  @override
  int get hashCode => Object.hash(kind, label);

  @override
  String toString() => 'FileType($kind, $label)';
}

const _imageExt = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

const _binaryExt = {
  'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'zst', 'jar', 'war', 'apk', 'aab', 'ipa', 'deb', 'rpm',
  'so', 'dylib', 'dll', 'exe', 'o', 'a', 'class', 'pyc', 'wasm', 'bin', 'dat', 'db', 'sqlite', 'sqlite3',
  'mp3', 'wav', 'flac', 'ogg', 'm4a', 'mp4', 'mov', 'mkv', 'webm', 'avi',
  'ttf', 'otf', 'woff', 'woff2', 'ico', 'icns', 'psd', 'heic', 'heif', 'tiff', 'tif', 'avif',
  'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'iso', 'img', 'dmg', 'pkl', 'npy', 'parquet',
};

const _markdownExt = {'md', 'markdown', 'mdx'};
const _jsonExt = {'json', 'jsonc', 'json5', 'geojson', 'webmanifest', 'ipynb'};

String _extension(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 || dot == name.length - 1 ? '' : name.substring(dot + 1).toLowerCase();
}

/// What the file name alone suggests. Unknown names are assumed to be text:
/// [detectType] corrects that from the content.
FileType typeForName(String name) {
  final ext = _extension(name);
  if (_imageExt.contains(ext)) return FileType(FileKind.image, '${ext.toUpperCase()} image');
  if (ext == 'svg') return const FileType(FileKind.svg, 'SVG image');
  if (ext == 'pdf') return const FileType(FileKind.pdf, 'PDF document');
  if (_markdownExt.contains(ext)) return const FileType(FileKind.markdown, 'Markdown');
  if (_jsonExt.contains(ext)) return const FileType(FileKind.json, 'JSON');
  if (_binaryExt.contains(ext)) return FileType(FileKind.binary, '${ext.toUpperCase()} file');
  return const FileType(FileKind.text, 'Text');
}

bool _starts(Uint8List b, List<int> magic, [int at = 0]) {
  if (b.length < at + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (b[at + i] != magic[i]) return false;
  }
  return true;
}

/// A type from the first bytes alone, or null when there is no signature.
FileType? sniffSignature(Uint8List head) {
  if (_starts(head, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
    return const FileType(FileKind.image, 'PNG image');
  }
  if (_starts(head, const [0xFF, 0xD8, 0xFF])) return const FileType(FileKind.image, 'JPEG image');
  if (_starts(head, const [0x47, 0x49, 0x46, 0x38])) return const FileType(FileKind.image, 'GIF image');
  if (_starts(head, const [0x52, 0x49, 0x46, 0x46]) && _starts(head, const [0x57, 0x45, 0x42, 0x50], 8)) {
    return const FileType(FileKind.image, 'WebP image');
  }
  // "BM" alone is too weak (plain text can start with it): also require the
  // reserved fields of a BITMAPFILEHEADER to be zero.
  if (_starts(head, const [0x42, 0x4D]) && head.length >= 14 && head[6] == 0 && head[7] == 0 && head[8] == 0 && head[9] == 0) {
    return const FileType(FileKind.image, 'BMP image');
  }
  if (_starts(head, const [0x25, 0x50, 0x44, 0x46, 0x2D])) {
    return const FileType(FileKind.pdf, 'PDF document');
  }
  if (_starts(head, const [0x7F, 0x45, 0x4C, 0x46])) return const FileType(FileKind.binary, 'Executable (ELF)');
  if (_starts(head, const [0x50, 0x4B, 0x03, 0x04])) return const FileType(FileKind.binary, 'ZIP archive');
  if (_starts(head, const [0x1F, 0x8B])) return const FileType(FileKind.binary, 'gzip archive');
  if (_starts(head, const [0x37, 0x7A, 0xBC, 0xAF])) return const FileType(FileKind.binary, '7z archive');
  if (_starts(head, const [0xFD, 0x37, 0x7A, 0x58, 0x5A])) return const FileType(FileKind.binary, 'xz archive');
  if (_starts(head, const [0x42, 0x5A, 0x68])) return const FileType(FileKind.binary, 'bzip2 archive');
  if (_starts(head, const [0x00, 0x61, 0x73, 0x6D])) return const FileType(FileKind.binary, 'WebAssembly');
  if (_starts(head, const [0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20, 0x66])) {
    return const FileType(FileKind.binary, 'SQLite database');
  }
  if (_starts(head, const [0x75, 0x73, 0x74, 0x61, 0x72], 257)) return const FileType(FileKind.binary, 'tar archive');
  return null;
}

/// Whether [head] (the start of a file) is not text: a NUL byte, or so much
/// invalid UTF-8 that it cannot be.
bool looksBinary(Uint8List head) {
  if (head.isEmpty) return false;
  final sample = head.length > 8192 ? Uint8List.sublistView(head, 0, 8192) : head;
  if (sample.contains(0)) return true;
  final text = const Utf8Decoder(allowMalformed: true).convert(
    Uint8List.sublistView(sample, 0, utf8SafeLength(sample)),
  );
  if (text.isEmpty) return false;
  var bad = 0;
  for (final unit in text.codeUnits) {
    // U+FFFD from malformed input, or a C0 control that text never uses.
    if (unit == 0xFFFD || (unit < 0x20 && unit != 9 && unit != 10 && unit != 13 && unit != 12 && unit != 27 && unit != 8)) {
      bad++;
    }
  }
  return bad > 2 && bad * 50 > text.length;
}

/// The type of file [name] whose first bytes are [head]. Content decides
/// between text and binary and recognises images and PDFs whatever they are
/// called; the name only picks among kinds of text (Markdown, JSON, SVG).
FileType detectType(String name, Uint8List head) {
  final byName = typeForName(name);
  if (head.isEmpty) return const FileType(FileKind.text, 'Empty file');
  final signature = sniffSignature(head);
  if (signature != null) return signature;
  if (looksBinary(head)) {
    // `.bin` stays what its name says; a name that promises text, an image or
    // a PDF the content does not have is just "binary data".
    return byName.kind == FileKind.binary ? byName : const FileType(FileKind.binary, 'Binary data');
  }
  // Text content under a name that says image/PDF/binary (an HTML error page
  // saved as .png, a text file called .bin): the content wins.
  return switch (byName.kind) {
    FileKind.image || FileKind.pdf || FileKind.binary => const FileType(FileKind.text, 'Text'),
    _ => byName,
  };
}

/// How many leading bytes of [bytes] end on a complete UTF-8 sequence: a read
/// that stops mid-character must not turn its last bytes into U+FFFD.
int utf8SafeLength(Uint8List bytes) {
  var end = bytes.length;
  // Look back over at most three continuation bytes for the sequence's lead.
  for (var back = 1; back <= 3 && back <= end; back++) {
    final b = bytes[end - back];
    if (b & 0xC0 == 0x80) continue; // continuation
    final need = b >= 0xF0
        ? 4
        : b >= 0xE0
            ? 3
            : b >= 0xC0
                ? 2
                : 1;
    return need > back ? end - back : end;
  }
  return end;
}
