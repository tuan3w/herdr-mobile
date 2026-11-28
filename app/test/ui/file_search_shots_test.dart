// Renders the Files search to PNGs for review: the prompt, a search under way
// (first batch in, spinner going), many matches with long and Vietnamese names,
// the 2,000-match truncated end, nothing found, nothing changed in the last
// hour, a failure (not reachable), a folder that could not be read, and the
// browser's header with the Search action and the Photos chip. Light and dark
// at 412x892, and 320x640 at 1.6 text scale. Off by default; it writes files:
//
//   SEARCH_SHOTS=1 flutter test test/ui/file_search_shots_test.dart
//
// Output: $SEARCH_SHOTS_DIR (default /tmp/search_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
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
import 'package:herdr_mobile/data/models/remote_search.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';

import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/files_support.dart';
import '../support/shot.dart' show loadAppFonts;

const _dir = '/home/dev/payments-api';
final _now = DateTime(2026, 5, 20, 12);

RemoteEntry _file(String path, {Duration ago = const Duration(minutes: 3), int size = 2048}) => RemoteEntry(
  name: RemotePath.basename(path),
  path: path,
  kind: RemoteEntryKind.file,
  resolvedKind: RemoteEntryKind.file,
  size: size,
  modified: _now.subtract(ago),
);

RemoteEntry _folder(String path, {Duration ago = const Duration(hours: 2)}) => RemoteEntry(
  name: RemotePath.basename(path),
  path: path,
  kind: RemoteEntryKind.dir,
  resolvedKind: RemoteEntryKind.dir,
  modified: _now.subtract(ago),
);

/// Matches with the worst names a real tree has, spread over shallow and deep folders.
List<RemoteEntry> _matches(int n, {int offset = 0}) {
  const names = [
    'payment_service_integration_with_the_ledger_and_retries....test.dart',
    'Báo cáo tổng hợp quý ba năm 2026 bản cuối cùng đã chỉnh sửa.docx',
    'x.md',
    'main.dart',
    'Đồng hồ đo hiệu năng.txt',
    'screenshot 2026-05-20 at 09.30.png',
  ];
  const folders = [
    '',
    '/lib',
    '/lib/features/payments/data/repositories/ledger_entries/remote_sources',
    '/Tài liệu thiết kế/bản nháp/2026',
    '/a',
    '/docs/screens',
  ];
  return [
    for (var i = 0; i < n; i++)
      if ((i + offset) % 7 == 3)
        _folder('$_dir${folders[(i + offset) % folders.length]}/reports-${i + offset}', ago: Duration(hours: i + 1))
      else
        _file(
          '$_dir${folders[(i + offset) % folders.length]}/${names[(i + offset) % names.length]}',
          ago: Duration(minutes: 2 + 7 * (i + offset)),
          size: 120 + 1700 * (i + offset),
        ),
  ];
}

/// Matches for [query] with names whose match is far from both ends, so the cut
/// has to choose what to keep.
List<RemoteEntry> _namedLike(String query) {
  final names = [
    'payment_service_integration_${query}_with_the_ledger_and_retries....test.dart',
    '${query}_2026_q3.md',
    'Báo cáo tổng hợp quý ba năm 2026 bản cuối cùng đã $query sửa.docx',
    'a-very-long-prefix-before-the-part-you-typed-$query.txt',
    'x$query',
    '$query-${'z' * 60}.png',
  ];
  return [for (var i = 0; i < names.length; i++) _file('$_dir/lib/${names[i]}', ago: Duration(minutes: 2 + 7 * i))];
}

void main() {
  if (Platform.environment['SEARCH_SHOTS'] == null) {
    test('search shots are off (set SEARCH_SHOTS=1)', () {}, skip: 'set SEARCH_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['SEARCH_SHOTS_DIR'] ?? '/tmp/search_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  /// A search the test answers: [script] runs on listen and may hold the stream open.
  FakeTransport machine(void Function(StreamController<FileSearchEvent> c, FileSearchSpec spec) script) {
    final fs = FakeFs()..addDir(_dir);
    for (var i = 0; i < 9; i++) {
      fs.addFile('$_dir/shot-$i.png', Uint8List.fromList([1, 2, 3]));
    }
    return FakeTransport()
      ..fs = fs
      ..onSearch = (spec) {
        late final StreamController<FileSearchEvent> c;
        c = StreamController<FileSearchEvent>();
        scheduleMicrotask(() => script(c, spec));
        return c.stream;
      };
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    FakeTransport transport,
    Size size,
    Brightness brightness, {
    double scale = 1,
    String? type,
    String? chip,
    bool search = true,
    bool scrollEnd = false,
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
        home: FileBrowserScreen(
          machine: machineWithFiles(transport.fs, transport: transport),
          path: _dir,
          clock: () => _now,
          thumbs: ThumbLoader(),
        ),
      ),
    );
    Future<void> settle() async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    if (search) {
      await tester.tap(find.byTooltip('Search in payments-api'));
      await settle();
      if (type != null) {
        await tester.enterText(find.byType(TextField), type);
        await tester.pump(const Duration(milliseconds: 600));
      }
      if (chip != null) {
        await tester.tap(find.widgetWithText(AppChip, chip));
        await tester.pump();
      }
      await settle();
      if (scrollEnd) {
        for (var i = 0; i < 30; i++) {
          await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -4000));
          await tester.pump();
        }
        await settle();
      }
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size');
  }

  final cases = <String, Future<void> Function(WidgetTester tester, Brightness b, Size size, double scale)>{
    'prompt': (t, b, s, k) => shoot(t, 'prompt', machine((c, spec) {}), s, b, scale: k),
    'searching': (t, b, s, k) => shoot(
      t,
      'searching',
      machine((c, spec) => c.add(FileSearchBatch(_matches(3)))),
      s,
      b,
      scale: k,
      type: 'report',
    ),
    'loading-first': (t, b, s, k) => shoot(t, 'loading-first', machine((c, spec) {}), s, b, scale: k, type: 'report'),
    'results': (t, b, s, k) => shoot(
      t,
      'results',
      machine((c, spec) {
        c
          ..add(FileSearchBatch(_matches(14)))
          ..add(const FileSearchDone(scanned: 1234, truncated: false, skippedDirs: 0));
      }),
      s,
      b,
      scale: k,
      type: 'report',
    ),
    'match-report': (t, b, s, k) => shoot(
      t,
      'match-report',
      machine((c, spec) {
        c
          ..add(FileSearchBatch(_namedLike('report')))
          ..add(const FileSearchDone(scanned: 1234, truncated: false, skippedDirs: 0));
      }),
      s,
      b,
      scale: k,
      type: 'report',
    ),
    'match-viet': (t, b, s, k) => shoot(
      t,
      'match-viet',
      machine((c, spec) {
        c
          ..add(FileSearchBatch(_namedLike('chỉnh')))
          ..add(const FileSearchDone(scanned: 1234, truncated: false, skippedDirs: 0));
      }),
      s,
      b,
      scale: k,
      type: 'CHỈNH',
    ),
    'truncated-2000': (t, b, s, k) => shoot(
      t,
      'truncated-2000',
      machine((c, spec) {
        for (var i = 0; i < 20; i++) {
          c.add(FileSearchBatch(_matches(100, offset: i * 100)));
        }
        c.add(const FileSearchDone(scanned: 183204, truncated: true, skippedDirs: 3));
      }),
      s,
      b,
      scale: k,
      type: 'a',
    ),
    'empty': (t, b, s, k) => shoot(
      t,
      'empty',
      machine((c, spec) => c.add(const FileSearchDone(scanned: 842, truncated: false))),
      s,
      b,
      scale: k,
      type: 'invoice-final-v2-really-final-this-time',
    ),
    'empty-stopped': (t, b, s, k) => shoot(
      t,
      'empty-stopped',
      machine((c, spec) => c.add(const FileSearchDone(scanned: 3000, truncated: true))),
      s,
      b,
      scale: k,
      type: 'zz',
    ),
    'last-hour': (t, b, s, k) => shoot(
      t,
      'last-hour',
      machine((c, spec) {
        c
          ..add(FileSearchBatch(_matches(6)))
          ..add(const FileSearchDone(scanned: 4120, truncated: false));
      }),
      s,
      b,
      scale: k,
      chip: 'Last hour',
    ),
    'last-hour-empty': (t, b, s, k) => shoot(
      t,
      'last-hour-empty',
      machine((c, spec) => c.add(const FileSearchDone(scanned: 4120, truncated: false))),
      s,
      b,
      scale: k,
      chip: 'Last hour',
    ),
    'failed-offline': (t, b, s, k) => shoot(
      t,
      'failed-offline',
      machine((c, spec) {
        c
          ..add(FileSearchBatch(_matches(2)))
          ..addError(RemoteFileException(RemoteFileErrorKind.network, 'The connection was lost', path: _dir));
      }),
      s,
      b,
      scale: k,
      type: 'report',
    ),
    'failed-empty': (t, b, s, k) => shoot(
      t,
      'failed-empty',
      machine((c, spec) {
        c.addError(RemoteFileException(RemoteFileErrorKind.permission, 'denied', path: _dir));
      }),
      s,
      b,
      scale: k,
      type: 'report',
    ),
    'browser-header': (t, b, s, k) => shoot(t, 'browser-header', machine((c, spec) {}), s, b, scale: k, search: false),
    'truncated-footer': (t, b, s, k) => shoot(
      t,
      'truncated-footer',
      machine((c, spec) {
        for (var i = 0; i < 20; i++) {
          c.add(FileSearchBatch(_matches(100, offset: i * 100)));
        }
        c.add(const FileSearchDone(scanned: 183204, truncated: true, skippedDirs: 3));
      }),
      s,
      b,
      scale: k,
      type: 'a',
      scrollEnd: true,
    ),
  };

  for (final MapEntry(key: name, value: run) in cases.entries) {
    for (final (size, scale) in [(const Size(412, 892), 1.0), (const Size(320, 640), 1.6)]) {
      for (final b in Brightness.values) {
        testWidgets('$name ${b.name} ${size.width.toInt()}x${size.height.toInt()} x$scale', (tester) async {
          await run(tester, b, size, scale);
        });
      }
    }
  }
}
