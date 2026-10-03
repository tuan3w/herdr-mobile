import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:herdr_mobile/data/models/remote_file.dart';

class FakeNode {
  FakeNode.dir({DateTime? modified})
      : isDir = true,
        bytes = Uint8List(0),
        linkTarget = null,
        modified = modified ?? DateTime.utc(2026, 5, 20, 9, 30);

  FakeNode.file(this.bytes, {DateTime? modified})
      : isDir = false,
        linkTarget = null,
        modified = modified ?? DateTime.utc(2026, 5, 20, 9, 30);

  FakeNode.link(this.linkTarget)
      : isDir = false,
        bytes = Uint8List(0),
        modified = DateTime.utc(2026, 5, 20, 9, 30);

  final bool isDir;
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

  /// `stat /a`, `list /a`, `read /a@0+524288`, `real /a`, in call order.
  final List<String> calls = [];

  void mkdirs(String path) {
    var acc = '';
    for (final part in path.split('/').where((s) => s.isNotEmpty)) {
      acc = '$acc/$part';
      nodes.putIfAbsent(acc, FakeNode.dir);
    }
  }

  void addDir(String path) => mkdirs(path);

  void addFile(String path, Object content, {DateTime? modified}) {
    mkdirs(RemotePath.parent(path));
    final bytes = content is Uint8List
        ? content
        : Uint8List.fromList(utf8.encode(content as String));
    nodes[path] = FakeNode.file(bytes, modified: modified);
  }

  void addLink(String path, String target) {
    mkdirs(RemotePath.parent(path));
    nodes[path] = FakeNode.link(target);
  }

  bool _denied(String path) =>
      deny.any((d) => path == d || path.startsWith(d.endsWith('/') ? d : '$d/'));

  Future<void> _enter(String call) async {
    calls.add(call);
    if (fail != null) throw fail!;
    await gate?.future;
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
      mode: node.isDir ? 0x41ED : 0x81A4,
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
        mode: n.isDir ? 0x41ED : 0x81A4,
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

  Future<String> realPath(String path) async {
    await _enter('real $path');
    if (path == '.') return home;
    return RemotePath.resolve(path, cwd: home, home: home) ?? path;
  }
}
