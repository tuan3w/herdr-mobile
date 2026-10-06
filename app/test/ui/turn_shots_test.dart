// Renders the turn model to PNGs for review (light and dark, 412x892 and
// 320x640, text scale 1 and 1.6): a finished turn folded and expanded, a live
// turn with its status line, 40 tool calls, a failed command, a long file
// path, a 300-file Changed card, Vietnamese, a call waiting for permission and
// the since-you-left divider. Off by default; it writes files:
//
//   TURN_SHOTS=1 flutter test test/ui/turn_shots_test.dart
//
// Output: $TURN_SHOTS_DIR (default /tmp/turn_shots)/<case>-<light|dark>-<w>x<h>-<scale>.png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/last_seen.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import '../support/turn_fixtures.dart';

void main() {
  if (Platform.environment['TURN_SHOTS'] == null) {
    test('turn shots are off (set TURN_SHOTS=1)', () {}, skip: 'set TURN_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['TURN_SHOTS_DIR'] ?? '/tmp/turn_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });
  tearDown(() => statusNow = DateTime.now);

  Future<void> shoot(
    WidgetTester tester,
    String name,
    FakeAgentSession session,
    Size size,
    Brightness brightness,
    double scale, {
    Future<void> Function()? then,
    SinceLeft? sinceLeft,
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
        builder: (context, child) => RepaintBoundary(
          key: key,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: sinceLeft == null
            ? AgentSessionScreen(key: ObjectKey(session), session: session)
            : Builder(
                builder: (context) => Scaffold(
                  backgroundColor: context.ds.bg,
                  body: SafeArea(child: TranscriptView(session: session, sinceLeft: sinceLeft)),
                ),
              ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await then?.call();
    await tester.pump(const Duration(milliseconds: 600));
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}-${scale == 1 ? '1' : scale}';
      await File('$out/$name-${brightness.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${brightness.name} $size $scale');
  }

  FakeAgentSession session(List<TranscriptItem> items, {bool live = false, List<PendingRequest> pending = const []}) {
    statusNow = () => at(live ? 95 : 100);
    return FakeAgentSession(state: stateWith(items: items, turnActive: live, pending: pending))
      ..turnStart = live ? t0 : null;
  }

  Future<void> openFold(WidgetTester tester) async {
    // The fold line can be above the screen (a long turn at a large text size).
    for (var i = 0; i < 4; i++) {
      await tester.fling(find.byType(TranscriptView), const Offset(0, 800), 4000);
      await tester.pump(const Duration(milliseconds: 300));
    }
    await tester.tap(find.textContaining('Worked'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  // The scenarios; each builds its own session.
  final scenarios = <String, (FakeAgentSession Function(), Future<void> Function(WidgetTester)?)>{
    'folded': (() => session(richTurn()), null),
    'expanded': (() => session(richTurn()), openFold),
    'live': (
      () => session([
        userAt('u', 'Fix the Hà Nội locale bug in the parser and add a test.', 0),
        thoughtAt('th', 'Looking at the parser first. Then the tests.', 1),
        readAt('r1', '/home/dev/payments-api/lib/locale/parse.dart', 4),
        editAt('e1', '/home/dev/payments-api/lib/locale/parse.dart', 12, before: 'a\nb\n', after: 'a\nB\nc\n'),
        agentAt('n', 'Now I run the tests to see if the fix holds.', 20),
        toolAt(
          'c',
          title: 'flutter test',
          kind: ToolKind.execute,
          status: ToolStatus.inProgress,
          rawInput: {'command': 'flutter test test/locale_test.dart'},
          start: 80,
        ),
      ], live: true),
      null,
    ),
    'tools40': (
      () => session([
        userAt('u', 'Audit every module for the locale bug.', 0),
        for (var i = 0; i < 40; i++)
          switch (i % 5) {
            0 => readAt('t$i', '/home/dev/payments-api/lib/module_$i/file_$i.dart', i * 2),
            1 => readAt('t$i', '/home/dev/payments-api/lib/module_$i/other_$i.dart', i * 2),
            2 => searchAt('t$i', 'toLowerCase', i * 2, hits: i),
            3 => editAt('t$i', '/home/dev/payments-api/lib/module_$i/file_$i.dart', i * 2),
            _ => runAt('t$i', 'dart analyze lib/module_$i', i * 2, exitCode: 0),
          },
        agentAt('a', 'Audited 40 steps; every module is clean.', 90),
      ]),
      openFold,
    ),
    'failed': (
      () => session([
        userAt('u', 'Run the tests.', 0),
        runAt(
          'c',
          'flutter test --no-pub --coverage test/locale_test.dart',
          3,
          end: 30,
          exitCode: 1,
          output: 'loading\n00:02 +11 -1: locale handles Hà Nội [E]\n  Expected: Hà Nội, Actual: ha noi\n',
        ),
        toolAt('k', title: 'sleep 600', kind: ToolKind.execute, status: ToolStatus.cancelled, start: 31),
        const TranscriptStop(key: 'stop', reason: StopReason.maxTokens),
        agentAt('a', 'One test fails: the fixture expects the old output.', 33),
      ]),
      null,
    ),
    'longpath': (
      () => session([
        userAt('u', 'Move the helpers.', 0),
        readAt(
          'r',
          '/home/dev/payments-api/packages/internal_localisation_helpers/lib/src/normalization/very_long_directory_name/unicode_normalization_form_composition_tables.dart',
          3,
        ),
        editAt(
          'e',
          '/home/dev/payments-api/packages/internal_localisation_helpers/lib/src/normalization/very_long_directory_name/unicode_normalization_form_composition_tables.dart',
          6,
          before: 'a\n',
          after: 'b\nc\n',
        ),
        agentAt('a', 'Moved.', 9),
      ]),
      openFold,
    ),
    'changed300': (
      () => session([
        userAt('u', 'Rename the package everywhere.', 0),
        for (var i = 0; i < 300; i++)
          editAt('e$i', '/home/dev/payments-api/lib/feature_${i ~/ 10}/screen_$i.dart', 3 + i, before: 'import old;\n', after: 'import new;\n'),
        agentAt('a', 'Renamed the package in 300 files.', 400),
      ]),
      null,
    ),
    'vietnamese': (
      () => session([
        userAt('u', 'Sửa lỗi hiển thị “Tiếng Việt” trong tệp vi-VN.json ở thư mục Hà Nội.', 0),
        thoughtAt('th', 'Đọc tệp trước. Sau đó sửa lỗi.', 1),
        agentAt('n', 'Tôi đọc tệp trước rồi mới sửa.', 2),
        readAt('r', '/home/dev/đường-dẫn/thư-mục/vi-VN.json', 3),
        editAt('e', '/home/dev/đường-dẫn/thư-mục/vi-VN.json', 5, before: '"ha noi"\n', after: '"Hà Nội"\n'),
        runAt('c', 'dart test --name "Hà Nội"', 8, exitCode: 0),
        agentAt('a', 'Đã sửa xong: **Hà Nội** hiển thị đúng dấu. Chạy lại bài kiểm tra: qua hết.', 11),
      ]),
      openFold,
    ),
    'waiting': (
      () => session(
        [
          userAt('u', 'Clean the build folder.', 0),
          readAt('r', '/home/dev/payments-api/pubspec.yaml', 3),
          toolAt(
            't1',
            title: 'rm -rf build',
            kind: ToolKind.execute,
            status: ToolStatus.pending,
            rawInput: {'command': 'rm -rf build'},
            start: 6,
          ),
        ],
        live: true,
        pending: [PendingPermission(7, permissionRequest(title: 'rm -rf build', rawInput: {'command': 'rm -rf build'}))],
      ),
      null,
    ),
  };

  for (final brightness in Brightness.values) {
    for (final size in const [Size(412, 892), Size(320, 640)]) {
      for (final scale in const [1.0, 1.6]) {
        for (final entry in scenarios.entries) {
          testWidgets('${entry.key} ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
            final then = entry.value.$2;
            await shoot(
              tester,
              entry.key,
              entry.value.$1(),
              size,
              brightness,
              scale,
              then: then == null ? null : () => then(tester),
            );
          });
        }
        testWidgets('divider ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
          final items = [...richTurn(prefix: 'old'), ...richTurn(prefix: 'new')];
          final s = session(items);
          await shoot(
            tester,
            'divider',
            s,
            size,
            brightness,
            scale,
            sinceLeft: SinceLeft(
              since: at(0),
              steps: 13,
              tools: 11,
              messages: 2,
              stops: 0,
              notes: 0,
              needsYou: 0,
              firstUnseenKey: 'newu',
            ),
          );
        });
      }
    }
  }
}
