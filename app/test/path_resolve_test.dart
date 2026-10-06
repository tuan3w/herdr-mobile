import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/path_finder.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_widgets.dart';
import 'package:herdr_mobile/ui/features/files/files_navigation.dart';

import 'support/fake_fs.dart';
import 'support/files_support.dart';
import 'support/shot.dart' show loadAppFonts;

const _cwd = '/work/proj';

/// The session runs in /work/proj; two linked worktrees sit beside it.
FakeFs _fs() {
  final fs = FakeFs()..addDir('$_cwd/docs');
  fs.addRepo(_cwd, ['wt-old', 'wt-new']);
  return fs;
}

Future<void> _host(
  WidgetTester tester,
  MachineConnection machine,
  Future<void> Function(BuildContext context) onTap,
) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2.625
    ..devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      theme: AppTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(child: GestureDetector(onTap: () => onTap(context), child: const Text('go'))),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _settle(WidgetTester tester, [int steps = 6]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tap(WidgetTester tester, MachineConnection machine, String path, {String cwd = _cwd, int? line}) async {
  await _host(tester, machine, (c) => openRemoteFile(c, machine, path, cwd: cwd, line: line));
  await tester.tap(find.text('go'));
  await _settle(tester);
}

void main() {
  setUpAll(loadAppFonts);

  group('openRemoteFile finds what a subagent wrote in another worktree', () {
    testWidgets('a file only in a worktree opens, and says where it came from', (tester) async {
      final fs = _fs()..addFile('/work/wt-old/docs/OPEN_SESSION_PROFILE.txt', 'profile text');
      await _tap(tester, machineWithFiles(fs), 'docs/OPEN_SESSION_PROFILE.txt');

      expect(find.byType(FileViewerScreen), findsOneWidget);
      expect(find.text('profile text'), findsOneWidget);
      expect(find.text('From worktree wt-old'), findsOneWidget);
    });

    testWidgets('a path written in full under the session folder is found the same way', (tester) async {
      final fs = _fs()..addFile('/work/wt-new/docs/SESSION_NOTES.txt', 'notes');
      await _tap(tester, machineWithFiles(fs), '$_cwd/docs/SESSION_NOTES.txt:1');

      expect(find.text('notes'), findsOneWidget);
      expect(find.text('From worktree wt-new'), findsOneWidget);
    });

    testWidgets('the main checkout\'s own file wins and no worktree is asked', (tester) async {
      final fs = _fs()
        ..addFile('$_cwd/docs/PROFILE_NOTES.txt', 'main copy')
        ..addFile('/work/wt-new/docs/PROFILE_NOTES.txt', 'worktree copy');
      await _tap(tester, machineWithFiles(fs), 'docs/PROFILE_NOTES.txt');

      expect(find.text('main copy'), findsOneWidget);
      expect(find.textContaining('From worktree'), findsNothing);
      expect(fs.calls.where((c) => !c.startsWith('read ')), ['stat $_cwd/docs/PROFILE_NOTES.txt'], reason: 'the first attempt is the only lookup');
    });

    testWidgets('the same name in two worktrees offers a sheet, newest first; a tap opens that one', (tester) async {
      final fs = _fs()
        ..addFile('/work/wt-old/docs/SESSION_NOTES.txt', 'old copy', modified: DateTime.utc(2026, 5, 1))
        ..addFile('/work/wt-new/docs/SESSION_NOTES.txt', 'new copy', modified: DateTime.utc(2026, 6, 1));
      await _tap(tester, machineWithFiles(fs), 'docs/SESSION_NOTES.txt');

      expect(find.text('SESSION_NOTES.txt is in 2 places'), findsOneWidget);
      expect(find.text('docs/SESSION_NOTES.txt'), findsNWidgets(2));
      final newer = tester.getTopLeft(find.textContaining('wt-new ·')).dy;
      final older = tester.getTopLeft(find.textContaining('wt-old ·')).dy;
      expect(newer, lessThan(older), reason: 'newest first');
      expect(find.byType(FileViewerScreen), findsNothing, reason: 'nothing opens until one is picked');

      await tester.tap(find.textContaining('wt-old ·'));
      await _settle(tester);

      expect(find.text('old copy'), findsOneWidget);
      expect(find.text('From worktree wt-old'), findsOneWidget);
    });

    testWidgets('dismissing the sheet goes back to where the tap was', (tester) async {
      final fs = _fs()
        ..addFile('/work/wt-old/SESSION_NOTES.txt', 'a')
        ..addFile('/work/wt-new/SESSION_NOTES.txt', 'b');
      await _tap(tester, machineWithFiles(fs), 'SESSION_NOTES.txt');
      expect(find.textContaining('is in 2 places'), findsOneWidget);

      await tester.tapAt(const Offset(20, 40)); // the barrier
      await _settle(tester);

      expect(find.text('go'), findsOneWidget);
      expect(find.byType(FileResolvingPage), findsNothing);
    });

    testWidgets('nothing anywhere: says what it looked for and where, with Search for a plain name', (tester) async {
      final fs = _fs();
      await _tap(tester, machineWithFiles(fs), 'docs/README.md');

      expect(find.text('Not found'), findsOneWidget);
      expect(find.text("docs/README.md isn't in proj (also looked in 2 worktrees)"), findsOneWidget);
      expect(find.text('Search'), findsOneWidget, reason: 'README.md is too common to search for unasked');
      expect(find.byType(FileViewerScreen), findsNothing);
    });

    testWidgets('Search looks for the name below the session folder', (tester) async {
      final fs = _fs()..addFile('$_cwd/app/README.md', 'deep readme');
      await _tap(tester, machineWithFiles(fs), 'docs/README.md');

      await tester.tap(find.text('Search'));
      await _settle(tester);

      expect(find.text('deep readme'), findsOneWidget);
      expect(find.text('Found in app'), findsOneWidget);
    });

    testWidgets('a distinctive name is searched for at once; nothing found says so and offers no Search', (tester) async {
      final fs = _fs()..addFile('$_cwd/a/b/UNIQUE_REPORT.txt', 'report');
      final machine = machineWithFiles(fs);
      await _tap(tester, machine, 'UNIQUE_REPORT.txt');
      expect(find.text('report'), findsOneWidget);
      expect(find.text('Found in a/b'), findsOneWidget);

      await _tap(tester, machine, 'MISSING_REPORT.txt');
      expect(find.text("MISSING_REPORT.txt isn't in proj (also looked in 2 worktrees and searched by name)"), findsOneWidget);
      expect(find.text('Search'), findsNothing);
    });

    testWidgets('a long path is cut in the middle, keeping the file name', (tester) async {
      final machine = machineWithFiles(_fs());
      final long = 'packages/some/very/deep/folder/structure/that/keeps/going/and/going/NOT_THERE_AT_ALL.txt';
      await _tap(tester, machine, long);

      final message = tester.widget<Text>(find.textContaining("isn't in proj")).data!;
      expect(message, contains('…'));
      expect(message, contains('NOT_THERE_AT_ALL.txt isn\'t in proj'));
      expect(message.indexOf("isn't"), lessThan(80));
    });

    testWidgets('a path outside the session folder is not hunted for in worktrees', (tester) async {
      final fs = _fs()..addFile('/work/wt-old/x/OTHER_FILE.txt', 'x');
      await _tap(tester, machineWithFiles(fs), '/etc/OTHER_FILE.txt');

      expect(find.text("/etc/OTHER_FILE.txt isn't on this machine"), findsOneWidget);
      expect(fs.calls.where((c) => c.contains('worktrees')), isEmpty);
    });

    testWidgets('a worktree folder as the answer opens the browser', (tester) async {
      final fs = _fs()..addFile('/work/wt-old/generated/one.txt', 'x');
      await _tap(tester, machineWithFiles(fs), 'generated');

      expect(find.text('one.txt'), findsOneWidget);
      expect(find.text('From worktree wt-old'), findsOneWidget);
    });

    testWidgets('Back while it is looking stops the asking', (tester) async {
      final fs = _fs()
        ..latency = const Duration(milliseconds: 50)
        ..addFile('/work/wt-old/docs/LATE_FILE.txt', 'x');
      final machine = machineWithFiles(fs);
      await _host(tester, machine, (c) => openRemoteFile(c, machine, 'docs/LATE_FILE.txt', cwd: _cwd));
      await tester.tap(find.text('go'));
      await tester.pump(); // the route builds, the lookup starts
      await tester.pump(const Duration(milliseconds: 280));
      expect(fs.calls.any((c) => c.contains('worktrees')), isTrue, reason: 'it was in the worktree search');
      expect(find.text('Looking in other checkouts…'), findsOneWidget, reason: 'the skeleton says what the wait is for');

      await tester.tap(find.byTooltip('Back'));
      await tester.pump(const Duration(milliseconds: 50));
      final atBack = fs.calls.length;
      await _settle(tester, 20);

      expect(fs.calls.length, atBack);
      expect(find.text('go'), findsOneWidget);
    });
  });

  group('resolveRemotePath', () {
    test('the first attempt is unchanged: one stat, no search machinery', () async {
      final fs = _fs()..addFile('$_cwd/docs/a.txt', 'x');
      final found = await resolveRemotePath(machineWithFiles(fs), 'docs/a.txt:7', cwd: _cwd);

      expect(found, isA<PathFound>().having((f) => f.line, 'line', 7).having((f) => f.from, 'from', isNull));
      expect(fs.calls, ['stat $_cwd/docs/a.txt']);
    });

    test('several matches come back as choices, newest first', () async {
      final fs = _fs()
        ..addFile('/work/wt-old/z.txt', '1', modified: DateTime.utc(2026, 1, 1))
        ..addFile('/work/wt-new/z.txt', '2', modified: DateTime.utc(2026, 2, 1));
      final r = await resolveRemotePath(machineWithFiles(fs), 'z.txt', cwd: _cwd, line: 3);

      expect(r, isA<PathChoices>());
      r as PathChoices;
      expect(r.candidates.map((c) => c.rootName), ['wt-new', 'wt-old']);
      expect(r.line, 3);
    });

    test('not found throws a PathNotFound that a plain not-found handler still sees', () async {
      final fs = _fs();
      await expectLater(
        resolveRemotePath(machineWithFiles(fs), 'nope.txt', cwd: _cwd),
        throwsA(isA<PathNotFound>()
            .having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)
            .having((e) => e.canSearch, 'canSearch', isTrue)
            .having((e) => e.message, 'message', "nope.txt isn't in proj (also looked in 2 worktrees)")),
      );
    });

    test('a permission error on the first attempt is not turned into a search', () async {
      final fs = _fs()
        ..addFile('$_cwd/locked.txt', 'x')
        ..deny.add('$_cwd/locked.txt');
      await expectLater(
        resolveRemotePath(machineWithFiles(fs), 'locked.txt', cwd: _cwd),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.permission)),
      );
      expect(fs.calls.where((c) => c.contains('worktrees')), isEmpty);
    });

    test('pathNotFoundMessage and cutMiddle', () {
      expect(pathNotFoundMessage('a.md', folder: 'p'), "a.md isn't in p");
      expect(pathNotFoundMessage('a.md', folder: 'p', worktrees: 1), "a.md isn't in p (also looked in 1 worktree)");
      expect(pathNotFoundMessage('a.md', folder: 'p', searched: true), "a.md isn't in p (also searched by name)");
      expect(pathNotFoundMessage('a.md'), "a.md isn't on this machine");
      expect(cutMiddle('short'), 'short');
      final cut = cutMiddle('${'d' * 100}/file.txt', 30);
      expect(cut.length, 30);
      expect(cut, endsWith('/file.txt'));
      expect(cut, contains('…'));
    });
  });
}
