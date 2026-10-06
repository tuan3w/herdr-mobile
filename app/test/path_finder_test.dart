import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/path_finder.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

const _main = '/work/proj';

void _repo(FakeFs fs, List<String> names) => fs.addRepo(_main, names);

PathFinder _finder(FakeFs fs, {DateTime Function()? now, int maxWorktrees = 12, Duration? budget, int maxFolders = 400, Duration? search}) =>
    PathFinder(
      RemoteFiles(FakeTransport()..fs = fs),
      now: now,
      maxWorktrees: maxWorktrees,
      worktreeBudget: budget ?? const Duration(seconds: 3),
      searchBudget: search ?? const Duration(seconds: 2),
      maxFolders: maxFolders,
    );

Future<PathFindReport> _inWorktrees(PathFinder f, String rel, {String cwd = _main, SearchCancel? cancel}) =>
    f.inWorktrees([rel], cwd, cancel ?? SearchCancel());

void main() {
  group('worktrees', () {
    test('a file only in a sibling worktree is found there', () async {
      final fs = FakeFs();
      _repo(fs, ['open-profile', 'ux']);
      fs.addFile('/work/open-profile/docs/PROFILE.md', '# p');

      final r = await _inWorktrees(_finder(fs), 'docs/PROFILE.md');

      expect(r.candidates.map((c) => c.path), ['/work/open-profile/docs/PROFILE.md']);
      expect(r.candidates.single.rootName, 'open-profile');
      expect(r.candidates.single.relative, 'docs/PROFILE.md');
      expect(r.candidates.single.source, CandidateSource.worktree);
      expect(r.worktreesLooked, 2);
    });

    test('the same name in two worktrees: both, newest first', () async {
      final fs = FakeFs();
      _repo(fs, ['a', 'b', 'c']);
      fs.addFile('/work/a/x.md', '1', modified: DateTime.utc(2026, 5, 1));
      fs.addFile('/work/b/x.md', '2', modified: DateTime.utc(2026, 6, 1));

      final r = await _inWorktrees(_finder(fs), 'x.md');

      expect(r.candidates.map((c) => c.rootName), ['b', 'a']);
      expect(r.worktreesLooked, 3);
    });

    test('a cwd that is itself a worktree also looks in the main checkout', () async {
      final fs = FakeFs();
      _repo(fs, ['a', 'b']);
      fs.addFile('$_main/only-main.md', 'm');
      fs.addFile('/work/b/only-main.md', 'b', modified: DateTime.utc(2030));

      final r = await _inWorktrees(_finder(fs), 'only-main.md', cwd: '/work/a');

      expect(r.candidates.map((c) => c.root), ['/work/b', _main]);
      expect(r.worktreesLooked, 2, reason: 'main and b; never the folder it is already in');
      expect(fs.calls.where((c) => c == 'stat /work/a/only-main.md'), isEmpty);
    });

    test('a cwd inside the repository tries its own subfolder, then the root', () async {
      final fs = FakeFs()..addDir('$_main/app');
      _repo(fs, ['a']);
      fs.addFile('/work/a/app/lib/m.dart', 'x');
      fs.addFile('/work/a/lib/m.dart', 'y');

      final r = await _inWorktrees(_finder(fs), 'lib/m.dart', cwd: '$_main/app');

      expect(r.candidates.single.path, '/work/a/app/lib/m.dart', reason: 'the first place that exists in each worktree');
    });

    test('a path that climbs out of the checkout is never asked about', () async {
      final fs = FakeFs();
      _repo(fs, ['a']);
      fs.addFile('/work/secret.txt', 'x');

      final r = await _inWorktrees(_finder(fs), '../secret.txt');

      expect(r.candidates, isEmpty);
      expect(fs.calls.where((c) => c.contains('secret')), isEmpty);
    });

    test('malformed gitdir files and permission errors are ignored', () async {
      final fs = FakeFs();
      _repo(fs, ['good', 'locked', 'gone']);
      fs.addFile('$_main/.git/worktrees/junk/gitdir', 'not a path at all');
      fs.addFile('$_main/.git/worktrees/rel/gitdir', '../elsewhere/.git');
      fs.addFile('$_main/.git/worktrees/notgit/gitdir', '/work/notgit/other');
      fs.addFile('$_main/.git/worktrees/nul/gitdir', '/work/nul\u0000/.git');
      fs.addFile('$_main/.git/worktrees/empty/gitdir', '');
      fs.addDir('$_main/.git/worktrees/nofile');
      fs.addFile('/work/good/f.md', 'ok');
      fs.addFile('/work/locked/f.md', 'no');
      fs.deny.addAll(['/work/locked', '$_main/.git/worktrees/gone']);

      final r = await _inWorktrees(_finder(fs), 'f.md');

      expect(r.candidates.map((c) => c.rootName), ['good']);
      expect(fs.calls.where((c) => c.startsWith('stat ') && (c.contains('elsewhere') || c.contains('/work/notgit') || c.contains('/work/nul'))), isEmpty);
    });

    test('a denied .git/worktrees, or no repository at all, is just nothing', () async {
      final fs = FakeFs();
      _repo(fs, ['a']);
      fs.addFile('/work/a/f.md', 'x');
      fs.deny.add('$_main/.git/worktrees');
      expect((await _inWorktrees(_finder(fs), 'f.md')).candidates, isEmpty);

      final bare = FakeFs()..addDir('/work/plain');
      final r = await _inWorktrees(_finder(bare), 'f.md', cwd: '/work/plain');
      expect(r.candidates, isEmpty);
      expect(r.worktreesLooked, 0);
    });

    test('a submodule .git file lists no worktrees', () async {
      final fs = FakeFs()..addDir('$_main/.git/modules/sub');
      fs.addFile('$_main/sub/.git', 'gitdir: ../.git/modules/sub\n');
      fs.addFile('/work/a/f.md', 'x');

      final r = await _inWorktrees(_finder(fs), 'f.md', cwd: '$_main/sub');

      expect(r.candidates, isEmpty);
      expect(r.worktreesLooked, 0);
    });

    test('at most 12 worktrees are asked, and never more than 4 calls at once', () async {
      final fs = FakeFs()..latency = const Duration(milliseconds: 15);
      _repo(fs, [for (var i = 0; i < 30; i++) 'w$i']);
      fs.addFile('/work/w3/f.md', 'x');

      final r = await _inWorktrees(_finder(fs), 'f.md');

      expect(r.worktreesLooked, 12);
      expect(fs.calls.where((c) => c.startsWith('stat /work/') && c.endsWith('/f.md')).length, 12);
      expect(fs.maxInFlight, lessThanOrEqualTo(4));
      expect(fs.maxInFlight, greaterThan(1), reason: 'they do run side by side');
    });

    test('worktree lists are remembered for 60 s per folder, then read again', () async {
      final fs = FakeFs();
      _repo(fs, ['a']);
      var clock = DateTime.utc(2026, 1, 1);
      final f = _finder(fs, now: () => clock);

      await _inWorktrees(f, 'one.md');
      int reads() => fs.calls.where((c) => c.startsWith('list ') || c.contains('/gitdir@')).length;
      final first = reads();
      expect(first, greaterThan(0));

      await _inWorktrees(f, 'two.md');
      expect(reads(), first, reason: 'second tap inside the minute asks only for the file');

      await _inWorktrees(f, 'two.md', cwd: '/work/a');
      expect(reads(), greaterThan(first), reason: 'another folder is another list');

      final before = reads();
      clock = clock.add(const Duration(seconds: 61));
      await _inWorktrees(f, 'two.md');
      expect(reads(), greaterThan(before));
    });

    test('a run that was cut short or failed is not remembered', () async {
      final fs = FakeFs();
      _repo(fs, ['a']);
      fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'down');
      final f = _finder(fs);
      await _inWorktrees(f, 'one.md');

      fs.fail = null;
      fs.addFile('/work/a/one.md', 'x');
      final r = await _inWorktrees(f, 'one.md');
      expect(r.candidates, hasLength(1), reason: 'the outage was not cached as "no worktrees"');
    });

    test('the budget ends a search whose host stops answering', () async {
      final fs = FakeFs();
      _repo(fs, ['a', 'b']);
      fs.hang.add('/work/a');
      fs.addFile('/work/b/f.md', 'x');
      final f = _finder(fs, budget: const Duration(milliseconds: 150));
      final clock = Stopwatch()..start();

      final r = await _inWorktrees(f, 'f.md');

      expect(clock.elapsedMilliseconds, lessThan(1500));
      expect(r.candidates.single.rootName, 'b', reason: 'what answered in time still counts');
      expect(r.worktreesLooked, 1);
    });

    test('cancelled before it starts: no call at all; cancelled midway: no call after', () async {
      final fs = FakeFs();
      _repo(fs, ['a']);
      final early = SearchCancel()..cancel();
      await _inWorktrees(_finder(fs), 'f.md', cancel: early);
      expect(fs.calls, isEmpty);

      final slow = FakeFs()..latency = const Duration(milliseconds: 40);
      _repo(slow, [for (var i = 0; i < 8; i++) 'w$i']);
      final cancel = SearchCancel();
      final run = _inWorktrees(_finder(slow), 'f.md', cancel: cancel);
      await Future<void>.delayed(const Duration(milliseconds: 90));
      cancel.cancel();
      final r = await run;
      final atCancel = slow.calls.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(slow.calls.length, atCancel, reason: 'nothing is asked after the screen is gone');
      expect(r.candidates, isEmpty);
    });
  });

  group('search by name', () {
    test('finds a nested file, newest first, and says where the root is', () async {
      final fs = FakeFs()..addDir('/work/proj');
      fs.addFile('/work/proj/a/b/target.md', '1', modified: DateTime.utc(2026, 1, 1));
      fs.addFile('/work/proj/c/target.md', '2', modified: DateTime.utc(2026, 3, 1));

      final r = await _finder(fs).byName('target.md', '/work/proj', SearchCancel());

      expect(r.candidates.map((c) => c.relative), ['c/target.md', 'a/b/target.md']);
      expect(r.candidates.first.folder, 'c');
      expect(r.candidates.first.rootName, 'proj');
      expect(r.searched, isTrue);
    });

    test('skips node_modules, build, .git, .dart_tool, target, dist, hidden folders and links', () async {
      final fs = FakeFs()..addDir('/w');
      for (final d in ['node_modules', 'build', '.git', '.dart_tool', 'target', 'dist', '.hidden', '.venv']) {
        fs.addFile('/w/$d/t.md', 'x');
      }
      fs.addFile('/elsewhere/t.md', 'x');
      fs.addLink('/w/out', '/elsewhere');
      fs.addFile('/w/ok/t.md', 'x');

      final r = await _finder(fs).byName('t.md', '/w', SearchCancel());

      expect(r.candidates.map((c) => c.path), ['/w/ok/t.md']);
      expect(fs.calls.where((c) => c.contains('node_modules') || c.contains('.git') || c.contains('/out')), isEmpty);
    });

    test('goes three folders deep and no further', () async {
      final fs = FakeFs()..addDir('/w');
      fs.addFile('/w/a/b/c/deep.md', 'x');
      fs.addFile('/w/a/b/c/d/too-deep.md', 'x');

      final f = _finder(fs);
      expect((await f.byName('deep.md', '/w', SearchCancel())).candidates, hasLength(1));
      expect((await f.byName('too-deep.md', '/w', SearchCancel())).candidates, isEmpty);
    });

    test('lists at most the folder cap', () async {
      final fs = FakeFs()..addDir('/w');
      for (var i = 0; i < 50; i++) {
        fs.addDir('/w/d$i');
      }
      fs.addFile('/w/d49/lost.md', 'x');

      final r = await _finder(fs, maxFolders: 20).byName('lost.md', '/w', SearchCancel());

      expect(fs.calls.where((c) => c.startsWith('list ')).length, 20);
      expect(r.candidates, isEmpty);
    });

    test('never more than 4 folders listed at once', () async {
      final fs = FakeFs()..latency = const Duration(milliseconds: 10);
      for (var i = 0; i < 30; i++) {
        fs.addDir('/w/d$i');
      }
      await _finder(fs).byName('nope.md', '/w', SearchCancel());
      expect(fs.maxInFlight, lessThanOrEqualTo(4));
    });

    test('the budget and a cancel both stop it', () async {
      final fs = FakeFs()..addDir('/w/a');
      fs.hang.add('/w');
      final clock = Stopwatch()..start();
      final r = await _finder(fs, search: const Duration(milliseconds: 120)).byName('x.md', '/w', SearchCancel());
      expect(clock.elapsedMilliseconds, lessThan(1500));
      expect(r.candidates, isEmpty);

      final cancel = SearchCancel()..cancel();
      final before = fs.calls.length;
      await _finder(fs).byName('x.md', '/w', cancel);
      expect(fs.calls.length, before);
    });

    test('a folder with the name counts too; a broken link does not', () async {
      final fs = FakeFs()..addDir('/w/docs/notes');
      fs.addLink('/w/docs/ghost', 'nowhere');

      final f = _finder(fs);
      final dir = await f.byName('notes', '/w', SearchCancel());
      expect(dir.candidates.single.stat.isDirectory, isTrue);
      expect((await f.byName('ghost', '/w', SearchCancel())).candidates, isEmpty);
    });
  });

  test('isDistinctive: a long, uncommon name is; README.md, main.dart and short names are not', () {
    expect(PathFinder.isDistinctive('SESSION_PROFILE.md'), isTrue);
    expect(PathFinder.isDistinctive('files_navigation.dart'), isTrue);
    for (final common in ['README.md', 'main.dart', 'index.ts', 'pubspec.yaml', 'a.md', 'Makefile', 'notes.txt', '.env']) {
      expect(PathFinder.isDistinctive(common), isFalse, reason: common);
    }
  });

  test('PathFinder.of is one finder per machine', () {
    final a = RemoteFiles(FakeTransport());
    final b = RemoteFiles(FakeTransport());
    expect(identical(PathFinder.of(a), PathFinder.of(a)), isTrue);
    expect(identical(PathFinder.of(a), PathFinder.of(b)), isFalse);
  });

  test('reads of gitdir files stay short', () async {
    final fs = FakeFs();
    _repo(fs, ['a']);
    fs.addFile('$_main/.git/worktrees/a/gitdir', Uint8List(100000)..fillRange(0, 100000, 0x61));
    await _inWorktrees(_finder(fs), 'f.md');
    expect(fs.calls.where((c) => c.contains('/gitdir@')).every((c) => c.endsWith('+4096')), isTrue);
  });
}
