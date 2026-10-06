/// What a directory entry is. [link] is a symbolic link (see
/// [RemoteEntry.resolvedKind] for what it points at); [other] is a socket,
/// FIFO or device node, which cannot be opened.
enum RemoteEntryKind {
  dir,
  file,
  link,
  other;

  static RemoteEntryKind parse(String? name) =>
      values.firstWhere((k) => k.name == name, orElse: () => other);
}

/// One row of a directory listing.
class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.kind,
    this.resolvedKind,
    this.size,
    this.modified,
    this.mode,
    this.linkTarget,
  });

  final String name;

  /// Absolute path of the entry itself (not of a link's target).
  final String path;

  /// As listed: a symlink is [RemoteEntryKind.link].
  final RemoteEntryKind kind;

  /// What the entry is once links are followed; null for a broken link.
  /// Equal to [kind] for everything that is not a link.
  final RemoteEntryKind? resolvedKind;

  /// Bytes, of the link target for a working link. Null when unknown.
  final int? size;
  final DateTime? modified;

  /// Unix mode bits (type and permissions) when the server reports them.
  final int? mode;
  final String? linkTarget;

  bool get isDirectory => resolvedKind == RemoteEntryKind.dir;
  bool get isFile => resolvedKind == RemoteEntryKind.file;
  bool get isBrokenLink => kind == RemoteEntryKind.link && resolvedKind == null;
  bool get isHidden => name.startsWith('.');

  Map<String, Object?> toJson() => {
        'name': name,
        'path': path,
        'kind': kind.name,
        'resolved': resolvedKind?.name,
        'size': size,
        'modified': modified?.millisecondsSinceEpoch,
        'mode': mode,
        'target': linkTarget,
      };

  factory RemoteEntry.fromJson(Map<Object?, Object?> j) => RemoteEntry(
        name: j['name']! as String,
        path: j['path']! as String,
        kind: RemoteEntryKind.parse(j['kind'] as String?),
        resolvedKind: j['resolved'] == null
            ? null
            : RemoteEntryKind.parse(j['resolved'] as String?),
        size: j['size'] as int?,
        modified: j['modified'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['modified']! as int, isUtc: true),
        mode: j['mode'] as int?,
        linkTarget: j['target'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is RemoteEntry &&
      other.name == name &&
      other.path == path &&
      other.kind == kind &&
      other.resolvedKind == resolvedKind &&
      other.size == size &&
      other.modified == modified &&
      other.mode == mode &&
      other.linkTarget == linkTarget;

  @override
  int get hashCode => Object.hash(name, path, kind, resolvedKind, size, modified, mode, linkTarget);
}

/// What `stat` found at a path, links followed.
class RemoteStat {
  const RemoteStat({
    required this.path,
    required this.kind,
    this.size,
    this.modified,
    this.mode,
  });

  /// The path that was asked about.
  final String path;

  /// [RemoteEntryKind.dir], [RemoteEntryKind.file] or [RemoteEntryKind.other];
  /// never [RemoteEntryKind.link] (links are followed).
  final RemoteEntryKind kind;
  final int? size;
  final DateTime? modified;
  final int? mode;

  bool get isDirectory => kind == RemoteEntryKind.dir;
  bool get isFile => kind == RemoteEntryKind.file;
  String get name => RemotePath.basename(path);

  Map<String, Object?> toJson() => {
        'path': path,
        'kind': kind.name,
        'size': size,
        'modified': modified?.millisecondsSinceEpoch,
        'mode': mode,
      };

  factory RemoteStat.fromJson(Map<Object?, Object?> j) => RemoteStat(
        path: j['path']! as String,
        kind: RemoteEntryKind.parse(j['kind'] as String?),
        size: j['size'] as int?,
        modified: j['modified'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['modified']! as int, isUtc: true),
        mode: j['mode'] as int?,
      );

  @override
  bool operator ==(Object other) =>
      other is RemoteStat &&
      other.path == path &&
      other.kind == kind &&
      other.size == size &&
      other.modified == modified &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(path, kind, size, modified, mode);
}

enum RemoteFileErrorKind {
  notFound,
  permission,

  /// Refused because the file is bigger than the viewer will load.
  tooLarge,

  /// A file operation on a directory (or a special file).
  notAFile,

  /// A directory operation on a file.
  notADirectory,

  /// The host does not offer SFTP (or the transport cannot do files at all).
  unsupported,

  /// The server refused or could not do the operation for a reason that fits
  /// no other kind (its own message is kept); retrying may help.
  failed,

  /// The connection failed or dropped; retrying may help.
  network;

  static RemoteFileErrorKind parse(String? name) =>
      values.firstWhere((k) => k.name == name, orElse: () => network);
}

/// A file operation failed. Like `HerdrTransportException`, it says whether
/// retrying can help: [fatal] is true when it cannot without the user changing
/// something (a missing file, a permission, an SFTP-less host); only
/// [RemoteFileErrorKind.network] and [RemoteFileErrorKind.failed] failures are
/// retryable by default.
class RemoteFileException implements Exception {
  RemoteFileException(this.kind, this.message, {bool? fatal, this.path})
      : fatal = fatal ??
            (kind != RemoteFileErrorKind.network && kind != RemoteFileErrorKind.failed);

  final RemoteFileErrorKind kind;
  final String message;
  final bool fatal;

  /// The path the operation was about, when known.
  final String? path;

  @override
  String toString() => message;
}

/// Hard cap on one `readFile` call, enforced by the transport whatever the
/// caller asks for.
const remoteReadCap = 8 * 1024 * 1024;

/// The biggest phone file the app uploads to a host (200 MB): a bigger one is
/// refused up front with [RemoteFileErrorKind.tooLarge].
const uploadMaxBytes = 200 * 1024 * 1024;

/// An upload stopped by [UploadJob.cancel]: not a failure, nobody is waiting.
/// Kind `failed` and fatal (retrying is the caller's choice, not automatic).
class UploadCancelled extends RemoteFileException {
  UploadCancelled({super.path})
      : super(RemoteFileErrorKind.failed, 'Upload cancelled', fatal: true);
}

/// One upload to the host, running in the transport's worker. Bytes never
/// reach the UI isolate: only counters do.
abstract interface class UploadJob {
  /// Completes when every byte is stored on the host. Fails with a
  /// [RemoteFileException] ([UploadCancelled] after [cancel]); an ignored
  /// failure never reaches the zone as an unhandled error.
  Future<void> get done;

  /// Stops at once: no more writes are issued, [done] fails with
  /// [UploadCancelled], and the partial file is closed and removed in the
  /// background. Harmless after [done] completed.
  void cancel();
}

/// Pure helpers for POSIX paths on the remote machine (the phone's own `path`
/// package would use the phone's rules; the remote is always `/`-separated).
abstract final class RemotePath {
  static final _location = RegExp(r'^(.*?)(?::(\d+))(?::(\d+))?$');
  static final _hashLine = RegExp(r'^(.*?)#L(\d+)(?:C\d+)?$');

  /// Splits a trailing `:line` or `:line:col` (compiler and grep output) or
  /// `#L12` (web links) off [raw]. A path that is only digits after a colon
  /// but would leave nothing behind keeps its colon.
  static ({String path, int? line, int? column}) splitLocation(String raw) {
    final text = raw.trim().replaceFirst(RegExp(r':+$'), '');
    final m = _location.firstMatch(text);
    if (m != null && m.group(1)!.isNotEmpty) {
      return (
        path: m.group(1)!,
        line: int.tryParse(m.group(2)!),
        column: m.group(3) == null ? null : int.tryParse(m.group(3)!),
      );
    }
    final h = _hashLine.firstMatch(text);
    if (h != null && h.group(1)!.isNotEmpty) {
      return (path: h.group(1)!, line: int.tryParse(h.group(2)!), column: null);
    }
    return (path: text, line: null, column: null);
  }

  static bool isAbsolute(String path) => path.startsWith('/');

  /// True for `~` and `~/...`: the only tilde forms expanded (`~user` is not).
  static bool usesHome(String path) => path == '~' || path.startsWith('~/');

  /// Collapses `//`, `.` and `..` in an absolute or relative path.
  static String normalize(String path) {
    final absolute = isAbsolute(path);
    final out = <String>[];
    for (final part in path.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (out.isNotEmpty && out.last != '..') {
          out.removeLast();
        } else if (!absolute) {
          out.add('..');
        }
        continue;
      }
      out.add(part);
    }
    final joined = out.join('/');
    return absolute ? '/$joined' : (joined.isEmpty ? '.' : joined);
  }

  /// Absolute, normalised form of [raw]: `~` expands to [home], a relative path
  /// is taken against [cwd] (or [home] when there is no cwd). Returns null when
  /// a base is needed and missing.
  static String? resolve(String raw, {String? cwd, String? home}) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (isAbsolute(text)) return normalize(text);
    if (usesHome(text)) {
      if (home == null) return null;
      return normalize('$home/${text.substring(1)}');
    }
    final base = cwd != null && isAbsolute(cwd) ? cwd : home;
    if (base == null) return null;
    return normalize('$base/$text');
  }

  static String join(String dir, String name) =>
      dir == '/' ? '/$name' : '${dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir}/$name';

  static String basename(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty);
    return parts.isEmpty ? '/' : parts.last;
  }

  /// The containing directory; `/` is its own parent.
  static String parent(String path) {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length <= 1) return '/';
    return '/${parts.sublist(0, parts.length - 1).join('/')}';
  }

  /// `/home/a/b` -> [(`/`, '/'), (`/home`, 'home'), (`/home/a`, 'a'), ...].
  static List<({String path, String label})> breadcrumbs(String path) {
    final out = <({String path, String label})>[(path: '/', label: '/')];
    var acc = '';
    for (final part in path.split('/').where((s) => s.isNotEmpty)) {
      acc = '$acc/$part';
      out.add((path: acc, label: part));
    }
    return out;
  }

  /// Names compared the way a person sorts them: case-insensitive, runs of
  /// digits by value (`file2` before `file10`).
  static int naturalCompare(String a, String b) {
    final c = naturalCompareFolded(a.toLowerCase(), b.toLowerCase());
    return c != 0 ? c : a.compareTo(b);
  }

  /// [naturalCompare] for names already lowercased by the caller (sorting a
  /// big directory lowercases each name once instead of once per comparison).
  static int naturalCompareFolded(String x, String y) {
    var i = 0;
    var j = 0;
    while (i < x.length && j < y.length) {
      final cx = x.codeUnitAt(i);
      final cy = y.codeUnitAt(j);
      final dx = cx >= 0x30 && cx <= 0x39;
      final dy = cy >= 0x30 && cy <= 0x39;
      if (dx && dy) {
        var ei = i;
        while (ei < x.length && _isDigit(x.codeUnitAt(ei))) {
          ei++;
        }
        var ej = j;
        while (ej < y.length && _isDigit(y.codeUnitAt(ej))) {
          ej++;
        }
        final nx = _stripZeros(x.substring(i, ei));
        final ny = _stripZeros(y.substring(j, ej));
        if (nx.length != ny.length) return nx.length - ny.length;
        final c = nx.compareTo(ny);
        if (c != 0) return c;
        i = ei;
        j = ej;
        continue;
      }
      if (cx != cy) return cx - cy;
      i++;
      j++;
    }
    return (x.length - i) - (y.length - j);
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static String _stripZeros(String s) {
    var k = 0;
    while (k < s.length - 1 && s.codeUnitAt(k) == 0x30) {
      k++;
    }
    return s.substring(k);
  }
}

