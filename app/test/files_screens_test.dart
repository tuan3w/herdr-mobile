import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/files/binary_view.dart';
import 'package:herdr_mobile/ui/features/files/code_view.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_widgets.dart';
import 'package:herdr_mobile/ui/features/files/files_navigation.dart';
import 'package:herdr_mobile/ui/features/files/image_view.dart';
import 'package:herdr_mobile/ui/features/files/markdown_view.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'support/fake_fs.dart';
import 'support/files_support.dart';
import 'support/shot.dart' show loadAppFonts;

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2.625
    ..devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  // A fresh key per call: a second screen in one test must not inherit the
  // first one's providers.
  await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: AppTheme.light(), home: home));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 80 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}

FileViewerScreen _viewer(FakeFs fs, String path, {int? line}) => FileViewerScreen(
      machine: machineWithFiles(fs),
      stat: RemoteStat(
        path: path,
        kind: RemoteEntryKind.file,
        size: fs.nodes[path]!.bytes.length,
        modified: fs.nodes[path]!.modified,
      ),
      line: line,
    );

/// Captures what the app puts on the clipboard.
List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      copied.add((call.arguments as Map)['text'] as String);
    }
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

void main() {
  setUpAll(loadAppFonts);

  group('browser', () {
    testWidgets('a 5,000-entry folder builds only the rows on screen, at any scroll position', (tester) async {
      final fs = FakeFs();
      for (var i = 0; i < 5000; i++) {
        fs.addFile('/home/dev/big/Tệp số $i.txt', 'x');
      }
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(fs), path: '/home/dev/big'));
      await _settle(tester);

      expect(find.text('5,000 items'), findsOneWidget);
      expect(find.byType(ListRow).evaluate().length, lessThan(30));

      final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pump();
      await tester.pump();

      expect(find.text('Tệp số 4999.txt'), findsOneWidget, reason: 'natural order puts 4999 last');
      expect(find.byType(ListRow).evaluate().length, lessThan(30));
    });

    testWidgets('tapping a folder opens it; back returns; the system back gesture works too', (tester) async {
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(projectFs()), path: '/home/dev/herdr-mobile'));
      await _settle(tester);

      await tester.tap(find.text('docs'));
      await _settle(tester);
      expect(find.text('Thiết kế giao diện.md'), findsOneWidget);
      expect(find.text('3 items'), findsNothing);

      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);
      expect(find.text('AGENTS.md'), findsOneWidget);

      await tester.tap(find.text('app'));
      await _settle(tester);
      expect(find.text('lib'), findsOneWidget);
      await tester.tap(find.text('lib'));
      await _settle(tester);
      expect(find.text('main.dart'), findsOneWidget);

      await tester.pageBack();
      await _settle(tester);
      await tester.pageBack();
      await _settle(tester);
      expect(find.text('AGENTS.md'), findsOneWidget);
    });

    testWidgets('a folder link opens its target; a file opens the viewer', (tester) async {
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(projectFs()), path: '/home/dev/herdr-mobile'));
      await _settle(tester);

      await tester.tap(find.text('latest'));
      await _settle(tester);
      expect(find.text('Thiết kế giao diện.md'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);

      await tester.tap(find.text('pubspec.yaml'));
      await _settle(tester);
      expect(find.byType(FileViewerScreen), findsOneWidget);
      expect(find.text('name: herdr_mobile'), findsOneWidget);
    });

    testWidgets('pulling down re-reads the folder and shows what changed', (tester) async {
      final fs = projectFs();
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(fs), path: '/home/dev/herdr-mobile/docs'));
      await _settle(tester);
      expect(find.text('fresh.txt'), findsNothing);
      fs.addFile('/home/dev/herdr-mobile/docs/fresh.txt', 'x');

      await tester.fling(find.byType(ListRow).first, const Offset(0, 400), 1000);
      await _settle(tester);
      await _settle(tester);

      expect(find.text('fresh.txt'), findsOneWidget);
      expect(fs.calls.where((c) => c == 'list /home/dev/herdr-mobile/docs'), hasLength(2));
    });

    testWidgets('dotfiles stay hidden until the eye is tapped', (tester) async {
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(projectFs()), path: '/home/dev/herdr-mobile'));
      await _settle(tester);
      expect(find.text('.gitignore'), findsNothing);
      expect(find.text('15 items · 3 hidden'), findsOneWidget);

      await tester.tap(find.byTooltip('Show hidden files'));
      await _settle(tester);

      expect(find.text('.git'), findsOneWidget);
      expect(find.text('18 items'), findsOneWidget);
      expect(find.byTooltip('Hide hidden files'), findsOneWidget);
    });

    testWidgets('an empty folder, and a folder of only dotfiles, say so', (tester) async {
      final fs = projectFs()
        ..addDir('/home/dev/empty')
        ..addFile('/home/dev/dots/.env', 'x');
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(fs), path: '/home/dev/empty'));
      await _settle(tester);
      expect(find.text('Empty folder'), findsOneWidget);

      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(fs), path: '/home/dev/dots'));
      await _settle(tester);
      expect(find.text('Only hidden files'), findsOneWidget);
      await tester.tap(find.text('Show hidden files'));
      await _settle(tester);
      expect(find.text('.env'), findsOneWidget);
    });

    testWidgets('permission denied, missing folder and no-SFTP each get their own message; Retry recovers', (tester) async {
      final fs = projectFs()
        ..addDir('/home/dev/secret')
        ..deny.add('/home/dev/secret');
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(fs), path: '/home/dev/secret'));
      await _settle(tester);
      expect(find.text('Permission denied'), findsOneWidget);

      fs.deny.clear();
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.text('Permission denied'), findsNothing);
      expect(find.text('Empty folder'), findsOneWidget);

      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(fs), path: '/home/dev/gone'));
      await _settle(tester);
      expect(find.text('Not found'), findsOneWidget);
      expect(find.text('Go up'), findsOneWidget);

      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(null), path: '/home/dev'));
      await _settle(tester);
      expect(find.text('Files are unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsNothing, reason: 'trying again cannot add SFTP');
    });

    testWidgets('a broken link explains itself instead of failing silently', (tester) async {
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(projectFs()), path: '/home/dev/herdr-mobile'));
      await _settle(tester);

      await tester.scrollUntilVisible(
        find.text('stale-link'),
        300,
        scrollable: find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable)).first,
      );
      await tester.tap(find.text('stale-link'));
      await tester.pump();

      expect(find.textContaining('no longer exists'), findsOneWidget);
    });

    testWidgets('long names and Vietnamese / CJK names fit on one line each, without overflow errors', (tester) async {
      await _pump(tester, FileBrowserScreen(machine: machineWithFiles(projectFs()), path: '/home/dev/herdr-mobile/docs'));
      await _settle(tester);

      expect(find.text('Thiết kế giao diện.md'), findsOneWidget);
      expect(find.text('日本語のメモ.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('folder picking and opening paths', () {
    Future<void> host(
      WidgetTester tester,
      MachineConnection machine,
      Future<void> Function(BuildContext context) onTap,
    ) async {
      await _pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: GestureDetector(onTap: () => onTap(context), child: const Text('go')),
            ),
          ),
        ),
      );
    }

    testWidgets('pickRemoteDirectory returns the folder chosen after browsing down', (tester) async {
      String? chosen;
      var done = false;
      final machine = machineWithFiles(projectFs());
      await host(tester, machine, (context) async {
        chosen = await pickRemoteDirectory(context, machine, startDir: '~/herdr-mobile');
        done = true;
      });

      await tester.tap(find.text('go'));
      await _settle(tester);
      expect(find.text('Choose this folder'), findsOneWidget);
      expect(find.text('README.md'), findsNothing, reason: 'only folders are listed');
      await tester.tap(find.text('app'));
      await _settle(tester);
      await tester.tap(find.text('lib'));
      await _settle(tester);
      await tester.tap(find.text('Choose this folder'));
      await _settle(tester);

      expect(done, isTrue);
      expect(chosen, '/home/dev/herdr-mobile/app/lib');
      expect(find.text('go'), findsOneWidget, reason: 'the whole stack of pickers is gone');
    });

    testWidgets('pickRemoteDirectory returns null when dismissed, and without files', (tester) async {
      String? chosen = 'unset';
      final machine = machineWithFiles(projectFs());
      await host(tester, machine, (context) async => chosen = await pickRemoteDirectory(context, machine));
      await tester.tap(find.text('go'));
      await _settle(tester);
      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);
      expect(chosen, isNull);

      chosen = 'unset';
      final none = machineWithFiles(null);
      await host(tester, none, (context) async => chosen = await pickRemoteDirectory(context, none));
      await tester.tap(find.text('go'));
      await _settle(tester);
      expect(chosen, isNull);
      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(machineSupportsFiles(none), isFalse);
      expect(machineSupportsFiles(machine), isTrue);
    });

    testWidgets('openRemoteFile: ~ and :line:col resolve to the viewer with the line highlighted', (tester) async {
      final machine = machineWithFiles(projectFs());
      await host(tester, machine, (c) => openRemoteFile(c, machine, '~/herdr-mobile/app/lib/main.dart:24:3'));

      await tester.tap(find.text('go'));
      await _settle(tester);

      expect(find.byType(FileViewerScreen), findsOneWidget);
      expect(find.text('main.dart'), findsOneWidget);
      expect(tester.widget<CodeView>(find.byType(CodeView)).highlightLine, 24);
    });

    testWidgets('openRemoteFile: a relative path resolves against the pane cwd', (tester) async {
      final machine = machineWithFiles(projectFs());
      await host(tester, machine, (c) => openRemoteFile(c, machine, 'lib/main.dart', cwd: '/home/dev/herdr-mobile/app', line: 3));

      await tester.tap(find.text('go'));
      await _settle(tester);

      expect(tester.widget<CodeView>(find.byType(CodeView)).highlightLine, 3);
    });

    testWidgets('openRemoteFile: a folder opens the browser', (tester) async {
      final machine = machineWithFiles(projectFs());
      await host(tester, machine, (c) => openRemoteFile(c, machine, '/home/dev/herdr-mobile/docs'));

      await tester.tap(find.text('go'));
      await _settle(tester);

      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(find.text('docs'), findsWidgets);
    });

    testWidgets('openRemoteFile: a file really named with a colon and digits is found literally', (tester) async {
      final fs = projectFs()..addFile('/home/dev/notes:2024', 'literal');
      final machine = machineWithFiles(fs);
      await host(tester, machine, (c) => openRemoteFile(c, machine, '/home/dev/notes:2024'));

      await tester.tap(find.text('go'));
      await _settle(tester);

      expect(find.text('literal'), findsOneWidget);
      expect(tester.widget<CodeView>(find.byType(CodeView)).highlightLine, isNull);
    });

    testWidgets('openRemoteFile: not found, permission and no-files are quiet toasts, not routes', (tester) async {
      final fs = projectFs()
        ..addFile('/home/dev/locked.txt', 'x')
        ..deny.add('/home/dev/locked.txt');
      final machine = machineWithFiles(fs);
      var path = '/home/dev/missing.txt';
      await host(tester, machine, (c) => openRemoteFile(c, machine, path));

      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining("missing.txt doesn't exist"), findsOneWidget);
      expect(find.byType(FileViewerScreen), findsNothing);

      path = '/home/dev/locked.txt';
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.text('go'));
      await _settle(tester);
      await _settle(tester);
      expect(find.textContaining('permission to open locked.txt'), findsOneWidget);

      final none = machineWithFiles(null);
      await host(tester, none, (c) => openRemoteFile(c, none, '/x'));
      await tester.tap(find.text('go'));
      await _settle(tester);
      await _settle(tester);
      expect(find.textContaining('not available'), findsOneWidget);
    });
  });

  group('viewer', () {
    testWidgets('shows a skeleton while loading, then numbered lines in the mono font', (tester) async {
      final fs = projectFs();
      fs.gate = Completer<void>();
      await _pump(tester, _viewer(fs, '/home/dev/herdr-mobile/pubspec.yaml'));
      await tester.pump();

      expect(find.byType(FileSkeleton), findsOneWidget);
      expect(find.byType(CodeView), findsNothing);

      fs.gate!.complete();
      await _settle(tester);

      expect(find.byType(FileSkeleton), findsNothing);
      expect(find.text('name: herdr_mobile'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      final text = tester.widget<Text>(find.text('name: herdr_mobile'));
      expect(text.style!.fontFamily, 'JetBrainsMono');
    });

    testWidgets('the highlighted line is scrolled into view and drawn with a band', (tester) async {
      await _pump(tester, _viewer(projectFs(), '/home/dev/herdr-mobile/build.log', line: 250));
      await _settle(tester);

      expect(find.text('250'), findsOneWidget);
      expect(find.text('line 249 ok'), findsOneWidget);
      final row = find.ancestor(of: find.text('250'), matching: find.byType(Container)).first;
      expect((tester.widget<Container>(row).color), isNotNull);
    });

    testWidgets('only the lines on screen exist, wrapping or not', (tester) async {
      final fs = FakeFs()..addFile('/h/big.txt', List.generate(50000, (i) => 'row $i').join('\n'));
      await _pump(tester, _viewer(fs, '/h/big.txt'));
      await _settle(tester);

      final nowrap = find.byType(Text).evaluate().length;
      expect(nowrap, lessThan(150));

      await tester.tap(find.text('Wrap'));
      await _settle(tester);
      expect(tester.widget<CodeView>(find.byType(CodeView)).wrap, isTrue);
      expect(find.byType(Text).evaluate().length, lessThan(200));
    });

    testWidgets('a megabyte-long line is cut, not laid out whole', (tester) async {
      final fs = FakeFs()..addFile('/h/min.js', 'x' * 400000);
      await _pump(tester, _viewer(fs, '/h/min.js'));
      await _settle(tester);

      final lengths = [for (final t in tester.widgetList<Text>(find.byType(Text))) (t.data ?? '').length];
      expect(lengths.reduce((a, b) => a > b ? a : b), lessThan(codeLineCap + 100));
      expect(find.textContaining('more characters'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a line wider than the screen scrolls sideways to its end', (tester) async {
      final fs = FakeFs()..addFile('/h/wide.txt', '${'0123456789' * 30}END\nshort\n');
      await _pump(tester, _viewer(fs, '/h/wide.txt'));
      await _settle(tester);
      expect(find.textContaining('END'), findsOneWidget);
      final scroller = find.descendant(of: find.byType(CodeView), matching: find.byType(SingleChildScrollView)).first;
      final position = tester.state<ScrollableState>(
        find.descendant(of: scroller, matching: find.byType(Scrollable)).first,
      ).position;
      expect(position.maxScrollExtent, greaterThan(1000), reason: '303 columns of mono text');

      position.jumpTo(position.maxScrollExtent);
      await tester.pump();

      final text = tester.getTopRight(find.textContaining('END'));
      expect(text.dx, lessThanOrEqualTo(412 + 0.5), reason: 'the end of the line is on screen, not clipped');
    });

    testWidgets('code can be selected', (tester) async {
      await _pump(tester, _viewer(projectFs(), '/home/dev/herdr-mobile/pubspec.yaml'));
      await _settle(tester);

      expect(find.descendant(of: find.byType(CodeView), matching: find.byType(SelectionArea)), findsOneWidget);
    });

    testWidgets('a long file offers "Load more" with how much is shown, and loads it', (tester) async {
      final fs = FakeFs()..addFile('/h/log.txt', List.generate(80000, (i) => 'entry number $i').join('\n'));
      await _pump(tester, _viewer(fs, '/h/log.txt'));
      await _settle(tester);

      expect(find.textContaining('Showing 512 KB of'), findsOneWidget);
      final before = tester.widget<CodeView>(find.byType(CodeView)).document.lineCount;

      await tester.tap(find.text('Load more'));
      await _settle(tester);

      expect(tester.widget<CodeView>(find.byType(CodeView)).document.lineCount, greaterThan(before));
      expect(find.textContaining('Showing 1 MB of'), findsOneWidget);
    });

    testWidgets('copy path and copy contents reach the clipboard', (tester) async {
      final copied = _captureClipboard(tester);
      await _pump(tester, _viewer(projectFs(), '/home/dev/herdr-mobile/pubspec.yaml'));
      await _settle(tester);

      await tester.tap(find.byTooltip('Copy path'));
      await tester.pump();
      expect(copied.last, '/home/dev/herdr-mobile/pubspec.yaml');
      expect(find.text('Path copied'), findsOneWidget);

      await tester.tap(find.byTooltip('Copy contents'));
      await _settle(tester);
      expect(copied.last, 'name: herdr_mobile\nversion: 1.4.0+4102');
    });

    testWidgets('a clipboard that refuses a huge copy is reported, not crashed on', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') throw PlatformException(code: 'too_large');
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await _pump(tester, _viewer(projectFs(), '/home/dev/herdr-mobile/pubspec.yaml'));
      await _settle(tester);

      await tester.tap(find.byTooltip('Copy contents'));
      await _settle(tester);

      expect(find.textContaining("Couldn't copy"), findsOneWidget);
    });

    testWidgets('an empty file says so and offers no copy', (tester) async {
      await _pump(tester, _viewer(projectFs(), '/home/dev/herdr-mobile/empty.txt'));
      await _settle(tester);

      expect(find.text('Empty file'), findsOneWidget);
      expect(find.byTooltip('Copy contents'), findsNothing);
      expect(find.text('Wrap'), findsNothing);
    });

    testWidgets('Markdown is rendered, with a switch to the source', (tester) async {
      await _pump(tester, _viewer(projectFs(), '/home/dev/herdr-mobile/README.md'));
      await _settle(tester);

      expect(find.byType(MarkdownView), findsOneWidget);
      expect(find.text('# herdr mobile'), findsNothing);

      await tester.tap(find.text('Source'));
      await _settle(tester);

      expect(find.byType(MarkdownView), findsNothing);
      expect(find.text('# herdr mobile'), findsOneWidget);
    });

    testWidgets('JSON: minified text is laid out, and Pretty switches back to what is on disk', (tester) async {
      await _pump(tester, _viewer(projectFs(), '/home/dev/herdr-mobile/package.json'));
      await _settle(tester);
      expect(find.text('  "name": "herdr",'), findsOneWidget);

      await tester.tap(find.text('Pretty'));
      await _settle(tester);

      expect(find.text('  "name": "herdr",'), findsNothing);
      expect(find.textContaining('"name":"herdr"'), findsOneWidget);
    });

    testWidgets('invalid JSON explains why Pretty did nothing', (tester) async {
      final fs = FakeFs()..addFile('/h/a.json', '{"a": [1, 2,\n  3\n}\n');
      await _pump(tester, _viewer(fs, '/h/a.json'));
      await _settle(tester);

      await tester.tap(find.text('Pretty'));
      await _settle(tester);

      expect(find.textContaining('valid JSON'), findsOneWidget);
    });

    for (final (name, fs, title, retry) in [
      ('permission', () => projectFs()..deny.add('/home/dev/herdr-mobile/AGENTS.md'), 'Permission denied', true),
      ('not found', () => projectFs()..nodes.remove('/home/dev/herdr-mobile/AGENTS.md'), 'Not found', true),
    ]) {
      testWidgets('$name: its own message${retry ? ' and a Retry' : ''}', (tester) async {
        final fileSystem = fs();
        final screen = FileViewerScreen(
          machine: machineWithFiles(fileSystem),
          stat: const RemoteStat(path: '/home/dev/herdr-mobile/AGENTS.md', kind: RemoteEntryKind.file, size: 6),
        );
        await _pump(tester, screen);
        await _settle(tester);

        expect(find.text(title), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(find.text('Copy path'), findsWidgets);
      });
    }

    testWidgets('Retry after a permission fix shows the file', (tester) async {
      final fs = projectFs()..deny.add('/home/dev/herdr-mobile/AGENTS.md');
      await _pump(
        tester,
        FileViewerScreen(
          machine: machineWithFiles(fs),
          stat: const RemoteStat(path: '/home/dev/herdr-mobile/AGENTS.md', kind: RemoteEntryKind.file, size: 6),
        ),
      );
      await _settle(tester);
      fs.deny.clear();

      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(find.text('notes'), findsOneWidget);
    });

    testWidgets('no SFTP: an explanation and no Retry', (tester) async {
      await _pump(
        tester,
        FileViewerScreen(
          machine: machineWithFiles(null),
          stat: const RemoteStat(path: '/home/dev/a.txt', kind: RemoteEntryKind.file, size: 5),
        ),
      );
      await _settle(tester);

      expect(find.text('Files are unavailable'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a binary file is an info card with a hex preview and no text chrome', (tester) async {
      final fs = FakeFs()
        ..addFile('/h/tool', Uint8List.fromList([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0, ...List.generate(1000, (i) => i % 256)]));
      await _pump(tester, _viewer(fs, '/h/tool'));
      await _settle(tester);

      expect(find.byType(BinaryView), findsOneWidget);
      expect(find.text('Executable (ELF)'), findsOneWidget);
      expect(find.text('First 256 bytes'), findsOneWidget);
      expect(find.textContaining('7f 45 4c 46'), findsOneWidget);
      expect(find.text('Wrap'), findsNothing);
      expect(find.byTooltip('Copy contents'), findsNothing);
      expect(find.text('Copy path'), findsOneWidget);
    });

    testWidgets('SVG offers its source as text', (tester) async {
      final fs = FakeFs()..addFile('/h/logo.svg', '<svg xmlns="http://www.w3.org/2000/svg"></svg>');
      await _pump(tester, _viewer(fs, '/h/logo.svg'));
      await _settle(tester);
      expect(find.byType(BinaryView), findsOneWidget);

      await tester.tap(find.text('View as text'));
      await _settle(tester);

      expect(find.byType(BinaryView), findsNothing);
      expect(find.textContaining('<svg'), findsOneWidget);
    });

    testWidgets('an image appears, with its pixel size, and Fit / 100% switch the zoom', (tester) async {
      final fs = FakeFs()..addFile('/h/photo.png', await makePng(tester, 1600, 1200));
      await _pump(tester, _viewer(fs, '/h/photo.png'));
      await _waitFor(tester, find.byType(RawImage));

      expect(find.byType(ImageView), findsOneWidget);
      expect(find.textContaining('1,600 × 1,200'), findsOneWidget);
      final viewer = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), 1);

      await tester.tap(find.text('100%'));
      await _settle(tester);
      // One image pixel per device pixel: 1600 px at 2.625 dpr in a 412 dp viewport.
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), closeTo(1600 / 2.625 / 412, 0.02));

      await tester.tap(find.text('Fit'));
      await _settle(tester);
      expect(viewer.transformationController!.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
    });

    testWidgets('double-tapping an image zooms in, and again returns to fit', (tester) async {
      final fs = FakeFs()..addFile('/h/photo.png', await makePng(tester, 1600, 1200));
      await _pump(tester, _viewer(fs, '/h/photo.png'));
      await _waitFor(tester, find.byType(RawImage));
      final controller = tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).transformationController!;

      await tester.tap(find.byType(RawImage));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byType(RawImage));
      await _settle(tester);
      expect(controller.value.getMaxScaleOnAxis(), greaterThan(2));

      await tester.tap(find.byType(RawImage));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byType(RawImage));
      await _settle(tester);
      expect(controller.value.getMaxScaleOnAxis(), closeTo(1, 0.001));
    });

    testWidgets('an image larger than the cap is decoded at reduced size and says so', (tester) async {
      final fs = FakeFs()..addFile('/h/huge.png', await makePng(tester, 3000, 2000));
      await _pump(tester, _viewer(fs, '/h/huge.png'));
      await _waitFor(tester, find.byType(RawImage));

      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect(raw.image!.width, 2048);
      expect(raw.image!.height, 1365);
      expect(find.text('Preview at reduced resolution'), findsOneWidget);
      expect(find.textContaining('3,000 × 2,000'), findsOneWidget);
    });

    testWidgets('a damaged image is an error with an explanation, not a blank screen', (tester) async {
      final fs = FakeFs()
        ..addFile('/h/bad.png', Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(200, 3)]));
      await _pump(tester, _viewer(fs, '/h/bad.png'));
      await _waitFor(tester, find.textContaining("can't be decoded"));

      expect(find.textContaining("can't be decoded"), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('an image over 20 MB is refused with the size in the message', (tester) async {
      final fs = FakeFs()
        ..addFile('/h/big.png', Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...Uint8List(21 * 1024 * 1024)]));
      await _pump(tester, _viewer(fs, '/h/big.png'));
      await _settle(tester);

      expect(find.text('Too large to open'), findsOneWidget);
      expect(find.textContaining('21 MB'), findsWidgets);
      expect(find.text('Retry'), findsNothing);
      expect(fs.calls.where((c) => c.startsWith('read')).length, 1, reason: 'the image itself was never fetched');
    });

    testWidgets('leaving the viewer frees the decoded image', (tester) async {
      final fs = FakeFs()..addFile('/h/photo.png', await makePng(tester, 300, 200));
      await _pump(tester, _viewer(fs, '/h/photo.png'));
      await _waitFor(tester, find.byType(RawImage));
      final image = tester.widget<RawImage>(find.byType(RawImage)).image!;

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(image.debugDisposed, isTrue);
    });

    testWidgets('header, tools and cards fit at 320dp wide and 2x text without overflow', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fs = projectFs();
      for (final path in [
        '/home/dev/herdr-mobile/README.md',
        '/home/dev/herdr-mobile/build.log',
        '/home/dev/herdr-mobile/package.json',
      ]) {
        tester.view
          ..physicalSize = const Size(320, 640) * 2
          ..devicePixelRatio = 2;
        await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: _viewer(fs, path)));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: path);
      }
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: FileBrowserScreen(machine: machineWithFiles(fs), path: '/home/dev/herdr-mobile'),
      ));
      await _settle(tester);
      expect(tester.takeException(), isNull);
    });
  });

  test('the file icons are the Lucide ones the design system uses', () {
    expect(fileIconForName('a.dart'), LucideIcons.fileCode);
    expect(fileIconForName('a.png'), LucideIcons.fileImage);
    expect(fileIconForName('a.zip'), LucideIcons.fileArchive);
    expect(fileIconForName('notes.txt'), LucideIcons.fileText);
    expect(fileIconForName('Makefile'), LucideIcons.fileCode);
  });
}
