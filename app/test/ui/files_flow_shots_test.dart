// Renders the file browser and viewer states to PNGs for review: the folder
// sorted by recency with the "changed in the last hour" filter, the same folder
// by name (thumbnails, a refused folder dimmed), a search, nothing found,
// nothing changed, an empty folder, a failure (not reachable, no permission),
// one item, the sort sheet, the loading skeleton and the viewer with its
// "Changed on disk" pill. Light and dark at 412x892, and 320x640 at 1.6 text
// scale. Off by default; it writes files:
//
//   FILES_SHOTS=1 flutter test test/ui/files_flow_shots_test.dart
//
// Output: $FILES_SHOTS_DIR (default /tmp/files_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_listing.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:image/image.dart' as img;

import '../support/fake_fs.dart';
import '../support/files_support.dart';
import '../support/shot.dart' show loadAppFonts;

final _now = DateTime.utc(2026, 5, 20, 12);

Uint8List _picture(int hue, {int w = 96, int h = 72}) {
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    final t = p.x / image.width;
    p.setRgb(
      (60 + 160 * t + hue).round() % 256,
      (200 - 120 * t + hue ~/ 2).round() % 256,
      (90 + 100 * (p.y / image.height) + hue).round() % 256,
    );
  }
  return Uint8List.fromList(img.encodePng(image));
}

const _dir = '/home/dev/payments-api';

/// A project folder with a bit of everything: long and Vietnamese names,
/// pictures, hidden files, things changed minutes ago and months ago.
FakeFs _projectFs() {
  final fs = FakeFs();
  void file(String name, Duration ago, [Object content = 'x']) =>
      fs.addFile('$_dir/$name', content, modified: _now.subtract(ago));
  void dir(String name, Duration ago) => fs.nodes['$_dir/$name'] = FakeNode.dir(modified: _now.subtract(ago));

  fs.mkdirs(_dir);
  dir('lib', const Duration(minutes: 2));
  dir('test', const Duration(minutes: 38));
  dir('docs', const Duration(days: 12));
  dir('build', const Duration(days: 40));
  dir('Tài liệu thiết kế', const Duration(days: 3));
  dir('secret', const Duration(days: 90));
  file('payment_service_integration_with_the_ledger_and_retries....test.dart', const Duration(minutes: 4), 'x' * 8200);
  file('main.dart', const Duration(minutes: 7), 'x' * 2100);
  file('pubspec.yaml', const Duration(minutes: 25), 'x' * 940);
  file('screenshot 2026-05-20 at 09.30.png', const Duration(minutes: 12), _picture(0));
  file('diagram.png', const Duration(minutes: 55), _picture(90, w: 120, h: 60));
  file('Báo cáo tổng hợp quý ba năm 2026 bản cuối cùng đã chỉnh sửa.docx', const Duration(hours: 5), 'x' * 48000);
  file('Thiết kế giao diện.md', const Duration(hours: 9), 'x' * 3300);
  file('Đồng hồ đo hiệu năng.txt', const Duration(days: 2), 'x' * 700);
  file('Ảnh chụp màn hình.png', const Duration(days: 4), _picture(160, w: 80, h: 80));
  file('README.md', const Duration(days: 20), 'x' * 5200);
  file('release-2026-05-19-arm64-universal.apk', const Duration(days: 1), Uint8List(4 * 1024 * 1024));
  file('photo-from-the-phone.jpg', const Duration(days: 6), Uint8List(3 * 1024 * 1024));
  file('build.log', const Duration(minutes: 1), 'x' * 120000);
  file('notes.txt', const Duration(days: 30), 'x' * 40);
  file('.env', const Duration(days: 60), 'x' * 90);
  file('.gitignore', const Duration(days: 60), 'x' * 30);
  fs.deny.add('$_dir/secret');
  return fs;
}

void main() {
  if (Platform.environment['FILES_SHOTS'] == null) {
    test('files shots are off (set FILES_SHOTS=1)', () {}, skip: 'set FILES_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['FILES_SHOTS_DIR'] ?? '/tmp/files_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Widget home,
    Size size,
    Brightness brightness, {
    double scale = 1,
    Future<void> Function()? then,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: key, child: child!),
        ),
        home: home,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await then?.call();
    // Thumbnails decode on the engine's real clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size');
  }

  FileBrowserScreen browser(FakeFs fs, String path, {FileBrowserSession? session}) => FileBrowserScreen(
    machine: machineWithFiles(fs),
    path: path,
    session: session,
    clock: () => _now,
    thumbs: ThumbLoader(),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  final cases = <String, Future<void> Function(WidgetTester tester, Brightness b, Size size, double scale)>{
    'browser-recent': (tester, b, size, scale) => shoot(
      tester,
      'browser-recent',
      browser(_projectFs(), _dir),
      size,
      b,
      scale: scale,
      then: () async {
        await settle(tester);
        await tester.tap(find.text('Changed in the last hour'));
        await settle(tester);
      },
    ),
    'browser-name': (tester, b, size, scale) {
      final session = FileBrowserSession()..options.denied.add('$_dir/secret');
      return shoot(tester, 'browser-name', browser(_projectFs(), _dir, session: session), size, b, scale: scale, then: () => settle(tester));
    },
    'browser-modified': (tester, b, size, scale) {
      final session = FileBrowserSession()..options.setSort(FileSort.modified);
      return shoot(tester, 'browser-modified', browser(_projectFs(), _dir, session: session), size, b, scale: scale, then: () => settle(tester));
    },
    'browser-search': (tester, b, size, scale) => shoot(
      tester,
      'browser-search',
      browser(_projectFs(), _dir),
      size,
      b,
      scale: scale,
      then: () async {
        await settle(tester);
        await tester.enterText(find.byType(TextField), 'anh chup');
        await settle(tester);
      },
    ),
    'browser-no-match': (tester, b, size, scale) => shoot(
      tester,
      'browser-no-match',
      browser(_projectFs(), _dir),
      size,
      b,
      scale: scale,
      then: () async {
        await settle(tester);
        await tester.enterText(find.byType(TextField), 'invoice');
        await settle(tester);
      },
    ),
    'browser-nothing-recent': (tester, b, size, scale) {
      final fs = FakeFs()
        ..addFile('/home/dev/old/a.txt', 'x', modified: _now.subtract(const Duration(days: 3)))
        ..addFile('/home/dev/old/b.txt', 'x', modified: _now.subtract(const Duration(days: 9)));
      return shoot(
        tester,
        'browser-nothing-recent',
        browser(fs, '/home/dev/old'),
        size,
        b,
        scale: scale,
        then: () async {
          await settle(tester);
          await tester.tap(find.text('Changed in the last hour'));
          await settle(tester);
        },
      );
    },
    'browser-empty': (tester, b, size, scale) =>
        shoot(tester, 'browser-empty', browser(FakeFs()..addDir('/home/dev/empty'), '/home/dev/empty'), size, b, scale: scale, then: () => settle(tester)),
    'browser-one': (tester, b, size, scale) => shoot(
      tester,
      'browser-one',
      browser(FakeFs()..addFile('/home/dev/one/Thiết kế giao diện.md', 'x', modified: _now.subtract(const Duration(minutes: 3))), '/home/dev/one'),
      size,
      b,
      scale: scale,
      then: () => settle(tester),
    ),
    'browser-unreachable': (tester, b, size, scale) => shoot(
      tester,
      'browser-unreachable',
      browser(_projectFs()..fail = RemoteFileException(RemoteFileErrorKind.network, 'Connection lost: the host stopped answering'), _dir),
      size,
      b,
      scale: scale,
      then: () => settle(tester),
    ),
    'browser-no-permission': (tester, b, size, scale) => shoot(
      tester,
      'browser-no-permission',
      browser(_projectFs(), '$_dir/secret'),
      size,
      b,
      scale: scale,
      then: () => settle(tester),
    ),
    'browser-loading': (tester, b, size, scale) {
      final fs = _projectFs()..gate = Completer<void>();
      return shoot(
        tester,
        'browser-loading',
        browser(fs, _dir),
        size,
        b,
        scale: scale,
        then: () async => tester.pump(const Duration(milliseconds: 200)),
      );
    },
    'sort-sheet': (tester, b, size, scale) => shoot(
      tester,
      'sort-sheet',
      browser(_projectFs(), _dir),
      size,
      b,
      scale: scale,
      then: () async {
        await settle(tester);
        await tester.tap(find.text('Name'));
        await settle(tester);
      },
    ),
    'viewer-pill': (tester, b, size, scale) {
      final fs = _projectFs();
      const path = '$_dir/main.dart';
      fs.addFile(path, sampleDart, modified: _now.subtract(const Duration(minutes: 7)));
      final stat = RemoteStat(path: path, kind: RemoteEntryKind.file, size: fs.nodes[path]!.bytes.length, modified: fs.nodes[path]!.modified);
      return shoot(
        tester,
        'viewer-pill',
        FileViewerScreen(machine: machineWithFiles(fs), stat: stat),
        size,
        b,
        scale: scale,
        then: () async {
          await settle(tester);
          fs.addFile(path, sampleDart, modified: _now.subtract(const Duration(minutes: 1)));
          await tester.pump(const Duration(seconds: 16));
          await settle(tester);
        },
      );
    },
  };

  for (final entry in cases.entries) {
    for (final b in [Brightness.light, Brightness.dark]) {
      for (final (size, scale) in [(const Size(412, 892), 1.0), (const Size(320, 640), 1.6)]) {
        testWidgets('${entry.key} ${b.name} ${size.width.toInt()}x${size.height.toInt()}', (tester) async {
          await entry.value(tester, b, size, scale);
        });
      }
    }
  }
}
