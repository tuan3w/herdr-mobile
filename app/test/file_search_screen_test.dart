import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_row.dart';
import 'package:herdr_mobile/ui/features/files/file_search_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/files_support.dart';
import 'support/shot.dart' show loadAppFonts;

// Search in the Files screen as a person meets it: the header's action, typing,
// matches arriving while the spinner runs, the time chips, what a truncated or
// empty or failed search says, opening a match and coming back, and that the
// machine is not kept searching for nobody. The mapping to the host is in
// host_files_search_thumb_test.dart; the walk for SFTP in file_walk_search_test.dart.

const _dir = '/home/dev/proj';
// Local, like the clock the app uses: "Today" is since local midnight.
final _now = DateTime(2026, 5, 20, 12);

/// One search the machine was asked for, and how the test answers it.
class _Run {
  _Run(this.spec) {
    controller = StreamController<FileSearchEvent>(onCancel: () => cancelled = true);
  }

  final FileSearchSpec spec;
  late final StreamController<FileSearchEvent> controller;
  var cancelled = false;

  void found(Iterable<RemoteEntry> entries) => controller.add(FileSearchBatch(entries.toList()));

  void done({int scanned = 40, bool truncated = false, int skipped = 0}) =>
      controller.add(FileSearchDone(scanned: scanned, truncated: truncated, skippedDirs: skipped));
}

RemoteEntry _file(String path, {Duration ago = const Duration(minutes: 3), int size = 2048}) => RemoteEntry(
  name: RemotePath.basename(path),
  path: path,
  kind: RemoteEntryKind.file,
  resolvedKind: RemoteEntryKind.file,
  size: size,
  modified: _now.subtract(ago),
);

RemoteEntry _folder(String path) => RemoteEntry(
  name: RemotePath.basename(path),
  path: path,
  kind: RemoteEntryKind.dir,
  resolvedKind: RemoteEntryKind.dir,
  modified: _now.subtract(const Duration(hours: 2)),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadAppFonts);

  late FakeFs fs;
  late FakeTransport transport;
  late List<_Run> runs;

  setUp(() {
    fs = FakeFs()
      ..addDir(_dir)
      ..addFile('$_dir/notes.txt', 'hello', modified: _now)
      ..addFile('$_dir/a/b/report.md', '# report', modified: _now)
      ..addFile('$_dir/shot.png', Uint8List.fromList([1, 2, 3]), modified: _now);
    transport = FakeTransport()..fs = fs;
    runs = [];
    transport.onSearch = (spec) {
      final run = _Run(spec);
      runs.add(run);
      return run.controller.stream;
    };
  });

  Future<void> openBrowser(WidgetTester tester, {FileBrowserMode mode = FileBrowserMode.browse}) async {
    tester.view
      ..physicalSize = const Size(412, 892) * 2.625
      ..devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        key: UniqueKey(),
        theme: AppTheme.light(),
        home: FileBrowserScreen(
          machine: machineWithFiles(fs, transport: transport),
          path: _dir,
          mode: mode,
          clock: () => _now,
          thumbs: ThumbLoader(),
        ),
      ),
    );
    await tester.pump();
    await _settle(tester);
  }

  Future<void> openSearch(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Search in proj'));
    await _settle(tester);
    expect(find.byType(FileSearchScreen), findsOneWidget);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    // The pause after typing.
    await tester.pump(const Duration(milliseconds: 600));
  }

  group('getting there', () {
    testWidgets('the header has Search and the hidden-files eye: two actions, also in a folder of photos', (
      tester,
    ) async {
      for (var i = 0; i < 8; i++) {
        fs.addFile('$_dir/p$i.png', Uint8List.fromList([1, 2, 3]));
      }
      await openBrowser(tester);

      expect(find.byTooltip('Search in proj'), findsOneWidget);
      expect(find.byTooltip('Show hidden files'), findsOneWidget);
      expect(
        find.widgetWithText(AppChip, 'Photos'),
        findsOneWidget,
        reason: 'the grid switch is a chip, not a third action',
      );
      expect(find.byTooltip('Photos'), findsNothing);
    });

    testWidgets('opening it asks nobody; the keyboard is up and the three time chips are there', (tester) async {
      await openBrowser(tester);

      await openSearch(tester);

      expect(runs, isEmpty, reason: 'no question yet');
      expect(find.text('Search proj'), findsOneWidget);
      for (final label in ['Any time', 'Last hour', 'Today']) {
        expect(find.widgetWithText(AppChip, label), findsOneWidget);
      }
      expect(tester.widget<AppChip>(find.widgetWithText(AppChip, 'Any time')).selected, isTrue);
      expect(FocusManager.instance.primaryFocus, isNotNull);
    });
  });

  group('typing', () {
    testWidgets('the first batch is on screen while the spinner still runs; rows say which folder they are in', (
      tester,
    ) async {
      await openBrowser(tester);
      await openSearch(tester);

      await type(tester, 'report');
      expect(runs.single.spec.query, 'report');
      expect(runs.single.spec.root, _dir);
      expect(find.text('Searching proj…'), findsOneWidget, reason: 'nothing found yet');

      runs.single.found([_file('$_dir/a/b/report.md'), _file('$_dir/report.txt', size: 5)]);
      await tester.pump();

      expect(find.text('report.md'), findsOneWidget);
      expect(find.text('a/b'), findsOneWidget, reason: 'the folder below the searched one');
      expect(find.text('proj'), findsOneWidget, reason: 'a match directly in it names the searched folder');
      expect(find.text('Still searching…'), findsOneWidget, reason: 'the search is not over');
      expect(find.text('2 found so far'), findsOneWidget);
      expect(find.text(' · 3m ago'), findsNWidgets(2), reason: 'when it changed, kept whole after the folder');
    });

    testWidgets('a search that ends says what it covered', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'report');
      runs.single
        ..found([_file('$_dir/a/b/report.md')])
        ..done(scanned: 1234, skipped: 1);
      await tester.pump();

      expect(find.text('Searched 1,234 items · 1 folder couldn’t be read'), findsOneWidget);
      expect(find.text('Narrow the search'), findsNothing, reason: 'it covered everything it could');
      expect(find.text('1 found'), findsOneWidget);
      expect(find.text('Still searching…'), findsNothing);
    });

    testWidgets('a truncated search says so and offers to narrow it, which puts the cursor back in the field', (
      tester,
    ) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'a');
      runs.single
        ..found([for (var i = 0; i < 3; i++) _file('$_dir/f$i.txt')])
        ..done(scanned: 3000, truncated: true);
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      expect(find.text('Searched 3,000 items'), findsOneWidget);
      expect(find.textContaining('more than 3'), findsOneWidget);
      await tester.ensureVisible(find.text('Narrow the search'));
      await tester.tap(find.text('Narrow the search'));
      await tester.pump();

      expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
    });

    testWidgets('nothing found says what was asked, and a search that stopped early is not called final', (
      tester,
    ) async {
      await openBrowser(tester);
      await openSearch(tester);

      await type(tester, 'zzz');
      runs.last.done(scanned: 50);
      await tester.pump();
      expect(find.text('Nothing named “zzz”'), findsOneWidget);
      expect(find.text('Nothing in proj or the folders inside it.'), findsOneWidget);

      await type(tester, 'zzzz');
      runs.last.done(scanned: 3000, truncated: true);
      await tester.pump();
      expect(find.text('Nothing named “zzzz”'), findsOneWidget);
      expect(find.textContaining('may be more'), findsOneWidget);
      expect(find.text('Narrow the search'), findsOneWidget);
    });

    testWidgets('a newer text replaces the matches at once and the old stream\u2019s stragglers are not shown', (
      tester,
    ) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'a');
      final first = runs.single;
      first.found([_file('$_dir/apple.txt')]);
      await tester.pump();
      expect(find.text('apple.txt'), findsOneWidget);

      await type(tester, 'ab');

      expect(first.cancelled, isTrue);
      expect(find.text('apple.txt'), findsNothing);
      first.found([_file('$_dir/avocado.txt')]);
      runs.last.found([_file('$_dir/abc.txt')]);
      await tester.pump();
      expect(find.text('avocado.txt'), findsNothing);
      expect(find.text('abc.txt'), findsOneWidget);
    });
  });

  group('the time chips', () {
    testWidgets('Last hour works with no text at all', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);

      await tester.tap(find.widgetWithText(AppChip, 'Last hour'));
      await tester.pump();

      expect(runs.single.spec.query, isEmpty);
      expect(runs.single.spec.modifiedWithin, const Duration(hours: 1));
      expect(tester.widget<AppChip>(find.widgetWithText(AppChip, 'Last hour')).selected, isTrue);
      runs.single.found([_file('$_dir/fresh.log')]);
      await tester.pump();
      expect(find.text('fresh.log'), findsOneWidget);
    });

    testWidgets('Today with text narrows it; Any time takes the limit off and an empty field goes back to the prompt', (
      tester,
    ) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'log');

      await tester.tap(find.widgetWithText(AppChip, 'Today'));
      await tester.pump();
      expect(runs.last.spec.query, 'log');
      expect(runs.last.spec.modifiedWithin, const Duration(hours: 12), reason: 'since local midnight, by the clock');

      await tester.tap(find.widgetWithText(AppChip, 'Any time'));
      await tester.pump();
      expect(runs.last.spec.modifiedWithin, isNull);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Search proj'), findsOneWidget, reason: 'nothing to look for: the prompt, not “nothing found”');
      expect(runs.last.cancelled, isTrue);
    });

    testWidgets('an empty time window says what it means', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);

      await tester.tap(find.widgetWithText(AppChip, 'Last hour'));
      await tester.pump();
      runs.single.done();
      await tester.pump();

      expect(find.text('Nothing changed in the last hour'), findsOneWidget);
    });
  });

  group('when it fails', () {
    testWidgets('the text stays in the field, the panel says what happened, and Retry asks again', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'report');
      runs.single.controller.addError(
        RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost', path: _dir),
      );
      await tester.pump();

      expect(find.text('Retry'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'report');

      await tester.tap(find.text('Retry'));
      await tester.pump();

      expect(runs, hasLength(2));
      expect(runs.last.spec.query, 'report');
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('opening a match', () {
    testWidgets('a file opens the viewer over the search, which keeps its matches and does not run again', (
      tester,
    ) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'report');
      runs.single
        ..found([_file('$_dir/a/b/report.md', size: 8)])
        ..done();
      await tester.pump();

      await tester.tap(find.text('report.md'));
      await _settle(tester);
      expect(find.byType(FileViewerScreen), findsOneWidget);

      Navigator.of(tester.element(find.byType(FileViewerScreen))).pop();
      await _settle(tester);

      expect(find.byType(FileSearchScreen), findsOneWidget);
      expect(find.text('report.md'), findsOneWidget, reason: 'the matches are where they were');
      expect(runs, hasLength(1), reason: 'a finished search is not run again');
    });

    testWidgets('a folder match opens that folder in the browser', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'a');
      runs.single
        ..found([_folder('$_dir/a')])
        ..done();
      await tester.pump();

      await tester.tap(find.descendant(of: find.byType(FileRow), matching: find.text('a')));
      await _settle(tester);

      expect(find.byType(FileBrowserScreen), findsOneWidget, reason: 'the folder opened is in front');
      expect(find.byType(FileSearchScreen, skipOffstage: false), findsOneWidget, reason: 'the search is underneath');
      expect(find.text('b'), findsOneWidget);
    });

    testWidgets('picking a file: a match answers the picker, popping the search and the browser', (tester) async {
      String? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    picked = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => FileBrowserScreen(
                          machine: machineWithFiles(fs, transport: transport),
                          path: _dir,
                          mode: FileBrowserMode.pickFile,
                          clock: () => _now,
                          thumbs: ThumbLoader(),
                        ),
                      ),
                    );
                  },
                  child: const Text('pick'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pick'));
      await _settle(tester);
      await tester.tap(find.byTooltip('Search in proj'));
      await _settle(tester);
      await type(tester, 'report');
      runs.single
        ..found([_file('$_dir/a/b/report.md')])
        ..done();
      await tester.pump();

      await tester.tap(find.text('report.md'));
      await _settle(tester);

      expect(picked, '$_dir/a/b/report.md');
      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(find.byType(FileSearchScreen), findsNothing);
    });

    testWidgets('picking a folder searches folders only', (tester) async {
      await openBrowser(tester, mode: FileBrowserMode.pickDirectory);
      await openSearch(tester);

      await type(tester, 'a');

      expect(runs.single.spec.kind, FileSearchKind.dir);
    });
  });

  group('it stops when nobody looks', () {
    testWidgets('going back stops the search on the machine', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'report');
      expect(runs.single.cancelled, isFalse);

      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);

      expect(find.byType(FileSearchScreen), findsNothing);
      expect(runs.single.cancelled, isTrue);
    });

    testWidgets('a screen over it stops it; coming back goes on and does not move the rows', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'report');
      runs.single.found([_file('$_dir/a/b/report.md', size: 8)]);
      await tester.pump();

      await tester.tap(find.text('report.md'));
      await _settle(tester);
      expect(runs.single.cancelled, isTrue, reason: 'the viewer covers it: nothing is searched for nobody');

      Navigator.of(tester.element(find.byType(FileViewerScreen))).pop();
      await _settle(tester);

      expect(runs, hasLength(2), reason: 'it goes on where it was cut off');
      runs.last.found([_file('$_dir/a/b/report.md', size: 8), _file('$_dir/z/report-2.md', size: 8)]);
      await tester.pump();
      expect(find.text('report.md'), findsOneWidget);
      expect(find.text('report-2.md'), findsOneWidget);
    });

    testWidgets('the app going to the background stops it, and coming back resumes', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'report');
      runs.single.found([_file('$_dir/a/b/report.md')]);
      await tester.pump();

      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(runs.single.cancelled, isTrue);

      for (final s in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pump();
      expect(runs, hasLength(2));
    });
  });

  group('worst case', () {
    testWidgets('2,000 matches with long names build only the rows on screen', (tester) async {
      await openBrowser(tester);
      await openSearch(tester);
      await type(tester, 'x');
      final long = 'a-very-long-file-name-that-keeps-going-and-going-until-it-needs-an-ellipsis-here';
      for (var batch = 0; batch < 20; batch++) {
        runs.single.found([
          for (var i = 0; i < 100; i++)
            _file('$_dir/deep/${'nested-folder-' * 6}$batch/$long-${batch * 100 + i}.dart', ago: Duration(minutes: i)),
        ]);
      }
      runs.single.done(scanned: 200000, truncated: true);
      await tester.pump();

      expect(tester.takeException(), isNull, reason: 'long names and paths fit');
      expect(find.byType(FileRow).evaluate().length, lessThan(30));
    });
  });
}
