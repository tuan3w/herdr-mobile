import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:herdr_mobile/data/models/remote_file.dart';

class FakeNode {
  FakeNode.dir({DateTime? modified, int? mode})
      : isDir = true,
        bytes = Uint8List(0),
        linkTarget = null,
        mode = mode ?? 0x41ED,
        modified = modified ?? DateTime.utc(2026, 5, 20, 9, 30);

  FakeNode.file(this.bytes, {DateTime? modified, int? mode})
      : isDir = false,
        linkTarget = null,
        mode = mode ?? 0x81A4,
        modified = modified ?? DateTime.utc(2026, 5, 20, 9, 30);

  FakeNode.link(this.linkTarget)
      : isDir = false,
        bytes = Uint8List(0),
        mode = 0xA1FF,
        modified = DateTime.utc(2026, 5, 20, 9, 30);

  final bool isDir;

  /// Type and permission bits as SFTP reports them (0644 file, 0755 folder by
  /// default); a test may change it. `0x8000` is a regular file nobody may
  /// read.
  int mode;
  final Uint8List bytes;
  final String? linkTarget;
  final DateTime modified;
}

/// A scriptable in-memory remote file system for [FakeTransport].
///
/// Paths are absolute. [deny] makes a path (and everything under it) answer
/// "permission denied"; [gate] holds every operation until it completes (to
/// look at loading states); [fail] makes every operation throw.
class FakeFs {
  FakeFs({this.home = '/home/dev'}) {
    nodes['/'] = FakeNode.dir();
    mkdirs(home);
  }

  final String home;
  final Map<String, FakeNode> nodes = {};
  final Set<String> deny = {};
  Completer<void>? gate;
  Object? fail;

  /// Every call takes this long (and counts as in flight meanwhile).
  Duration? latency;

  /// Calls about these paths (and below) never answer.
  final Set<String> hang = {};

  /// Calls that have entered and not yet answered, and the most at once.
  int inFlight = 0;
  int maxInFlight = 0;

  /// `stat /a`, `list /a`, `read /a@0+524288`, `real /a`, in call order.
  final List<String> calls = [];

  void mkdirs(String path) {
    var acc = '';
    for (final part in path.split('/').where((s) => s.isNotEmpty)) {
      acc = '$acc/$part';
      nodes.putIfAbsent(acc, FakeNode.dir);
    }
  }

  void addDir(String path, {DateTime? modified}) {
    mkdirs(path);
    if (modified != null) nodes[path] = FakeNode.dir(modified: modified);
  }

  /// A git repository at [main] with linked worktrees at `<parent>/<name>`,
  /// laid out the way git does it: `.git/worktrees/<name>/gitdir` holds the
  /// path of `<wt>/.git`, which is a FILE `gitdir: <main>/.git/worktrees/<name>`.
  void addRepo(String main, List<String> names, {String parent = '/work'}) {
    addDir('$main/.git/worktrees');
    for (final name in names) {
      final wt = '$parent/$name';
      addFile('$main/.git/worktrees/$name/gitdir', '$wt/.git\n');
      addFile('$wt/.git', 'gitdir: $main/.git/worktrees/$name\n');
    }
  }

  void addFile(String path, Object content, {DateTime? modified, int? mode}) {
    mkdirs(RemotePath.parent(path));
    final bytes = content is Uint8List
        ? content
        : Uint8List.fromList(utf8.encode(content as String));
    nodes[path] = FakeNode.file(bytes, modified: modified, mode: mode);
  }

  /// A file the transport wrote: parent must exist, mode 0600.
  void writeFile(String path, Uint8List bytes, {DateTime? modified}) {
    if (nodes[RemotePath.parent(path)]?.isDir != true) _notFound(path);
    nodes[path] = FakeNode.file(bytes, modified: modified ?? DateTime.now().toUtc(), mode: 0x8180);
  }

  void addLink(String path, String target) {
    mkdirs(RemotePath.parent(path));
    nodes[path] = FakeNode.link(target);
  }

  bool _denied(String path) =>
      deny.any((d) => path == d || path.startsWith(d.endsWith('/') ? d : '$d/'));

  Future<void> _enter(String call) async {
    calls.add(call);
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (fail != null) throw fail!;
      await gate?.future;
      final path = call.substring(call.indexOf(' ') + 1).split('@').first;
      if (hang.any((h) => path == h || path.startsWith('$h/'))) await Completer<void>().future;
      if (latency != null) await Future<void>.delayed(latency!);
    } finally {
      inFlight--;
    }
  }

  /// [path] with links followed (the node it finally names).
  String _canonical(String path) {
    var p = path;
    for (var i = 0; i < 8; i++) {
      final target = nodes[p]?.linkTarget;
      if (target == null) return p;
      p = RemotePath.resolve(target, cwd: RemotePath.parent(p)) ?? p;
    }
    return p;
  }

  FakeNode? _follow(String path) {
    var node = nodes[path];
    for (var i = 0; i < 8 && node?.linkTarget != null; i++) {
      node = nodes[RemotePath.resolve(node!.linkTarget!, cwd: RemotePath.parent(path))];
    }
    return node?.linkTarget != null ? null : node;
  }

  RemoteEntryKind _kind(FakeNode n) => n.linkTarget != null
      ? RemoteEntryKind.link
      : n.isDir
          ? RemoteEntryKind.dir
          : RemoteEntryKind.file;

  Never _notFound(String path) =>
      throw RemoteFileException(RemoteFileErrorKind.notFound, 'No such file or directory', path: path);

  Future<RemoteStat> stat(String path) async {
    await _enter('stat $path');
    if (_denied(path)) {
      throw RemoteFileException(RemoteFileErrorKind.permission, 'Permission denied', path: path);
    }
    final node = _follow(path);
    if (node == null) _notFound(path);
    return RemoteStat(
      path: path,
      kind: node.isDir ? RemoteEntryKind.dir : RemoteEntryKind.file,
      size: node.isDir ? 4096 : node.bytes.length,
      modified: node.modified,
      mode: node.mode,
    );
  }

  Future<List<RemoteEntry>> list(String path) async {
    await _enter('list $path');
    if (_denied(path)) {
      throw RemoteFileException(RemoteFileErrorKind.permission, 'Permission denied', path: path);
    }
    final dir = _follow(path);
    if (dir == null) _notFound(path);
    if (!dir.isDir) {
      throw RemoteFileException(RemoteFileErrorKind.notADirectory, 'Not a folder', path: path);
    }
    // Listing a link lists its target; the entries keep the path asked for.
    final real = _canonical(path);
    final prefix = real == '/' ? '/' : '$real/';
    final out = <RemoteEntry>[];
    for (final MapEntry(key: p, value: n) in nodes.entries) {
      if (p == real || !p.startsWith(prefix) || p.substring(prefix.length).contains('/')) continue;
      final target = _follow(p);
      final name = p.substring(prefix.length);
      out.add(RemoteEntry(
        name: name,
        path: RemotePath.join(path, name),
        kind: _kind(n),
        resolvedKind: n.linkTarget == null
            ? _kind(n)
            : target == null
                ? null
                : target.isDir
                    ? RemoteEntryKind.dir
                    : RemoteEntryKind.file,
        size: n.isDir ? 4096 : (target ?? n).bytes.length,
        modified: n.modified,
        mode: n.mode,
        linkTarget: n.linkTarget,
      ));
    }
    return out;
  }

  Future<Uint8List> read(String path, int offset, int length) async {
    final n = length.clamp(0, remoteReadCap);
    await _enter('read $path@$offset+$n');
    if (_denied(path)) {
      throw RemoteFileException(RemoteFileErrorKind.permission, 'Permission denied', path: path);
    }
    final node = _follow(path);
    if (node == null) _notFound(path);
    if (node.isDir) {
      throw RemoteFileException(RemoteFileErrorKind.notAFile, 'Is a folder', path: path);
    }
    if (offset >= node.bytes.length) return Uint8List(0);
    final end = (offset + n).clamp(0, node.bytes.length);
    return Uint8List.sublistView(node.bytes, offset, end);
  }

  /// `mkdir -p` with mode 0700; a file in the way is not a folder.
  Future<void> makeDirs(String path) async {
    await _enter('mkdirs $path');
    if (_denied(path)) {
      throw RemoteFileException(RemoteFileErrorKind.permission, 'Permission denied', path: path);
    }
    var acc = '';
    for (final part in path.split('/').where((s) => s.isNotEmpty)) {
      acc = '$acc/$part';
      final have = nodes[acc];
      if (have == null) {
        nodes[acc] = FakeNode.dir(modified: DateTime.now().toUtc(), mode: 0x41C0);
      } else if (!have.isDir) {
        throw RemoteFileException(RemoteFileErrorKind.notADirectory, 'Not a folder', path: acc);
      }
    }
  }

  /// Deletes a file or link; a folder is refused.
  Future<void> remove(String path) async {
    await _enter('rm $path');
    if (_denied(path)) {
      throw RemoteFileException(RemoteFileErrorKind.permission, 'Permission denied', path: path);
    }
    final node = nodes[path];
    if (node == null) _notFound(path);
    if (node.isDir) {
      throw RemoteFileException(RemoteFileErrorKind.notAFile, 'Is a folder', path: path);
    }
    nodes.remove(path);
  }

  Future<String> realPath(String path) async {
    await _enter('real $path');
    if (path == '.') return home;
    return RemotePath.resolve(path, cwd: home, home: home) ?? path;
  }
}
