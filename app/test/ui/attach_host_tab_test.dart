// The attach sheet's Host tab: the session folder with what changed recently,
// inline folders, search, picks in the shared tray, the states, and PNGs of the
// tab for review (ATTACH_SHOTS=1).
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/attach/host_tab.dart';
import 'package:herdr_mobile/ui/features/attach/selection_circle.dart';
import 'package:herdr_mobile/ui/features/attach/sheet_frame.dart';
import 'package:herdr_mobile/ui/features/attach/tray.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_row.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/files_support.dart';
import '../support/shot.dart';

const _root = '/home/dev/herdr-mobile';
final _now = DateTime.utc(2026, 5, 20, 12);

/// A name of exactly 120 characters with Vietnamese diacritics and an extension.
final _longName = '${('Phương án triển khai hệ thống thanh toán nội bộ ' * 4).substring(0, 117)}.md';

/// projectFs() with three things that changed recently (a folder, README.md,
/// pubspec.yaml); everything else is from 09:30, two and a half hours before
/// [_now].
FakeFs _fs() {
  final fs = projectFs();
  void recent(String name, int minutes, Object content) =>
      fs.addFile('$_root/$name', content, modified: _now.subtract(Duration(minutes: minutes)));
  recent('README.md', 5, 'readme');
  recent('pubspec.yaml', 20, 'name: herdr_mobile');
  fs.addDir('$_root/docs', modified: _now.subtract(const Duration(minutes: 3)));
  return fs;
}

class _Rig {
  _Rig(this.tray, this.problems, this.position, this.fs);

  final AttachTray tray;
  final List<String> problems;
  final SheetPosition position;
  final FakeFs? fs;
}

class _Routes extends NavigatorObserver {
  var pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => pushes++;
}

Widget _tab(_Rig rig, FakeAgentSession session) => SheetScope(
  position: rig.position,
  bottomClearance: 120,
  child: Builder(
    builder: (context) => ColoredBox(
      color: context.ds.bg,
      child: HostTab(session: session, tray: rig.tray, onProblem: rig.problems.add, clock: () => _now),
    ),
  ),
);

FakeAgentSession _session(FakeFs? fs, {String cwd = _root}) =>
    FakeAgentSession(machine: machineWithFiles(fs), cwd: cwd);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pumps the tab on a phone-sized screen; the sheet rests at full height, so
/// the list scrolls.
Future<_Rig> _pump(
  WidgetTester tester, {
  FakeFs? fs,
  bool supported = true,
  String cwd = _root,
  Size size = const Size(412, 892),
  int capacity = 5,
  VoidCallback? onFull,
  _Routes? routes,
  bool expanded = true,
}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final files = supported ? (fs ?? _fs()) : null;
  final position = SheetPosition(vsync: tester, reduced: () => false, onDismiss: () {});
  // The frame lays the position out; without it the "full" height is 0 and
  // moving to it would dismiss the sheet.
  position.layout(full: size.height, half: size.height / 2);
  position.expanded.value = expanded;
  addTearDown(position.dispose);
  final rig = _Rig(AttachTray(capacity: capacity, onFull: onFull), [], position, files);
  addTearDown(rig.tray.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      navigatorObservers: [?routes],
      home: _tab(rig, _session(files, cwd: cwd)),
    ),
  );
  await _settle(tester);
  return rig;
}

Finder _row(String name) => find.ancestor(of: find.text(name), matching: find.byType(FileRow));

Finder _number(String name, int n) => find.descendant(of: _row(name), matching: find.text('$n'));

Future<void> _showAll(WidgetTester tester) async {
  await tester.tap(find.text('Changed recently'));
  await _settle(tester);
}

Future<void> _tapRow(WidgetTester tester, String name) async {
  await tester.tap(find.text(name));
  await _settle(tester);
}

Finder get _field => find.byType(TextField);

List<String> _lists(_Rig rig, String path) => rig.fs!.calls.where((c) => c == 'list $path').toList();

void main() {
  setUpAll(loadAppFonts);

  group('the first view', () {
    testWidgets('opens on the session folder with only what changed recently', (tester) async {
      final handle = tester.ensureSemantics();
      final rig = await _pump(tester);

      expect(_lists(rig, _root), hasLength(1));
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('pubspec.yaml'), findsOneWidget);
      expect(find.text('docs'), findsOneWidget);
      expect(find.text('package.json'), findsNothing);
      expect(find.text('AGENTS.md'), findsNothing);
      // Newest first, folders among the files.
      expect(
        tester.getTopLeft(find.text('docs')).dy < tester.getTopLeft(find.text('README.md')).dy &&
            tester.getTopLeft(find.text('README.md')).dy < tester.getTopLeft(find.text('pubspec.yaml')).dy,
        isTrue,
      );
      expect(find.text('Find in herdr-mobile'), findsOneWidget);
      final chip = tester.getSemantics(find.text('Changed recently'));
      expect(chip.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('the chip and Show all files switch the filter', (tester) async {
      final rig = await _pump(tester);
      await _showAll(tester);
      expect(find.text('package.json'), findsOneWidget);
      expect(find.text('AGENTS.md'), findsOneWidget);
      // One listing serves every filter.
      expect(_lists(rig, _root), hasLength(1));

      await _showAll(tester);
      expect(find.text('package.json'), findsNothing);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('nothing changed offers the whole folder', (tester) async {
      final fs = projectFs();
      await _pump(tester, fs: fs);
      expect(find.text('Nothing changed in the last hour'), findsOneWidget);
      await tester.tap(find.text('Show all files'));
      await _settle(tester);
      expect(find.text('Nothing changed in the last hour'), findsNothing);
      expect(find.text('package.json'), findsOneWidget);
    });

    testWidgets('an empty folder does not tell the person to pull down', (tester) async {
      final fs = FakeFs()..addDir('/home/dev/empty');
      await _pump(tester, fs: fs, cwd: '/home/dev/empty');
      expect(find.text('Folder is empty'), findsOneWidget);
      expect(find.textContaining('Nothing in empty yet.'), findsOneWidget);
      expect(find.textContaining('Pull down'), findsNothing);
    });

    testWidgets('a machine without files says so and has no tools', (tester) async {
      await _pump(tester, supported: false);
      expect(find.text('Files are unavailable on this machine'), findsOneWidget);
      expect(_field, findsNothing);
      expect(find.text('Browse all…'), findsNothing);
    });

    testWidgets('an empty session folder starts at the root', (tester) async {
      final fs = FakeFs()..addFile('/etc.conf', 'x', modified: _now);
      final rig = await _pump(tester, fs: fs, cwd: '');
      expect(_lists(rig, '/'), hasLength(1));
      expect(find.text('etc.conf'), findsOneWidget);
      expect(find.text('Find in /'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets('narrows the listing and clears with the field', (tester) async {
      await _pump(tester);
      await _showAll(tester);
      await tester.enterText(_field, 'read');
      await _settle(tester);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('pubspec.yaml'), findsNothing);

      await tester.enterText(_field, 'zzzz');
      await _settle(tester);
      expect(find.text('No matches'), findsOneWidget);
      await tester.tap(find.text('Clear search'));
      await _settle(tester);
      expect(find.text('pubspec.yaml'), findsOneWidget);
      expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
    });

    testWidgets('a finger on the field asks the sheet for its full height', (tester) async {
      final rig = await _pump(tester, expanded: false);
      expect(rig.position.expanded.value, isFalse);
      await tester.tap(_field);
      await _settle(tester);
      expect(rig.position.expanded.value, isTrue);
      // Let the spring come to rest (a running ticker fails the test).
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('folders', () {
    testWidgets('open in place and a breadcrumb pops back without listing again', (tester) async {
      final routes = _Routes();
      final rig = await _pump(tester, routes: routes);
      final pushed = routes.pushes;
      await _showAll(tester);

      await tester.enterText(_field, 'doc');
      await _settle(tester);
      await _tapRow(tester, 'docs');
      expect(_lists(rig, '$_root/docs'), hasLength(1));
      expect(find.text('Thiết kế giao diện.md'), findsOneWidget);
      expect(find.text('Find in docs'), findsOneWidget);
      // The search does not follow into the next folder.
      expect(tester.widget<TextField>(_field).controller!.text, isEmpty);
      expect(find.text('README.md'), findsNothing);

      final crumb = find.descendant(of: find.byType(FileBreadcrumbs), matching: find.text('herdr-mobile'));
      await tester.tap(crumb);
      await _settle(tester);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('Find in herdr-mobile'), findsOneWidget);
      expect(_lists(rig, _root), hasLength(1), reason: 'the folder is still listed');
      expect(routes.pushes, pushed, reason: 'nothing is pushed');
    });

    testWidgets('an ancestor above the start is listed fresh', (tester) async {
      final rig = await _pump(tester);
      await _showAll(tester);
      await tester.tap(find.descendant(of: find.byType(FileBreadcrumbs), matching: find.text('~')));
      await _settle(tester);
      expect(_lists(rig, '/home/dev'), hasLength(1));
      expect(find.text('Find in dev'), findsOneWidget);
      expect(find.text('herdr-mobile'), findsWidgets);
      // And a folder from there opens again.
      await _tapRow(tester, 'herdr-mobile');
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('a folder nobody can read opens to explain itself', (tester) async {
      final fs = _fs()..deny.add('$_root/docs');
      await _pump(tester, fs: fs);
      await _tapRow(tester, 'docs');
      expect(find.text('No permission'), findsOneWidget);
      await tester.tap(find.text('Open parent'));
      await _settle(tester);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets('a failed listing retries', (tester) async {
      final fs = _fs()..fail = RemoteFileException(RemoteFileErrorKind.failed, 'boom');
      await _pump(tester, fs: fs);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('README.md'), findsNothing);
      fs.fail = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.text('README.md'), findsOneWidget);
    });
  });

  group('picking', () {
    testWidgets('two files take places 1 and 2 in the tray, in order', (tester) async {
      final rig = await _pump(tester);
      await _tapRow(tester, 'pubspec.yaml');
      await _tapRow(tester, 'README.md');

      expect(_number('pubspec.yaml', 1), findsOneWidget);
      expect(_number('README.md', 2), findsOneWidget);
      final items = rig.tray.items.cast<HostPick>();
      expect(items.map((e) => e.path), ['$_root/pubspec.yaml', '$_root/README.md']);
      expect(items.map((e) => e.name), ['pubspec.yaml', 'README.md']);
      expect(items.map((e) => e.size), ['name: herdr_mobile'.length, 'readme'.length]);
      expect(items.every((e) => !e.fromPhone), isTrue);
      // A folder takes no place.
      expect(find.descendant(of: _row('docs'), matching: find.byType(SelectionCircle)), findsNothing);
    });

    testWidgets('a selected row deselects and the others renumber', (tester) async {
      final rig = await _pump(tester);
      await _tapRow(tester, 'pubspec.yaml');
      await _tapRow(tester, 'README.md');
      await _tapRow(tester, 'pubspec.yaml');

      expect(rig.tray.items.map((e) => e.name), ['README.md']);
      expect(_number('README.md', 1), findsOneWidget);
      expect(find.descendant(of: _row('pubspec.yaml'), matching: find.text('1')), findsNothing);
      expect(find.descendant(of: _row('pubspec.yaml'), matching: find.text('2')), findsNothing);
    });

    testWidgets('the circle picks and unpicks as the row does', (tester) async {
      final rig = await _pump(tester);
      final circle = find.descendant(of: _row('README.md'), matching: find.byType(SelectionCircle));
      await tester.tap(circle);
      await _settle(tester);
      expect(rig.tray.contains('h:$_root/README.md'), isTrue);
      await tester.tap(circle);
      await _settle(tester);
      expect(rig.tray.isEmpty, isTrue);
    });

    testWidgets('a pick made elsewhere shows on its row, a full message refuses the next', (tester) async {
      var full = 0;
      final rig = await _pump(tester, capacity: 1, onFull: () => full++);
      rig.tray.add(const HostPick(path: '$_root/README.md', name: 'README.md'));
      await _settle(tester);
      expect(_number('README.md', 1), findsOneWidget);

      await _tapRow(tester, 'pubspec.yaml');
      expect(full, 1);
      expect(rig.tray.length, 1);
      expect(find.descendant(of: _row('pubspec.yaml'), matching: find.byType(SelectionCircle)), findsOneWidget);
      expect(find.descendant(of: _row('pubspec.yaml'), matching: find.text('2')), findsNothing);
    });

    testWidgets('a file nobody can read is refused and says why', (tester) async {
      final fs = _fs();
      fs.nodes['$_root/AGENTS.md']!.mode = 0x8000;
      final rig = await _pump(tester, fs: fs);
      await _showAll(tester);
      expect(find.text('No permission'), findsOneWidget);
      expect(find.descendant(of: _row('AGENTS.md'), matching: find.byType(SelectionCircle)), findsNothing);

      await _tapRow(tester, 'AGENTS.md');
      expect(rig.problems, ['No permission to read AGENTS.md']);
      expect(rig.tray.isEmpty, isTrue);
    });

    testWidgets('a row reads as one node with its selected state, the circle as its own', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);

      var row = tester.getSemantics(find.byType(FileRow).at(1));
      expect(row.label, allOf(contains('README.md'), contains('6 B'), contains('5 min ago')));
      expect(row.flagsCollection.isSelected, Tristate.isFalse);
      expect(find.bySemanticsLabel('Select README.md'), findsOneWidget);

      await _tapRow(tester, 'README.md');
      row = tester.getSemantics(find.byType(FileRow).at(1));
      expect(row.flagsCollection.isSelected, Tristate.isTrue);
      expect(find.bySemanticsLabel('Deselect README.md'), findsOneWidget);
      expect(find.bySemanticsLabel('Select README.md'), findsNothing);
      // The folder is not selectable at all.
      final folder = tester.getSemantics(find.byType(FileRow).first);
      expect(folder.flagsCollection.isSelected, Tristate.none);
      handle.dispose();
    });

    testWidgets('Browse all… puts the path it returns in the tray', (tester) async {
      final routes = _Routes();
      final rig = await _pump(tester, routes: routes);
      await tester.tap(find.text('Browse all…'));
      await _settle(tester);
      final browser = find.byType(FileBrowserScreen);
      expect(browser, findsOneWidget);

      await tester.tap(find.descendant(of: browser, matching: find.text('AGENTS.md')));
      await _settle(tester);
      expect(browser, findsNothing);
      final pick = rig.tray.items.single as HostPick;
      expect(pick.path, '$_root/AGENTS.md');
      expect(pick.name, 'AGENTS.md');
    });

    testWidgets('backing out of Browse all… picks nothing', (tester) async {
      final rig = await _pump(tester);
      await tester.tap(find.text('Browse all…'));
      await _settle(tester);
      Navigator.of(tester.element(find.byType(FileBrowserScreen))).pop();
      await _settle(tester);
      expect(rig.tray.isEmpty, isTrue);
    });
  });

  group('worst cases', () {
    testWidgets('a 120-character Vietnamese name is cut in the middle and fits 320 px', (tester) async {
      expect(_longName.length, 120);
      final fs = _fs()..addFile('$_root/$_longName', 'x', modified: _now.subtract(const Duration(minutes: 1)));
      final rig = await _pump(tester, fs: fs, size: const Size(320, 640));

      expect(tester.takeException(), isNull);
      final cut = find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains('…') && (w.data ?? '').endsWith('.md'));
      expect(cut, findsOneWidget);
      final shown = tester.widget<Text>(cut).data!;
      expect(shown.length, lessThan(_longName.length));
      expect(shown.startsWith('Phương'), isTrue);
      // The row stays inside the screen.
      expect(tester.getRect(cut).right, lessThanOrEqualTo(320));

      await tester.tap(cut);
      await _settle(tester);
      expect(rig.tray.items.single.name, _longName);
      expect(tester.takeException(), isNull);
    });

    testWidgets('5,000 entries are built as they scroll in', (tester) async {
      final fs = FakeFs();
      for (var i = 0; i < 5000; i++) {
        fs.addFile('/big/Tệp $i.txt', 'x', modified: _now.subtract(Duration(seconds: i + 1)));
      }
      await _pump(tester, fs: fs, cwd: '/big');
      expect(tester.widgetList(find.byType(FileRow)).length, lessThan(30));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -3000));
      await tester.pump();
      expect(tester.widgetList(find.byType(FileRow)).length, lessThan(30));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a deep path keeps its breadcrumb scrolled to the folder', (tester) async {
      final deep = '/home/dev/${List.generate(12, (i) => 'level-number-$i').join('/')}';
      final fs = FakeFs()..addFile('$deep/a.txt', 'x', modified: _now);
      await _pump(tester, fs: fs, cwd: deep, size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      final last = find.descendant(of: find.byType(FileBreadcrumbs), matching: find.text('level-number-11'));
      expect(last, findsOneWidget);
      expect(tester.getRect(last).right, lessThanOrEqualTo(320));
    });
  });

  group('shots', skip: Platform.environment['ATTACH_SHOTS'] == null ? 'ATTACH_SHOTS=1 writes PNGs to /tmp' : false, () {
    Future<void> shot(WidgetTester tester, String name, Brightness brightness, {Size? size}) async {
      final fs = _fs()..addFile('$_root/$_longName', 'x', modified: _now.subtract(const Duration(minutes: 8)));
      fs.nodes['$_root/AGENTS.md']!.mode = 0x8000;
      final position = SheetPosition(vsync: tester, reduced: () => false, onDismiss: () {});
      position.expanded.value = true;
      addTearDown(position.dispose);
      final rig = _Rig(AttachTray(capacity: 5), [], position, fs);
      addTearDown(rig.tray.dispose);
      rig.tray
        ..add(const HostPick(path: '$_root/build.log', name: 'build.log', size: 3400))
        ..add(const HostPick(path: '$_root/package.json', name: 'package.json', size: 111));
      await shoot(
        tester,
        _tab(rig, _session(fs)),
        '/tmp/attach_host_tab_$name.png',
        brightness: brightness,
        pump: (tester) async {
          if (size != null) {
            tester.view.physicalSize = size * phoneDpr;
            await tester.pump();
          }
          await tester.tap(find.text('Changed recently'));
          await _settle(tester);
        },
      );
    }

    testWidgets('light', (tester) => shot(tester, 'light', Brightness.light));
    testWidgets('dark', (tester) => shot(tester, 'dark', Brightness.dark));
    testWidgets('small', (tester) => shot(tester, 'small', Brightness.light, size: const Size(320, 640)));
  });
}
