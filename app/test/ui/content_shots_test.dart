// Renders the content the agents send to PNGs for review (light and dark,
// 412x892 and 320x640, text scale 1 and 1.6): pictures (inline, uri only,
// malformed, huge uri, 50 in a row, a 1 MB one), links and embedded resources,
// locations, tool output with its copy foot, and the copy toolbar and sheet.
// Off by default; it writes files:
//
//   CONTENT_SHOTS=1 flutter test test/ui/content_shots_test.dart
//
// Output: $CONTENT_SHOTS_DIR (default /tmp/content_shots)/<case>-<light|dark>-<w>x<h>-<scale>.png
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image_cache.dart';
import 'package:herdr_mobile/ui/features/agent_session/status_line.dart';
import 'package:herdr_mobile/ui/features/agent_session/tool_rows.dart' show ToolRow;
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import '../support/turn_fixtures.dart';

void main() {
  if (Platform.environment['CONTENT_SHOTS'] == null) {
    test('content shots are off (set CONTENT_SHOTS=1)', () {}, skip: 'set CONTENT_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['CONTENT_SHOTS_DIR'] ?? '/tmp/content_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });
  tearDown(() {
    statusNow = DateTime.now;
    ImagePreviewCache.shared.clear();
  });

  /// A picture: a vertical gradient with bars, as base64 PNG.
  Future<String> chart(WidgetTester tester, int w, int h, {bool noise = false}) async {
    final data = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
      if (noise) {
        final random = math.Random(7);
        final pixels = Uint8List(w * h * 4);
        for (var i = 0; i < pixels.length; i++) {
          pixels[i] = i % 4 == 3 ? 255 : random.nextInt(256);
        }
        final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
        final descriptor = ui.ImageDescriptor.raw(buffer, width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
        final codec = await descriptor.instantiateCodec();
        final frame = await codec.getNextFrame();
        final bytes = await frame.image.toByteData(format: ui.ImageByteFormat.png);
        return base64Encode(bytes!.buffer.asUint8List());
      }
      canvas.drawRect(
        rect,
        Paint()..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, const [Color(0xFF1B4DB3), Color(0xFF8A5CF6)]),
      );
      final bar = Paint()..color = const Color(0xCCFFFFFF);
      for (var i = 0; i < 6; i++) {
        final bw = w / 12;
        final bh = h * (0.2 + 0.12 * ((i * 5) % 6));
        canvas.drawRect(Rect.fromLTWH(w * 0.1 + i * bw * 1.6, h * 0.9 - bh, bw, bh), bar);
      }
      final image = await recorder.endRecording().toImage(w, h);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      return base64Encode(bytes!.buffer.asUint8List());
    });
    return data!;
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    FakeAgentSession session,
    Size size,
    Brightness brightness,
    double scale, {
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
        builder: (context, child) => RepaintBoundary(
          key: key,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) => Scaffold(
            backgroundColor: context.ds.bg,
            body: SafeArea(child: TranscriptView(session: session)),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    // Pictures decode off the main isolate: give them real time.
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    await then?.call();
    // A fling keeps scrolling: let it end, then let the rows it brought decode.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
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

  FakeAgentSession session(List<TranscriptItem> items, {bool live = false}) {
    statusNow = () => at(live ? 95 : 100);
    return FakeAgentSession(state: stateWith(items: items, turnActive: live))..turnStart = live ? t0 : null;
  }

  TranscriptMessage agentBlocks(String key, List<ContentBlock> blocks, int seconds) => TranscriptMessage(
    key: key,
    role: MessageRole.agent,
    messageId: key,
    blocks: blocks,
    at: at(seconds),
    endedAt: at(seconds + 1),
  );

  TranscriptMessage userBlocks(String key, List<ContentBlock> blocks, int seconds) => TranscriptMessage(
    key: key,
    role: MessageRole.user,
    blocks: blocks,
    at: at(seconds),
    endedAt: at(seconds),
  );

  /// Opens every tool row on screen (a turn that runs shows its log open).
  Future<void> openTools(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      final rows = find.byType(ToolRow);
      if (i >= rows.evaluate().length) break;
      await tester.tap(rows.at(i));
      await tester.pumpAndSettle();
    }
  }

  final longUri = 'https://cdn.example.com/${List.filled(40, 'segment-very-long').join('/')}/final-image.png?token=${'x' * 200}';
  const bidi = 'báo\u202Egnp.cáo\u202C dài.png';

  final scenarios = <String, Future<(FakeAgentSession, Future<void> Function()?)> Function(WidgetTester)>{
    'pictures': (tester) async {
      final big = await chart(tester, 800, 500);
      final tall = await chart(tester, 300, 900);
      final icon = await chart(tester, 48, 48);
      return (
        session([
          userBlocks('u', [
            const TextBlock('Đây là ảnh chụp màn hình lỗi, xem giúp tôi.'),
            ImageBlock(data: big, mimeType: 'image/png'),
          ], 0),
          agentBlocks('a1', [
            const TextBlock('Tôi thấy biểu đồ ở Hà Nội. Đây là bản vẽ lại:'),
            ImageBlock(data: big, mimeType: 'image/png', uri: 'file:///home/dev/Hà Nội/báo cáo.png'),
            ImageBlock(data: tall, mimeType: 'image/png'),
            ImageBlock(data: icon, mimeType: 'image/png'),
            const TextBlock('Và những ảnh không tải được:'),
            ImageBlock(data: '', mimeType: 'image/png', uri: 'https://tracker.example.com/pixel.png?u=secret'),
            ImageBlock(data: '', mimeType: 'image/png', uri: 'file:///home/dev/shots/a.png'),
            const ImageBlock(data: '!!not base64!!', mimeType: 'image/png'),
            ImageBlock(data: base64Encode(utf8.encode('not a png')), mimeType: 'image/jpeg'),
            ImageBlock(data: '', mimeType: 'image/png', uri: longUri),
            ImageBlock(data: '', mimeType: 'image/png', uri: '/home/dev/$bidi'),
          ], 3),
        ]),
        null,
      );
    },
    'pictures50': (tester) async {
      final small = await chart(tester, 160, 100);
      return (
        session([
          userAt('u', 'Chụp 50 ảnh.', 0),
          agentBlocks('a', [for (var i = 0; i < 50; i++) ImageBlock(data: small, mimeType: 'image/png')], 3),
        ]),
        () async {
          await tester.fling(find.byType(TranscriptView), const Offset(0, 600), 3000);
          await tester.pump(const Duration(milliseconds: 300));
        },
      );
    },
    'bigimage': (tester) async {
      final noise = await chart(tester, 480, 480, noise: true);
      return (
        session([
          userAt('u', 'Ảnh nhiễu 1 MB.', 0),
          agentBlocks('a', [ImageBlock(data: noise, mimeType: 'image/png'), const TextBlock('Xong.')], 3),
        ]),
        null,
      );
    },
    'resources': (tester) async {
      return (
        session([
          userAt('u', 'Xuất phiên và đọc ghi chú.', 0),
          agentBlocks('a', [
            const TextBlock('Đã xuất phiên. Các tệp liên quan:'),
            const ResourceLinkBlock(
              uri: 'file:///home/dev/export/session-2026-10-05.html',
              name: 'session-2026-10-05.html',
              mimeType: 'text/html',
              size: 483201,
            ),
            const ResourceLinkBlock(
              uri: '/home/dev/Hà Nội/báo cáo tuần.md',
              name: 'báo cáo tuần.md',
              title: 'Báo cáo tuần Hà Nội',
              description: 'Tóm tắt thay đổi và các lỗi còn lại.',
            ),
            const ResourceLinkBlock(uri: 'https://docs.example.com/guide/getting-started', name: 'guide'),
            ResourceLinkBlock(uri: longUri, name: 'x' * 90),
            const ResourceLinkBlock(uri: 'file:///x', name: 'fdp.\u202Etxt'),
            const ResourceLinkBlock(uri: 'mailto:someone@example.com', name: 'someone@example.com'),
            EmbeddedResourceBlock(
              uri: 'file:///home/dev/payments-api/NOTES.txt',
              mimeType: 'text/plain',
              text: [for (var i = 1; i <= 11; i++) 'Dòng $i: ghi chú về Hà Nội và việc chuẩn hóa tiếng Việt'].join('\n'),
            ),
            EmbeddedResourceBlock(uri: 'file:///home/dev/data.bin', mimeType: 'application/octet-stream', blob: 'A' * 4096),
          ], 3),
        ]),
        null,
      );
    },
    'locations': (tester) async {
      return (
        session([
          userAt('u', 'Find the parser.', 0),
          toolAt(
            't',
            title: 'Search parse',
            kind: ToolKind.search,
            locations: const [
              ToolLocation(path: '/home/dev/payments-api/lib/locale/parse.dart', line: 42),
              ToolLocation(path: 'lib/b.dart'),
              ToolLocation(path: '/home/dev/Hà Nội/tệp báo cáo.dart', line: 7),
              ToolLocation(path: '/home/dev/payments-api/packages/very-long-package-name/lib/src/some/deep/folder/final_file.dart', line: 1234),
              ToolLocation(path: 'lib/e.dart', line: 2),
              ToolLocation(path: 'lib/f.dart', line: 3),
            ],
            start: 3,
          ),
          agentAt('a', 'Found it in `parse.dart`.', 10),
        ], live: true),
        () => openTools(tester),
      );
    },
    'output': (tester) async {
      return (
        session([
          userAt('u', 'Run the tests.', 0),
          runAt(
            'c',
            'flutter test test/locale_test.dart',
            2,
            end: 40,
            exitCode: 1,
            output: [for (var i = 1; i <= 14; i++) '00:0$i +$i -1: locale handles Hà Nội line $i'].join('\n'),
          ),
          editAt('e', '/home/dev/payments-api/lib/locale/parse.dart', 50, before: 'a\nb\nc\nd\ne\nf\ng\n', after: 'a\nB\nc\nd\ne\nf\ng\nh\n'),
          agentAt('a', 'One failure left.', 60),
        ], live: true),
        () => openTools(tester),
      );
    },
    'copy-toolbar': (tester) async {
      return (
        session([
          userAt('u', 'Explain the fix.', 0),
          agentAt(
            'a',
            'The parser lowercased **before** normalizing, so `Hà Nội` lost its tone marks.\n\n- moved the call\n- added a test',
            3,
          ),
        ]),
        () async {
          final at = tester.getTopLeft(find.textContaining('lowercased', findRichText: true)) + const Offset(30, 10);
          await tester.longPressAt(at);
          await tester.pump(const Duration(milliseconds: 400));
        },
      );
    },
    'copy-overflow': (tester) async {
      return (
        session([
          userAt('u', 'Explain the fix.', 0),
          agentAt('a', 'The parser lowercased **before** normalizing, so `Hà Nội` lost its tone marks.', 3),
        ]),
        () async {
          final at = tester.getTopLeft(find.textContaining('lowercased', findRichText: true)) + const Offset(30, 10);
          await tester.longPressAt(at);
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();
        },
      );
    },
  };

  // The same transcript scrolled to its first rows: the picture the person sent
  // and the previews.
  scenarios['pictures-top'] = (tester) async {
    final (s, _) = await scenarios['pictures']!(tester);
    return (
      s,
      () async {
        for (var i = 0; i < 4; i++) {
          await tester.fling(find.byType(TranscriptView), const Offset(0, 900), 5000);
          await tester.pump(const Duration(milliseconds: 300));
        }
      },
    );
  };

  for (final brightness in Brightness.values) {
    for (final size in const [Size(412, 892), Size(320, 640)]) {
      for (final scale in const [1.0, 1.6]) {
        for (final entry in scenarios.entries) {
          testWidgets('${entry.key} ${brightness.name} ${size.width.toInt()} x$scale', (tester) async {
            final (s, then) = await entry.value(tester);
            await shoot(tester, entry.key, s, size, brightness, scale, then: then);
          });
        }
      }
    }
  }
}
