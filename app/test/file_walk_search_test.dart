import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/data/services/file_walk_search.dart';

// The search a machine without `fs.search` gets: a breadth-first walk over the
// listing, with limits that say so when they stop it.

final _now = DateTime.utc(2026, 11, 28, 12);

RemoteEntry _f(String dir, String name, {DateTime? modified, RemoteEntryKind kind = RemoteEntryKind.file}) {
  return RemoteEntry(
    name: name,
    path: '$dir/$name',
    kind: kind,
    resolvedKind: kind,
    size: 1,
    modified: modified ?? _now,
  );
}

RemoteEntry _d(String dir, String name) => _f(dir, name, kind: RemoteEntryKind.dir);

/// A tree as listings: folder path -> its entries. A folder that is not a key
/// is "not found"; one in [denied] is refused.
class _Tree {
  _Tree(this.dirs, {this.denied = const {}});

  final Map<String, List<RemoteEntry>> dirs;
  final Set<String> denied;
  final listed = <String>[];
  void Function(String path)? onList;

  Future<List<RemoteEntry>> list(String path) async {
    listed.add(path);
    onList?.call(path);
    if (denied.contains(path)) throw RemoteFileException(RemoteFileErrorKind.permission, 'denied', path: path);
    final entries = dirs[path];
    if (entries == null) throw RemoteFileException(RemoteFileErrorKind.notFound, 'gone', path: path);
    return entries;
  }
}

Future<(List<RemoteEntry>, FileSearchDone)> _run(
  _Tree tree,
  FileSearchSpec spec, {
  DateTime Function()? now,
  int maxScanned = walkSearchMaxScanned,
  Duration budget = walkSearchBudget,
}) async {
  final events = await walkSearch(
    tree.list,
    spec,
    now: now ?? () => _now,
    maxScanned: maxScanned,
    budget: budget,
  ).toList();
  final done = events.last as FileSearchDone;
  expect(events.whereType<FileSearchDone>(), hasLength(1), reason: 'one end, last');
  return ([for (final b in events.whereType<FileSearchBatch>()) ...b.entries], done);
}

void main() {
  test('shallow matches come before deep ones, whatever order the listings give', () async {
    final tree = _Tree({
      '/r': [_d('/r', 'a'), _f('/r', 'top-x.txt'), _d('/r', 'b')],
      '/r/a': [_d('/r/a', 'deep'), _f('/r/a', 'a-x.txt')],
      '/r/b': [_f('/r/b', 'b-x.txt')],
      '/r/a/deep': [_f('/r/a/deep', 'deep-x.txt')],
    });

    final (found, done) = await _run(tree, const FileSearchSpec(root: '/r', query: 'x'));

    expect(found.map((e) => e.name), ['top-x.txt', 'a-x.txt', 'b-x.txt', 'deep-x.txt']);
    expect(done.truncated, isFalse);
    expect(done.scanned, 7);
  });

  test('names match as a case-insensitive part of the name, not the path', () async {
    final tree = _Tree({
      '/r': [_d('/r', 'Shots'), _f('/r', 'readme.md')],
      '/r/Shots': [_f('/r/Shots', 'a.png'), _f('/r/Shots', 'MySHOT.png')],
    });

    final (found, _) = await _run(tree, const FileSearchSpec(root: '/r', query: 'sHoT'));

    expect(found.map((e) => e.path), ['/r/Shots', '/r/Shots/MySHOT.png'], reason: 'the folder\u2019s name matches too');
  });

  test('kind narrows to files or folders', () async {
    final tree = _Tree({
      '/r': [_d('/r', 'x-dir'), _f('/r', 'x-file')],
      '/r/x-dir': [],
    });

    expect(
      (await _run(tree, const FileSearchSpec(root: '/r', query: 'x', kind: FileSearchKind.dir))).$1.map((e) => e.name),
      ['x-dir'],
    );
    expect(
      (await _run(tree, const FileSearchSpec(root: '/r', query: 'x', kind: FileSearchKind.file))).$1.map((e) => e.name),
      ['x-file'],
    );
  });

  test('an empty query with a time window finds what changed lately, and entries with no time never match', () async {
    final tree = _Tree({
      '/r': [
        _f('/r', 'new.txt', modified: _now.subtract(const Duration(minutes: 5))),
        _f('/r', 'old.txt', modified: _now.subtract(const Duration(hours: 3))),
        const RemoteEntry(
          name: 'timeless',
          path: '/r/timeless',
          kind: RemoteEntryKind.file,
          resolvedKind: RemoteEntryKind.file,
        ),
      ],
    });

    final (found, _) = await _run(tree, const FileSearchSpec(root: '/r', modifiedWithin: Duration(hours: 1)));

    expect(found.map((e) => e.name), ['new.txt']);
  });

  test('ignored folders are neither entered nor reported, but a FILE with the same name is a file', () async {
    final tree = _Tree({
      '/r': [_d('/r', 'node_modules'), _d('/r', '.git'), _f('/r', 'build'), _d('/r', 'src')],
      '/r/src': [_f('/r/src', 'build.rs')],
    });

    final (found, _) = await _run(tree, const FileSearchSpec(root: '/r', query: 'build'));

    expect(found.map((e) => e.path), ['/r/build', '/r/src/build.rs']);
    expect(tree.listed, ['/r', '/r/src'], reason: 'node_modules and .git are never listed');
  });

  test('hidden names are skipped unless asked for, and passing no ignore names searches everything', () async {
    final tree = _Tree({
      '/r': [_f('/r', '.secret-x'), _d('/r', '.dot'), _d('/r', 'node_modules')],
      '/r/.dot': [_f('/r/.dot', 'in-dot-x')],
      '/r/node_modules': [_f('/r/node_modules', 'pkg-x')],
    });

    expect((await _run(tree, const FileSearchSpec(root: '/r', query: 'x'))).$1, isEmpty);
    final (found, _) = await _run(tree, const FileSearchSpec(root: '/r', query: 'x', hidden: true, ignore: []));
    expect(found.map((e) => e.name), ['.secret-x', 'in-dot-x', 'pkg-x']);
  });

  test('a link is reported but never entered, so a loop cannot trap the walk', () async {
    final tree = _Tree({
      '/r': [
        const RemoteEntry(
          name: 'loop-x',
          path: '/r/loop-x',
          kind: RemoteEntryKind.link,
          resolvedKind: RemoteEntryKind.dir,
        ),
        _d('/r', 'real'),
      ],
      '/r/real': [_f('/r/real', 'file-x')],
    });

    final (found, done) = await _run(tree, const FileSearchSpec(root: '/r', query: 'x'));

    expect(found.map((e) => e.name), ['loop-x', 'file-x']);
    expect(tree.listed, ['/r', '/r/real']);
    expect(done.truncated, isFalse);
  });

  test('depth counts as the host does: the entries of the root are depth 1', () async {
    final tree = _Tree({
      '/r': [_d('/r', 'a'), _f('/r', 'top-x')],
      '/r/a': [_d('/r/a', 'b'), _f('/r/a', 'one-x')],
      '/r/a/b': [_f('/r/a/b', 'two-x')],
    });

    List<String> names((List<RemoteEntry>, FileSearchDone) r) => [for (final e in r.$1) e.name];
    expect(names(await _run(tree, const FileSearchSpec(root: '/r', query: 'x', maxDepth: 1))), ['top-x']);
    expect(names(await _run(tree, const FileSearchSpec(root: '/r', query: 'x', maxDepth: 2))), ['top-x', 'one-x']);
    expect(names(await _run(tree, const FileSearchSpec(root: '/r', query: 'x', maxDepth: 3))), hasLength(3));
  });

  test('the result cap stops the walk and says there may be more', () async {
    final tree = _Tree({
      '/r': [for (var i = 0; i < 10; i++) _f('/r', 'x$i'), _d('/r', 'later')],
      '/r/later': [_f('/r/later', 'x-never')],
    });

    final (found, done) = await _run(tree, const FileSearchSpec(root: '/r', query: 'x', maxResults: 4));

    expect(found, hasLength(4));
    expect(done.truncated, isTrue);
    expect(tree.listed, ['/r'], reason: 'it did not go on to the next folder');
  });

  test('looking at 3,000 entries is the limit: it stops and says so, with how far it got', () async {
    final tree = _Tree({
      '/r': [for (var i = 0; i < 5; i++) _d('/r', 'd$i')],
      for (var i = 0; i < 5; i++) '/r/d$i': [for (var j = 0; j < 1000; j++) _f('/r/d$i', 'f$j')],
    });

    final (found, done) = await _run(tree, const FileSearchSpec(root: '/r', query: 'f9'));

    expect(done.truncated, isTrue);
    expect(done.scanned, walkSearchMaxScanned);
    expect(found, isNotEmpty, reason: 'what it found before the limit is still shown');
    expect(tree.listed, hasLength(4), reason: 'the root and three folders, then the limit');
  });

  test('the time budget stops it between folders, and says so', () async {
    var t = _now;
    final tree = _Tree({
      '/r': [_d('/r', 'a'), _d('/r', 'b'), _d('/r', 'c')],
      '/r/a': [_f('/r/a', 'x1')],
      '/r/b': [_f('/r/b', 'x2')],
      '/r/c': [_f('/r/c', 'x3')],
    });
    tree.onList = (_) => t = t.add(const Duration(seconds: 1));

    final (found, done) = await _run(
      tree,
      const FileSearchSpec(root: '/r', query: 'x'),
      now: () => t,
      budget: const Duration(milliseconds: 2500),
    );

    expect(done.truncated, isTrue);
    expect(tree.listed, ['/r', '/r/a', '/r/b'], reason: 'the third folder began after 2.5 s: not entered');
    expect(found.map((e) => e.name), ['x1', 'x2']);
  });

  test('a folder that cannot be read is skipped and counted; the walk goes on', () async {
    final tree = _Tree(
      {
        '/r': [_d('/r', 'locked'), _d('/r', 'gone'), _d('/r', 'open')],
        '/r/open': [_f('/r/open', 'x-ok')],
      },
      denied: {'/r/locked'},
    );

    final (found, done) = await _run(tree, const FileSearchSpec(root: '/r', query: 'x'));

    expect(found.map((e) => e.name), ['x-ok']);
    expect(done.skippedDirs, 2, reason: 'one refused, one gone meanwhile');
    expect(done.truncated, isFalse);
  });

  test('the root failing fails the search; so does a lost connection further down', () async {
    final noRoot = _Tree({});
    await expectLater(
      walkSearch(
        noRoot.list,
        const FileSearchSpec(root: '/r', query: 'x'),
        now: () => _now,
      ).toList(),
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)),
    );

    final dropped = _Tree({
      '/r': [_d('/r', 'a')],
    });
    dropped.onList = (path) {
      if (path == '/r/a') throw RemoteFileException(RemoteFileErrorKind.network, 'lost', path: path);
    };
    await expectLater(
      walkSearch(
        dropped.list,
        const FileSearchSpec(root: '/r', query: 'x'),
        now: () => _now,
      ).toList(),
      throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.network)),
    );
  });

  test('matches go out in batches of at most 100, each as soon as its folder has been looked at', () async {
    final tree = _Tree({
      '/r': [_d('/r', 'a'), for (var i = 0; i < 250; i++) _f('/r', 'x$i')],
      '/r/a': [_f('/r/a', 'x-in-a')],
    });

    final events = await walkSearch(
      tree.list,
      const FileSearchSpec(root: '/r', query: 'x'),
      now: () => _now,
    ).toList();

    final sizes = [for (final b in events.whereType<FileSearchBatch>()) b.entries.length];
    expect(sizes, [100, 100, 50, 1]);
  });

  test('cancelling stops before the next folder is listed', () async {
    final tree = _Tree({
      '/r': [_d('/r', 'a'), _d('/r', 'b'), _f('/r', 'x')],
      '/r/a': [_f('/r/a', 'x1')],
      '/r/b': [_f('/r/b', 'x2')],
    });
    late final StreamSubscription<FileSearchEvent> sub;
    sub = walkSearch(
      tree.list,
      const FileSearchSpec(root: '/r', query: 'x'),
      now: () => _now,
    ).listen((_) {});
    tree.onList = (path) {
      if (path == '/r/a') sub.cancel();
    };

    await pumpEventQueue();

    expect(tree.listed, ['/r', '/r/a'], reason: 'b is never listed');
  });
}
