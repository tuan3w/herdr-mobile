import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/files/code_view.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_view_model.dart';
import 'package:herdr_mobile/ui/features/files/file_listing.dart';
import 'package:herdr_mobile/ui/features/files/file_row.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_view_model.dart';
import 'package:herdr_mobile/ui/features/files/file_widgets.dart';
import 'package:herdr_mobile/ui/features/files/files_navigation.dart';
import 'package:herdr_mobile/ui/features/files/middle_ellipsis.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/files_support.dart';
import 'support/shot.dart' show loadAppFonts;

const _home = '/home/dev';
const _root = '$_home/herdr-mobile';

/// Counts what the navigator does, so a test can say "nothing was pushed".
class _Routes extends NavigatorObserver {
  var pushes = 0;
  var depth = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    depth++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => depth--;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => depth--;
}

Future<void> _pump(WidgetTester tester, Widget home, {_Routes? routes, Size size = const Size(412, 892)}) async {
  tester.view
    ..physicalSize = size * 2.625
    ..devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(key: UniqueKey(), theme: AppTheme.light(), navigatorObservers: [?routes], home: home),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// A button that runs [onTap] with a context under the navigator.
Widget _host(Future<void> Function(BuildContext context) onTap) => Scaffold(
  body: Builder(
    builder: (context) => Center(
      child: GestureDetector(onTap: () => onTap(context), child: const Text('go')),
    ),
  ),
);

FileBrowserScreen _browser(
  FakeFs fs,
  String path, {
  FileBrowserSession? session,
  DateTime Function()? clock,
  ThumbLoader? thumbs,
}) => FileBrowserScreen(machine: machineWithFiles(fs), path: path, session: session, clock: clock, thumbs: thumbs);

List<String> _names(WidgetTester tester) => [
  for (final r in tester.widgetList<FileRow>(find.byType(FileRow))) r.entry.name,
];

final _now = DateTime.utc(2026, 5, 20, 12);

/// A folder of things changed at known moments before [_now].
FakeFs _recentFs() {
  final fs = FakeFs();
  const dir = '$_home/w';
  void file(String name, Duration ago, [String content = 'x']) =>
      fs.addFile('$dir/$name', content, modified: _now.subtract(ago));
  file('fresh.dart', const Duration(minutes: 3), 'x' * 50);
  file('big.log', const Duration(minutes: 5), 'x' * 100);
  file('edge.dart', const Duration(minutes: 59));
  file('exact.txt', const Duration(minutes: 60));
  file('stale.dart', const Duration(minutes: 61));
  file('old.md', const Duration(days: 2));
  fs.nodes['$dir/lib'] = FakeNode.dir(modified: _now.subtract(const Duration(minutes: 10)));
  fs.nodes['$dir/docs'] = FakeNode.dir(modified: _now.subtract(const Duration(days: 3)));
  return fs;
}

void main() {
  setUpAll(loadAppFonts);

  group('breadcrumbs and the stack', () {
    Future<void> tapRow(WidgetTester tester, String name) async {
      await tester.scrollUntilVisible(
        find.text(name),
        200,
        scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
      );
      await tester.tap(find.text(name));
      await _settle(tester);
    }

    int lists(FakeFs fs) => fs.calls.where((c) => c.startsWith('list ')).length;

    testWidgets('a breadcrumb pops to the folder already on the stack: nothing is pushed, nothing is read again', (
      tester,
    ) async {
      final fs = projectFs();
      final routes = _Routes();
      final session = FileBrowserSession();
      await _pump(tester, _browser(fs, _root, session: session), routes: routes);
      await _settle(tester);
      for (final name in ['app', 'lib', 'ui']) {
        await tapRow(tester, name);
      }
      expect(session.paths, [_root, '$_root/app', '$_root/app/lib', '$_root/app/lib/ui']);
      final pushed = routes.pushes;
      final read = lists(fs);

      await tester.tap(find.text('herdr-mobile'));
      await _settle(tester);

      expect(session.paths, [_root], reason: 'the stack went back to the ancestor');
      expect(routes.pushes, pushed, reason: 'a breadcrumb never pushes');
      expect(routes.depth, 1);
      expect(lists(fs), read, reason: 'the folder was still there, listed');
      expect(find.text('AGENTS.md'), findsOneWidget);
    });

    testWidgets('Back goes up one level without reading the folder above again', (tester) async {
      final fs = projectFs();
      final session = FileBrowserSession();
      await _pump(tester, _browser(fs, _root, session: session));
      await _settle(tester);
      await tapRow(tester, 'docs');
      final read = lists(fs);

      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);

      expect(session.paths, [_root]);
      expect(lists(fs), read);
      expect(find.text('AGENTS.md'), findsOneWidget);
    });

    testWidgets('a breadcrumb above where the session began points the first browser at it in place', (tester) async {
      final fs = projectFs();
      final routes = _Routes();
      final session = FileBrowserSession();
      await _pump(tester, _browser(fs, '$_root/app/lib', session: session), routes: routes);
      await _settle(tester);
      expect(find.text('ui'), findsOneWidget);
      final pushed = routes.pushes;

      await tester.tap(find.text('~'));
      await _settle(tester);

      expect(routes.pushes, pushed, reason: 'replaced in place, not pushed');
      expect(session.paths, [_home]);
      expect(find.text('herdr-mobile'), findsWidgets);
      expect(find.text('ui'), findsNothing);
      expect(fs.calls, contains('list $_home'));
    });

    testWidgets('the stack never grows past the depth of the folder, whatever the walk', (tester) async {
      final fs = projectFs();
      final routes = _Routes();
      final session = FileBrowserSession();
      await _pump(tester, _browser(fs, _root, session: session), routes: routes);
      await _settle(tester);

      void check(String where) {
        final here = session.paths.last;
        expect(
          session.paths.length,
          lessThanOrEqualTo(RemotePath.breadcrumbs(here).length),
          reason: '$where: ${session.paths} deeper than $here',
        );
        expect(routes.depth, session.paths.length, reason: where);
      }

      for (final name in ['app', 'lib', 'ui']) {
        await tapRow(tester, name);
      }
      check('down');
      await tester.tap(find.text('app'));
      await _settle(tester);
      check('up to app');
      await tapRow(tester, 'lib');
      await tapRow(tester, 'ui');
      check('down again');
      await tester.tap(find.text('~'));
      await _settle(tester);
      check('home, above the start');
      await tapRow(tester, 'herdr-mobile');
      await tapRow(tester, 'docs');
      check('and down');
      await tester.tap(find.text('/'));
      await _settle(tester);
      check('the root');
      expect(session.paths, ['/']);
    });

    testWidgets('a picker keeps handing its answer down the stack after a breadcrumb popped part of it', (
      tester,
    ) async {
      final fs = projectFs();
      String? chosen;
      final machine = machineWithFiles(fs);
      await _pump(
        tester,
        _host((context) async => chosen = await pickRemoteDirectory(context, machine, startDir: '$_root/app/lib')),
      );
      await tester.tap(find.text('go'));
      await _settle(tester);
      await tester.tap(find.text('ui'));
      await _settle(tester);
      await tester.tap(find.text('app'));
      await _settle(tester);
      expect(chosen, isNull, reason: 'a breadcrumb is not a choice');

      await tester.tap(find.text('Choose this folder'));
      await _settle(tester);

      expect(chosen, '$_root/app');
    });
  });

  group('what you chose stays', () {
    testWidgets('hidden files stay on down the levels, and a change below is there on the way back', (tester) async {
      final fs = projectFs()..addFile('$_root/docs/.notes', 'x');
      await _pump(tester, _browser(fs, _root, session: FileBrowserSession()));
      await _settle(tester);

      await tester.tap(find.byTooltip('Show hidden files'));
      await _settle(tester);
      await tester.tap(find.text('docs'));
      await _settle(tester);

      expect(find.byTooltip('Hide hidden files'), findsOneWidget, reason: 'the choice went down with the push');
      expect(find.text('.notes'), findsOneWidget);

      await tester.tap(find.byTooltip('Hide hidden files'));
      await _settle(tester);
      expect(find.text('.notes'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);
      expect(find.byTooltip('Show hidden files'), findsOneWidget, reason: 'and back up');
      expect(find.text('.gitignore'), findsNothing);
    });

    testWidgets('the sort and the recent filter are shared the same way', (tester) async {
      final fs = _recentFs()..addDir('$_home/w/lib/sub');
      final session = FileBrowserSession();
      await _pump(tester, _browser(fs, '$_home/w', session: session, clock: () => _now));
      await _settle(tester);
      await tester.tap(find.text('Changed in the last hour'));
      await _settle(tester);

      await tester.tap(find.text('lib'));
      await _settle(tester);

      expect(session.options.recentOnly, isTrue);
      expect(session.options.sort, FileSort.modified);
      expect(find.text('Nothing changed in the last hour'), findsOneWidget, reason: 'lib/sub is 2.5 hours old');
      expect(find.byTooltip('Back'), findsOneWidget);
    });
  });

  group('opening is immediate', () {
    testWidgets(
      'Browse files puts the screen up at once, the skeleton comes after a moment, a second tap does nothing',
      (tester) async {
        final fs = projectFs()..gate = Completer<void>();
        final routes = _Routes();
        final machine = machineWithFiles(fs);
        // Two asks in the same moment (a double tap, a hotkey and a tap): one screen.
        await _pump(
          tester,
          _host((c) async {
            unawaited(openFileBrowser(c, machine, startDir: _root));
            await openFileBrowser(c, machine, startDir: _root);
          }),
          routes: routes,
        );
        final before = routes.pushes;

        await tester.tap(find.text('go'));
        await tester.pump();
        await tester.pump();

        expect(find.byType(FileBrowserScreen), findsOneWidget, reason: 'on screen before the host answered a thing');
        expect(routes.pushes, before + 1, reason: 'the second tap was ignored');
        expect(find.text('AGENTS.md'), findsNothing, reason: 'the host has not answered yet');
        expect(find.byType(Skeleton), findsNothing, reason: 'no placeholder inside the first 120 ms');

        await tester.pump(const Duration(milliseconds: 60));
        expect(find.byType(Skeleton), findsNothing);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(Skeleton), findsOneWidget, reason: 'a slow link shows its placeholder');

        fs.gate!.complete();
        await _settle(tester);
        expect(find.byType(Skeleton), findsNothing);
        expect(find.text('AGENTS.md'), findsOneWidget);
        expect(routes.pushes, before + 1);
      },
    );

    testWidgets('a link that answers at once never flashes a skeleton', (tester) async {
      final machine = machineWithFiles(projectFs());
      await _pump(tester, _host((c) => openFileBrowser(c, machine, startDir: _root)));

      await tester.tap(find.text('go'));
      var skeleton = false;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        skeleton |= find.byType(Skeleton).evaluate().isNotEmpty;
      }

      expect(skeleton, isFalse);
      expect(find.text('AGENTS.md'), findsOneWidget);
    });

    testWidgets(
      'with no start folder the browser opens at the login directory, and the title is Files until it is known',
      (tester) async {
        final fs = projectFs()..gate = Completer<void>();
        final machine = machineWithFiles(fs);
        await _pump(tester, _host((c) => openFileBrowser(c, machine)));

        await tester.tap(find.text('go'));
        await tester.pump();
        await tester.pump();
        expect(find.text('Files'), findsWidgets);

        fs.gate!.complete();
        await _settle(tester);
        expect(find.text('herdr-mobile'), findsWidgets);
        expect(find.text('dev'), findsWidgets);
      },
    );

    testWidgets('a path tapped in the output is on screen at once; a double tap opens one screen', (tester) async {
      final fs = projectFs()..gate = Completer<void>();
      final routes = _Routes();
      final machine = machineWithFiles(fs);
      // Two asks in the same moment (a double tap, a hotkey and a tap): one screen.
      await _pump(
        tester,
        _host((c) async {
          unawaited(openRemoteFile(c, machine, '$_root/pubspec.yaml'));
          await openRemoteFile(c, machine, '$_root/pubspec.yaml');
        }),
        routes: routes,
      );
      final before = routes.pushes;

      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump();

      expect(routes.pushes, before + 1);
      expect(find.byType(FileResolvingPage), findsOneWidget);
      expect(find.text('pubspec.yaml'), findsOneWidget, reason: 'the name is in the header while the host is asked');
      expect(find.byType(FileViewerScreen), findsNothing);

      fs.gate!.complete();
      await _settle(tester);
      expect(find.byType(FileViewerScreen), findsOneWidget);
      expect(find.byType(FileResolvingPage), findsNothing);
    });

    testWidgets('a tapped path can be opened again once the first one was found', (tester) async {
      final machine = machineWithFiles(projectFs());
      final routes = _Routes();
      await _pump(tester, _host((c) => openRemoteFile(c, machine, '$_root/pubspec.yaml')), routes: routes);

      await tester.tap(find.text('go'));
      await _settle(tester);
      expect(find.byType(FileViewerScreen), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);
      await tester.tap(find.text('go'));
      await _settle(tester);

      expect(find.byType(FileViewerScreen), findsOneWidget);
    });
  });

  group('sorting and "changed in the last hour"', () {
    FileBrowserViewModel vmOf(FakeFs fs, {FileBrowserOptions? options}) {
      final vm = FileBrowserViewModel(
        files: machineWithFiles(fs).files,
        path: '$_home/w',
        options: options,
        clock: () => _now,
      );
      addTearDown(vm.dispose);
      return vm;
    }

    List<String> names(FileBrowserViewModel vm) => [for (final e in vm.entries) e.name];

    test('Name: folders first, natural order; folders first off puts them among the files', () async {
      final vm = vmOf(_recentFs());
      await vm.load();
      expect(names(vm), ['docs', 'lib', 'big.log', 'edge.dart', 'exact.txt', 'fresh.dart', 'old.md', 'stale.dart']);

      vm.options.setFoldersFirst(false);
      expect(names(vm), ['big.log', 'docs', 'edge.dart', 'exact.txt', 'fresh.dart', 'lib', 'old.md', 'stale.dart']);
    });

    test('Modified: newest first, with the folders first or among the files', () async {
      final vm = vmOf(_recentFs());
      await vm.load();
      vm.options.setSort(FileSort.modified);
      expect(names(vm), ['lib', 'docs', 'fresh.dart', 'big.log', 'edge.dart', 'exact.txt', 'stale.dart', 'old.md']);

      vm.options.setFoldersFirst(false);
      expect(names(vm), ['fresh.dart', 'big.log', 'lib', 'edge.dart', 'exact.txt', 'stale.dart', 'old.md', 'docs']);
    });

    test('Size: largest first, folders last (their size is a directory block)', () async {
      final vm = vmOf(_recentFs());
      await vm.load();
      vm.options
        ..setSort(FileSort.size)
        ..setFoldersFirst(false);
      expect(names(vm), ['big.log', 'fresh.dart', 'edge.dart', 'exact.txt', 'old.md', 'stale.dart', 'docs', 'lib']);
    });

    test('Type: by extension, then by name', () async {
      final vm = vmOf(_recentFs());
      await vm.load();
      vm.options
        ..setSort(FileSort.type)
        ..setFoldersFirst(false);
      expect(names(vm), ['docs', 'lib', 'edge.dart', 'fresh.dart', 'stale.dart', 'big.log', 'old.md', 'exact.txt']);
    });

    test('changed in the last hour keeps what changed at or after the cut, by the clock it was given', () async {
      final vm = vmOf(_recentFs());
      await vm.load();

      vm.options.setRecentOnly(true);
      expect(names(vm), ['fresh.dart', 'big.log', 'lib', 'edge.dart', 'exact.txt'], reason: '60 min is in, 61 is out');
      expect(vm.filtered, isTrue);
      expect(vm.baseCount, 8);
    });

    test('the chip also sorts newest first and takes the folders off the top; off, the ordering comes back', () async {
      final vm = vmOf(_recentFs());
      await vm.load();

      vm.options.setRecentOnly(true);
      expect(vm.options.sort, FileSort.modified);
      expect(vm.options.foldersFirst, isFalse);
      vm.options.setRecentOnly(false);
      expect(vm.options.sort, FileSort.name);
      expect(vm.options.foldersFirst, isTrue);
      expect(names(vm).length, 8);

      vm.options.setRecentOnly(true);
      vm.options.setSort(FileSort.size); // chosen by hand: the chip no longer owns the ordering
      vm.options.setRecentOnly(false);
      expect(vm.options.sort, FileSort.size);
    });

    test('an entry with no known time is never recent', () {
      final listing = FileListing([
        RemoteEntry(name: 'a', path: '/a', kind: RemoteEntryKind.file, resolvedKind: RemoteEntryKind.file, size: 1),
        RemoteEntry(
          name: 'b',
          path: '/b',
          kind: RemoteEntryKind.file,
          resolvedKind: RemoteEntryKind.file,
          size: 1,
          modified: _now,
        ),
      ]);
      final recent = listing.view(
        sort: FileSort.modified,
        foldersFirst: false,
        showHidden: false,
        changedSince: _now.subtract(recentWindow),
      );
      expect([for (final e in recent) e.name], ['b']);
      final all = listing.view(sort: FileSort.modified, foldersFirst: false, showHidden: false);
      expect([for (final e in all) e.name], ['b', 'a'], reason: 'unknown times sort last');
    });

    testWidgets('the sort chip opens the sheet; picking Modified reorders; Folders first is a switch', (tester) async {
      await _pump(tester, _browser(_recentFs(), '$_home/w', clock: () => _now));
      await _settle(tester);
      expect(_names(tester).first, 'docs');

      await tester.tap(find.text('Name'));
      await _settle(tester);
      expect(find.text('Sort by'), findsOneWidget);
      expect(find.text('Newest first'), findsOneWidget);
      await tester.tap(find.text('Modified'));
      await _settle(tester);

      expect(_names(tester).take(3), ['lib', 'docs', 'fresh.dart']);
      expect(find.text('50 B · 3m ago'), findsOneWidget, reason: 'times are told from the clock the screen was given');

      await tester.tap(find.text('Modified').first);
      await _settle(tester);
      await tester.tap(find.text('Folders first'));
      await _settle(tester);
      await tester.tapAt(const Offset(10, 10)); // the scrim
      await _settle(tester);
      expect(_names(tester).take(3), ['fresh.dart', 'big.log', 'lib']);
    });

    testWidgets('the Changed in the last hour chip filters the list and the count says how many', (tester) async {
      await _pump(tester, _browser(_recentFs(), '$_home/w', clock: () => _now));
      await _settle(tester);
      expect(find.text('8 items'), findsOneWidget);

      await tester.tap(find.text('Changed in the last hour'));
      await _settle(tester);

      expect(_names(tester), ['fresh.dart', 'big.log', 'lib', 'edge.dart', 'exact.txt']);
      expect(find.text('5 of 8 items'), findsOneWidget);
      expect(find.text('50 B · 3m ago'), findsOneWidget);
      expect(find.text('100 B · 5m ago'), findsOneWidget);

      await tester.tap(find.text('Changed in the last hour'));
      await _settle(tester);
      expect(find.text('8 items'), findsOneWidget);
    });

    testWidgets('when nothing changed it says so, that only this folder was checked, and offers everything', (
      tester,
    ) async {
      await _pump(tester, _browser(_recentFs(), '$_home/w', clock: () => _now.add(const Duration(days: 30))));
      await _settle(tester);

      await tester.tap(find.text('Changed in the last hour'));
      await _settle(tester);

      expect(find.text('Nothing changed in the last hour'), findsOneWidget);
      expect(find.textContaining('not the folders inside'), findsOneWidget);
      await tester.tap(find.text('Show all files'));
      await _settle(tester);
      expect(find.text('8 items'), findsOneWidget);
    });
  });

  group('find in this folder', () {
    FakeFs searchFs() => FakeFs()
      ..addFile('$_home/s/Thiết kế giao diện.md', 'x')
      ..addFile('$_home/s/Đồng hồ.txt', 'x')
      ..addFile('$_home/s/Ảnh chụp màn hình.png', 'x')
      ..addFile('$_home/s/README.md', 'x')
      ..addFile('$_home/s/notes.txt', 'x')
      ..addFile('$_home/s/Bảng giá 2026.xlsx', 'x')
      ..addFile('$_home/s/Hóa đơn tháng 5.pdf', 'x')
      ..addFile('$_home/s/cafe.txt', 'x')
      ..addDir('$_home/s/Tài liệu');

    test('foldForSearch drops case and diacritics, đ included, and combining marks', () {
      expect(foldForSearch('Thiết kế'), 'thiet ke');
      expect(foldForSearch('Đồng HỒ'), 'dong ho');
      expect(foldForSearch('Ảnh chụp'), 'anh chup');
      expect(foldForSearch('The\u0302\u0301'), 'the', reason: 'decomposed e + circumflex + acute');
      expect(foldForSearch('Café ÑANDÚ'), 'cafe nandu');
      expect(foldForSearch('日本語'), '日本語', reason: 'what has no Latin folding stays');
      expect(foldForSearch('plain.TXT'), 'plain.txt');
    });

    test('a query matches anywhere in the name, ignoring case and accents', () {
      final entries = [
        for (final n in ['Thiết kế giao diện.md', 'README.md', 'Đồng hồ.txt'])
          RemoteEntry(name: n, path: '/$n', kind: RemoteEntryKind.file, resolvedKind: RemoteEntryKind.file),
      ];
      final listing = FileListing(entries);
      List<String> find(String q) => [
        for (final e in listing.view(sort: FileSort.name, foldersFirst: true, showHidden: false, query: q)) e.name,
      ];
      expect(find('thiet ke'), ['Thiết kế giao diện.md']);
      expect(find('THIẾT'), ['Thiết kế giao diện.md']);
      expect(find('dong'), ['Đồng hồ.txt']);
      expect(find('đồng'), ['Đồng hồ.txt']);
      expect(find('.md'), ['README.md', 'Thiết kế giao diện.md']);
      expect(find('  readme '), ['README.md'], reason: 'the ends are trimmed');
      expect(find('zzz'), isEmpty);
    });

    testWidgets('typing filters at once, without a read; accents do not matter; Clear brings everything back', (
      tester,
    ) async {
      final fs = searchFs();
      await _pump(tester, _browser(fs, '$_home/s'));
      await _settle(tester);
      final reads = fs.calls.length;
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'thiet');
      await tester.pump();
      expect(_names(tester), ['Thiết kế giao diện.md']);
      expect(find.text('1 of 9 items'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'anh chup');
      await tester.pump();
      expect(_names(tester), ['Ảnh chụp màn hình.png']);

      await tester.enterText(find.byType(TextField), 'DONG');
      await tester.pump();
      expect(_names(tester), ['Đồng hồ.txt']);
      expect(fs.calls.length, reads, reason: 'the filter is the loaded listing: no remote search, no read');

      await tester.enterText(find.byType(TextField), 'nothing like this');
      await tester.pump();
      expect(find.text('No matches'), findsOneWidget);
      await tester.tap(find.text('Clear search'));
      await _settle(tester);
      expect(_names(tester).length, 9);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });

    testWidgets('a folder of a few entries has no find field (it is only height)', (tester) async {
      await _pump(tester, _browser(projectFs(), '$_root/docs'));
      await _settle(tester);

      expect(find.byType(TextField), findsNothing);
    });
  });

  group('rows', () {
    testWidgets('middleEllipsize keeps the extension and fits the width; a short name is left alone', (tester) async {
      final style = Type.row;
      const scaler = TextScaler.noScaling;
      double width(String s) => (TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
      )..layout()).width;

      const name = 'really_long_name....test.dart';
      final cut = middleEllipsize(name, 150, style, scaler);
      expect(cut, contains('…'));
      expect(cut, endsWith('test.dart'));
      expect(cut, startsWith('really'.substring(0, 2)));
      expect(width(cut), lessThanOrEqualTo(150));

      expect(middleEllipsize('main.dart', 300, style, scaler), 'main.dart');
      final tiny = middleEllipsize(name, 80, style, scaler);
      expect(width(tiny), lessThanOrEqualTo(80));
      expect(tiny, endsWith('.dart'), reason: 'when little fits, the end is what is left');

      final noExt = middleEllipsize('build_2026_05_20_snapshot_b', 150, style, scaler);
      expect(noExt, endsWith('shot_b'.substring(0, 6)));
      expect(width(noExt), lessThanOrEqualTo(150));

      final viet = middleEllipsize('Báo cáo tổng hợp quý ba năm 2026 bản cuối.docx', 160, style, scaler);
      expect(viet, endsWith('.docx'));
      expect(width(viet), lessThanOrEqualTo(160));
      expect(viet, startsWith('Báo'));
    });

    testWidgets('a long name in a row keeps its extension on screen at 320 wide', (tester) async {
      final fs = projectFs();
      await _pump(tester, _browser(fs, _root), size: const Size(320, 640));
      await _settle(tester);
      await tester.scrollUntilVisible(
        find.textContaining('orig.bak'),
        200,
        scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
      );

      final shown = tester.widget<Text>(find.textContaining('orig.bak')).data!;
      expect(shown, contains('…'));
      expect(shown, endsWith('orig.bak'));
      expect(shown, startsWith('a-very'));
      expect(tester.takeException(), isNull);
    });

    test('tailLength keeps four characters and the extension, six without one', () {
      expect(tailLength('report.final.test.dart'.split('')), '.dart'.length + 4);
      expect(tailLength('Makefile.long.name.here'.split('')), '.here'.length + 4);
      expect(tailLength('build_2026_05_20_b'.split('')), 6);
      expect(tailLength('a.b'.split('')), 3, reason: 'a name no longer than its tail is all tail');
    });

    testWidgets('a row says size and time on one muted line, and a folder says its time', (tester) async {
      final fs = _recentFs();
      await _pump(tester, _browser(fs, '$_home/w', clock: () => _now));
      await _settle(tester);

      expect(find.text('50 B · 3m ago'), findsOneWidget);
      expect(find.text('10m ago'), findsOneWidget);
    });

    test('unreadable: no read bit at all, or a folder nobody can enter; a link says nothing', () {
      RemoteEntry entry(int? mode, {RemoteEntryKind kind = RemoteEntryKind.file, RemoteEntryKind? resolved}) =>
          RemoteEntry(
            name: 'x',
            path: '/x',
            kind: kind,
            resolvedKind: resolved ?? (kind == RemoteEntryKind.link ? RemoteEntryKind.dir : kind),
            mode: mode,
          );
      expect(isUnreadable(entry(0x8000)), isTrue);
      expect(isUnreadable(entry(0x81A4)), isFalse);
      expect(isUnreadable(entry(0x8080)), isTrue, reason: 'write only');
      expect(
        isUnreadable(entry(0x4000 | 0x1A4, kind: RemoteEntryKind.dir)),
        isTrue,
        reason: 'a folder with no execute bit',
      );
      expect(isUnreadable(entry(0x41ED, kind: RemoteEntryKind.dir)), isFalse);
      expect(isUnreadable(entry(null)), isFalse);
      expect(isUnreadable(entry(0xA1FF, kind: RemoteEntryKind.link)), isFalse);
    });

    testWidgets('a folder the host refused is dimmed, says so, and still opens to explain; Open parent leads out', (
      tester,
    ) async {
      final fs = projectFs()
        ..addDir('$_home/w/secret')
        ..addFile('$_home/w/a.txt', 'x')
        ..deny.add('$_home/w/secret');
      final session = FileBrowserSession();
      await _pump(tester, _browser(fs, '$_home/w', session: session));
      await _settle(tester);
      expect(find.text('No permission'), findsNothing, reason: 'nothing is known before it is tried');

      await tester.tap(find.text('secret'));
      await _settle(tester);
      expect(find.text('No permission'), findsOneWidget);
      expect(find.text('Open parent'), findsOneWidget);
      await tester.tap(find.text('Open parent'));
      await _settle(tester);

      expect(session.paths, ['$_home/w']);
      final row = find.widgetWithText(FileRow, 'secret');
      expect(tester.widget<FileRow>(row).denied, isTrue);
      expect(find.descendant(of: row, matching: find.text('No permission')), findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byType(Opacity)),
        findsOneWidget,
        reason: 'dimmed, not hidden',
      );
      expect(find.byType(FileRow), findsNWidgets(2));
    });
  });

  group('states say what to do', () {
    testWidgets('empty: Folder is empty, and how to look again', (tester) async {
      final fs = FakeFs()..addDir('$_home/e');
      await _pump(tester, _browser(fs, '$_home/e'));
      await _settle(tester);

      expect(find.text('Folder is empty'), findsOneWidget);
      expect(find.textContaining('Pull down'), findsOneWidget);
    });

    testWidgets('not reachable: says so, offers Retry, and Retry recovers', (tester) async {
      final fs = projectFs()..fail = RemoteFileException(RemoteFileErrorKind.network, 'Host did not answer');
      await _pump(tester, _browser(fs, _root));
      await _settle(tester);

      expect(find.text('Not reachable'), findsOneWidget);
      expect(find.text('Host did not answer'), findsOneWidget);
      fs.fail = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.text('Not reachable'), findsNothing);
      expect(find.text('AGENTS.md'), findsOneWidget);
    });

    testWidgets('no permission names Open parent next to Retry; a missing folder offers Go up', (tester) async {
      final fs = projectFs()
        ..addDir('$_home/locked')
        ..deny.add('$_home/locked');
      await _pump(tester, _browser(fs, '$_home/locked'));
      await _settle(tester);
      expect(find.text('No permission'), findsOneWidget);
      expect(find.text('Open parent'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);

      await _pump(tester, _browser(fs, '$_home/vanished'));
      await _settle(tester);
      expect(find.text('Go up'), findsOneWidget);
    });
  });

  group('thumbnails', () {
    RemoteEntry png(String name, {int size = 100}) => RemoteEntry(
      name: name,
      path: '$_home/p/$name',
      kind: RemoteEntryKind.file,
      resolvedKind: RemoteEntryKind.file,
      size: size,
      modified: _now,
    );

    test('raster images are eligible up to what the machine can thumbnail; a photo is not READ for 32 px', () {
      expect(ThumbLoader.eligible(png('a.png')), isTrue);
      expect(ThumbLoader.eligible(png('a.JPG')), isTrue);
      expect(
        ThumbLoader.eligible(png('a.png', size: thumbMaxBytes + 1)),
        isTrue,
        reason: 'a machine with the helper makes its thumbnail; without it the row stays a glyph (see below)',
      );
      expect(ThumbLoader.eligible(png('a.png', size: thumbHostMaxBytes + 1)), isFalse);
      expect(ThumbLoader.eligible(png('a.svg')), isFalse);
      expect(ThumbLoader.eligible(png('a.txt')), isFalse);
      expect(ThumbLoader.eligible(png('a.png', size: 0)), isFalse);
    });

    test('a big picture on a machine that cannot thumbnail is never read, and not asked about twice', () async {
      final fs = FakeFs()..addFile('$_home/p/big.jpg', Uint8List(thumbMaxBytes + 10));
      final transport = FakeTransport()..fs = fs;
      final files = RemoteFiles(transport, machineId: 'm1');
      final loader = ThumbLoader();
      final big = png('big.jpg', size: thumbMaxBytes + 10);

      expect(await loader.load(files, big, cancelled: () => false), isNull);
      expect(await loader.load(files, big, cancelled: () => false), isNull);

      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty, reason: 'SFTP would carry the whole photo');
      expect(transport.thumbnails, ['$_home/p/big.jpg@256'], reason: 'asked once, then remembered');
    });

    test('a machine that makes thumbnails gives a big picture a small one, and nothing is read', () async {
      final fs = FakeFs()..addFile('$_home/p/big.jpg', Uint8List(3 * 1024 * 1024));
      final jpeg = Uint8List.fromList(List.filled(9000, 7));
      final transport = FakeTransport()
        ..fs = fs
        ..onThumbnail = (path, maxPx, expect, cancelled) async => jpeg;
      final files = RemoteFiles(transport, machineId: 'm1');
      final loader = ThumbLoader();
      final big = png('big.jpg', size: 3 * 1024 * 1024);

      final got = await loader.load(files, big, cancelled: () => false);

      expect(got, jpeg);
      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty);
      expect(transport.thumbnails, ['$_home/p/big.jpg@256']);
    });

    test('at most three reads at a time; a row that scrolled away before its turn is never read', () async {
      final fs = FakeFs();
      for (var i = 0; i < 8; i++) {
        fs.addFile('$_home/p/$i.png', Uint8List.fromList([1, 2, 3]));
      }
      fs.gate = Completer<void>();
      final loader = ThumbLoader();
      final files = machineWithFiles(fs).files;
      final results = <Future<Uint8List?>>[
        for (var i = 0; i < 8; i++) loader.load(files, png('$i.png', size: 3), cancelled: () => i == 6),
      ];
      await Future<void>.delayed(Duration.zero);

      expect(loader.running, 3);
      expect(loader.waiting, 5);
      expect(fs.calls.where((c) => c.startsWith('read ')), hasLength(3));

      fs.gate!.complete();
      final bytes = await Future.wait(results);
      expect(bytes[6], isNull, reason: 'cancelled while it waited');
      expect([
        for (final i in [0, 1, 2, 3, 4, 5, 7]) bytes[i]!.length,
      ], everyElement(3));
      expect(fs.calls.where((c) => c == 'read $_home/p/6.png@0+3'), isEmpty);
      expect(loader.running, 0);
    });

    test('a second ask for the same unchanged file is answered from memory', () async {
      final fs = FakeFs()..addFile('$_home/p/a.png', Uint8List.fromList([9, 9]));
      final loader = ThumbLoader();
      final files = machineWithFiles(fs).files;
      final entry = png('a.png', size: 2);

      await loader.load(files, entry, cancelled: () => false);
      await loader.load(files, entry, cancelled: () => false);

      expect(fs.calls.where((c) => c.startsWith('read ')), hasLength(1));
    });

    testWidgets('an image row shows its picture; a photo-sized one never reads', (tester) async {
      final bytes = await makePng(tester, 40, 30);
      final fs = FakeFs()
        ..addFile('$_home/p/small.png', bytes)
        ..addFile('$_home/p/photo.jpg', Uint8List(thumbMaxBytes + 10))
        ..addFile('$_home/p/notes.txt', 'x');
      await _pump(tester, _browser(fs, '$_home/p', thumbs: ThumbLoader()));
      await _settle(tester);

      final thumb = find.descendant(of: find.widgetWithText(FileRow, 'small.png'), matching: find.byType(Image));
      expect(thumb, findsOneWidget);
      expect(
        find.descendant(of: find.widgetWithText(FileRow, 'photo.jpg'), matching: find.byType(Image)),
        findsNothing,
      );
      expect(fs.calls.where((c) => c.contains('photo.jpg') && c.startsWith('read ')), isEmpty);
      expect(fs.calls.where((c) => c.contains('notes.txt') && c.startsWith('read ')), isEmpty);
    });
  });

  group('the viewer notices the file changing', () {
    const path = '$_root/build.log';
    final stamp = DateTime.utc(2026, 5, 20, 9, 30);
    late FakeTransport transport;

    setUp(() => transport = FakeTransport());

    FakeFs logFs() => projectFs()..addFile(path, List.generate(300, (i) => 'line $i ok').join('\n'), modified: stamp);

    FileViewerScreen viewer(FakeFs fs) => FileViewerScreen(
      machine: machineWithFiles(fs, transport: transport),
      stat: RemoteStat(
        path: path,
        kind: RemoteEntryKind.file,
        size: fs.nodes[path]!.bytes.length,
        modified: fs.nodes[path]!.modified,
      ),
    );

    int listening() => transport.watching(path);

    void touch(FakeFs fs, String content, {Duration later = const Duration(minutes: 5)}) {
      fs.addFile(path, content, modified: stamp.add(later));
      transport.touched(path);
    }

    Future<void> after(WidgetTester tester, Duration d) async {
      await tester.pump(d);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a change the machine reports shows the pill at once; nothing is read to find out', (tester) async {
      final fs = logFs();
      await _pump(tester, viewer(fs));
      await _settle(tester);
      expect(find.text('Changed on disk'), findsNothing);
      expect(listening(), 1, reason: 'one subscription, no timer');
      final reads = fs.calls.where((c) => c.startsWith('read ')).length;

      transport.touched(path);
      await after(tester, const Duration(minutes: 2));
      expect(find.text('Changed on disk'), findsNothing, reason: 'same time on disk, however long it is looked at');

      touch(fs, List.generate(300, (i) => 'new line $i').join('\n'));
      await after(tester, const Duration(milliseconds: 10));
      await _settle(tester);

      expect(find.text('Changed on disk'), findsOneWidget);
      expect(find.text('Reload'), findsOneWidget);
      expect(fs.calls.where((c) => c.startsWith('read ')).length, reads, reason: 'told, never read the body');
    });

    testWidgets('a tap reloads the text where the reader is, and the pill goes', (tester) async {
      final fs = logFs();
      await _pump(tester, viewer(fs));
      await _settle(tester);
      final scroll = tester.state<ScrollableState>(
        find.descendant(of: find.byType(CodeView), matching: find.byType(Scrollable)).last,
      );
      scroll.position.jumpTo(100 * 21.0); // line 101 at the top: Mono.input (13.5 px) at 1.5 is 21 px a row
      await tester.pump();
      await tester.pump();
      expect(find.text('110'), findsOneWidget, reason: 'line 110 is in view');
      final before = scroll.position.pixels;

      touch(fs, '${List.generate(300, (i) => 'rewritten $i').join('\n')}\n');
      await after(tester, const Duration(milliseconds: 10));
      await tester.tap(find.text('Reload'));
      await _settle(tester);
      await _settle(tester);

      expect(find.text('Changed on disk'), findsNothing);
      expect(find.textContaining('rewritten'), findsWidgets);
      expect(find.textContaining('line 1 ok'), findsNothing);
      expect(find.byType(Skeleton), findsNothing, reason: 'no flash back to a skeleton');
      expect(scroll.position.pixels, before, reason: 'the reader stayed on the same line');
    });

    testWidgets('it listens to nothing while another screen covers the viewer, and again when it is back', (
      tester,
    ) async {
      final fs = logFs();
      await _pump(tester, viewer(fs));
      await _settle(tester);
      final context = tester.element(find.byType(CodeView));
      expect(listening(), 1);

      unawaited(
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('covering page')))),
      );
      await _settle(tester);
      expect(find.text('covering page'), findsOneWidget);
      expect(listening(), 0, reason: 'behind another screen: no subscription');

      touch(fs, 'changed while you were away');
      Navigator.of(tester.element(find.text('covering page'))).pop();
      await _settle(tester);
      expect(listening(), 1);
      expect(find.text('Changed on disk'), findsOneWidget, reason: 'it noticed what happened while away');
    });

    testWidgets('it listens to nothing in the background, and again on resume', (tester) async {
      final fs = logFs();
      await _pump(tester, viewer(fs));
      await _settle(tester);
      expect(listening(), 1);

      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(listening(), 0);
      touch(fs, 'changed while the app was away');

      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await after(tester, const Duration(milliseconds: 10));
      expect(listening(), 1);
      expect(find.text('Changed on disk'), findsOneWidget);
    });

    testWidgets('leaving the viewer ends the subscription', (tester) async {
      final fs = logFs();
      await _pump(tester, viewer(fs));
      await _settle(tester);
      expect(listening(), 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(minutes: 1));

      expect(listening(), 0);
      // The test framework fails a test that leaves a timer pending.
    });

    testWidgets('a watch that ends is taken up again after 15 s, and nothing is claimed meanwhile', (tester) async {
      final fs = logFs();
      await _pump(tester, viewer(fs));
      await _settle(tester);
      expect(listening(), 1);

      transport.failWatchers(path, const HerdrTransportException('link dropped'));
      await after(tester, const Duration(seconds: 14));
      expect(listening(), 0, reason: 'not before the retry');
      expect(find.text('Changed on disk'), findsNothing, reason: 'a lost link is not a change');
      touch(fs, 'changed while the link was down');
      await after(tester, const Duration(seconds: 2));
      expect(listening(), 1);
      expect(find.text('Changed on disk'), findsOneWidget, reason: 'the new watch starts with the file as it is');
    });

    testWidgets('pulling down reads the file again; a failed read keeps the old text and offers Retry', (tester) async {
      final fs = logFs();
      await _pump(tester, viewer(fs));
      await _settle(tester);
      touch(fs, 'brand new text');
      fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'link down');

      await tester.fling(find.byType(CodeView), const Offset(0, 400), 1000);
      await _settle(tester);
      await _settle(tester);

      expect(find.textContaining('Couldn’t refresh'), findsOneWidget);
      expect(find.text('line 0 ok'), findsOneWidget, reason: 'the old text stays');
      fs.fail = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      await _settle(tester);

      expect(find.textContaining('Couldn’t refresh'), findsNothing);
      expect(find.text('brand new text'), findsOneWidget);
    });

    testWidgets('at 320 wide with large text the pill fits', (tester) async {
      final fs = logFs();
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pump(tester, viewer(fs), size: const Size(320, 640));
      await _settle(tester);
      touch(fs, 'x');
      await after(tester, const Duration(milliseconds: 10));
      await _settle(tester);

      expect(find.text('Changed on disk'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final pill = find.ancestor(of: find.text('Changed on disk'), matching: find.byType(PressBuilder)).first;
      final box = tester.getRect(pill);
      expect(box.height, greaterThanOrEqualTo(kMinTap));
    });

    test('view model: watchDisk follows the machine; refresh keeps the old content when it fails', () async {
      final fs = logFs();
      final stat = await fs.stat(path);
      final vm = FileViewerViewModel(
        files: machineWithFiles(fs, transport: transport).files,
        stat: stat,
      );
      addTearDown(vm.dispose);
      await vm.load();

      expect(transport.watching(path), 0, reason: 'nobody asked to watch');
      vm.watchDisk(true);
      vm.watchDisk(true); // idempotent: one subscription
      await pumpEventQueue();
      expect(transport.watching(path), 1);
      expect(vm.changedOnDisk, isFalse, reason: 'the first answer is the file as it was read');

      touch(fs, 'v2');
      await pumpEventQueue();
      expect(vm.changedOnDisk, isTrue);

      fs.fail = RemoteFileException(RemoteFileErrorKind.network, 'down');
      await vm.refresh();
      expect(vm.refreshError, isNotNull);
      expect(vm.phase, ViewerPhase.ready);
      expect(vm.document!.text, startsWith('line 0 ok'));
      expect(vm.refreshing, isFalse);

      fs.fail = null;
      await vm.refresh();
      expect(vm.refreshError, isNull);
      expect(vm.document!.text, 'v2');
      expect(vm.changedOnDisk, isFalse);
      expect(vm.stat.modified, stamp.add(const Duration(minutes: 5)));
      transport.touched(path);
      await pumpEventQueue();
      expect(vm.changedOnDisk, isFalse, reason: 'it now matches the disk');

      vm.watchDisk(false);
      expect(transport.watching(path), 0);
      touch(fs, 'v3', later: const Duration(minutes: 9));
      await pumpEventQueue();
      expect(vm.changedOnDisk, isFalse, reason: 'not listening, not told');
    });
  });

  testWidgets('the file icons for code, image, Markdown, archive and binary differ', (tester) async {
    final icons = {
      for (final n in ['a.dart', 'a.png', 'a.md', 'a.zip', 'a.bin', 'a.json', 'a.mp3']) n: fileIconForName(n),
    };
    expect(icons['a.dart'], isNot(icons['a.png']));
    expect(icons['a.md'], isNot(icons['a.zip']));
    expect(icons['a.zip'], isNot(icons['a.bin']));
    expect({icons['a.dart'], icons['a.png'], icons['a.md'], icons['a.zip'], icons['a.bin']}.length, 5);
  });
}
