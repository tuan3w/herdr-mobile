import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/services/image_decode.dart' show DecodedImage;
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/code_panel.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_blocks.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_copy.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image_cache.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_locations.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_resource.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_target.dart';
import 'package:herdr_mobile/ui/features/agent_session/tool_rows.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_view.dart';
import 'package:herdr_mobile/ui/features/photos/photo_stage.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';
import '../support/turn_fixtures.dart';

// Content blocks on screen: pictures, links, embedded
// resources and locations the agents send, and copying a message.

/// Every tap the surface offered, as the screen's `MdActions` would receive it.
class Taps {
  final links = <String>[];
  final paths = <(String, int?)>[];
}

Widget host(Widget body, {Taps? taps, double textScale = 1}) => MaterialApp(
  theme: AppTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: MdActions(
      onLink: taps == null ? null : (context, url) => taps.links.add(url),
      onPath: taps == null ? null : (context, path, line) => taps.paths.add((path, line)),
      child: Padding(padding: const EdgeInsets.all(16), child: body),
    ),
  ),
);

/// A PNG of [w] x [h] pixels, as base64.
Future<String> pngBase64(WidgetTester tester, int w, int h) async {
  final data = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFF3366CC));
    final image = await recorder.endRecording().toImage(w, h);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return base64Encode(bytes!.buffer.asUint8List());
  });
  return data!;
}

/// Lets the real decoder and isolates finish, then draws the frame.
Future<void> until(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }
  expect(finder, findsWidgets);
}

/// A line whose title carries a mono detail is one rich text.
Finder rich(String text) => find.textContaining(text, findRichText: true);

String? clipboard;

void mockClipboard(WidgetTester tester) {
  clipboard = null;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
}

class _NoHttp extends HttpOverrides {
  int requests = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    requests++;
    throw StateError('the transcript must never fetch an address an agent names');
  }
}

late ui.Image _base;

/// A 4 x 4 bitmap of its own each time (a clone of [_base], so each can be disposed).
Future<DecodedImage> _fakeBitmap(Uint8List bytes, {required int maxDimension}) async =>
    DecodedImage(image: _base.clone(), width: 4, height: 4, downscaled: false);

void main() {
  late ImagePreviewCache saved;

  setUp(() => saved = ImagePreviewCache.shared);
  tearDown(() {
    ImagePreviewCache.shared.clear();
    ImagePreviewCache.shared = saved;
  });

  group('pictures', () {
    testWidgets('an inline preview keeps its aspect within 220 dp, and a tap opens the photo viewer', (tester) async {
      final data = await pngBase64(tester, 400, 800);
      final block = ImageBlock(data: data, mimeType: 'image/png');
      await tester.pumpWidget(host(ImageBlockView(block: block)));
      await until(tester, find.byType(RawImage));

      final size = tester.getSize(find.byType(RawImage));
      expect(size.height, lessThanOrEqualTo(imagePreviewMaxHeight));
      expect(size.width / size.height, closeTo(0.5, 0.01), reason: 'aspect kept');
      expect(tester.getSize(find.byType(PressBuilder)).shortestSide, greaterThanOrEqualTo(kMinTap));

      await tester.tap(find.byType(RawImage));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await until(tester, find.byType(PhotoStage));
      await until(tester, find.byTooltip('Photo info'));
      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Save or share'), findsOneWidget, reason: 'a picture from the chat can be saved and shared');
      expect(find.text('Fit'), findsNothing, reason: 'the old Fit / 100% chips are gone: a double tap zooms');

      final model = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
      for (var i = 0; i < 200 && !model.currentEntry.ready; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      expect(model.currentEntry.ready, isTrue);
      final stage = tester.state<PhotoStageState>(find.byType(PhotoStage));
      expect(stage.pose.scale, 1);
      final at = tester.getCenter(find.byType(PhotoStage));
      await tester.tapAt(at);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(at);
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(stage.pose.scale, greaterThan(1.05), reason: 'double tap zooms');

      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.byType(RawImage), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the preview says what it is to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      final data = await pngBase64(tester, 40, 30);
      final block = ImageBlock(data: data, mimeType: 'image/png', uri: 'file:///home/dev/Hà Nội/chart.png');
      await tester.pumpWidget(host(ImageBlockView(block: block)));
      await until(tester, find.byType(RawImage));
      expect(find.bySemanticsLabel('Image, image/png, chart.png'), findsOneWidget);
      handle.dispose();
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an http picture is never fetched: a line with the host, and a tap shows the whole address', (tester) async {
      final overrides = _NoHttp();
      HttpOverrides.global = overrides;
      addTearDown(() => HttpOverrides.global = null);
      final taps = Taps();
      const url = 'https://tracker.example.com/pixel.png?u=secret&token=abc';
      await tester.pumpWidget(
        host(const ImageBlockView(block: ImageBlock(data: '', mimeType: 'image/png', uri: url)), taps: taps),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(rich('Image'), findsOneWidget);
      expect(find.textContaining('tracker.example.com', findRichText: true), findsOneWidget);
      expect(find.textContaining('secret', findRichText: true), findsNothing, reason: 'the address is for the sheet');
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(Image), findsNothing);
      await tester.tap(rich('Image'));
      expect(taps.links, [url], reason: 'the link sheet gets the full address');
      expect(overrides.requests, 0);
      expect(taps.paths, isEmpty);
    });

    testWidgets('a file uri or an absolute path opens the file viewer path; another scheme does nothing', (tester) async {
      final taps = Taps();
      await tester.pumpWidget(
        host(
          Column(
            children: const [
              ImageBlockView(block: ImageBlock(data: '', mimeType: 'image/png', uri: 'file:///home/dev/shots/a%20b.png')),
              ImageBlockView(block: ImageBlock(data: '', mimeType: 'image/png', uri: '/tmp/out/c.png')),
              ImageBlockView(block: ImageBlock(data: '', mimeType: 'image/png', uri: 'ftp://host/d.png')),
            ],
          ),
          taps: taps,
        ),
      );
      await tester.pump();
      final lines = rich('Image');
      expect(lines, findsNWidgets(3));
      await tester.tap(lines.at(0));
      await tester.tap(lines.at(1));
      await tester.tap(lines.at(2));
      expect(taps.paths, [('/home/dev/shots/a b.png', null), ('/tmp/out/c.png', null)]);
      expect(taps.links, isEmpty);
      expect(find.byType(PressBuilder), findsNWidgets(2), reason: 'ftp is plain text');
    });

    testWidgets('malformed data, a non-image and an oversize one degrade to the line with a plain note', (tester) async {
      final big = 'A' * 17000000;
      await tester.pumpWidget(
        host(
          Column(
            children: [
              const ImageBlockView(block: ImageBlock(data: '!!! not base64 !!!', mimeType: 'image/png')),
              ImageBlockView(block: ImageBlock(data: base64Encode(utf8.encode('hello')), mimeType: 'image/png')),
              ImageBlockView(block: ImageBlock(data: big, mimeType: 'image/png')),
            ],
          ),
        ),
      );
      await until(tester, find.text('The picture data is not valid base64.'));
      await until(tester, find.textContaining('not an image this app can read'));
      await until(tester, find.textContaining('Too large to show here'));
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a block with no data and no uri says so', (tester) async {
      await tester.pumpWidget(host(const ImageBlockView(block: ImageBlock(data: '', mimeType: 'image/png'))));
      expect(find.text('The agent sent no picture data.'), findsOneWidget);
    });

    testWidgets('a 200-picture transcript holds a few bitmaps, not 200, and disposes what it lets go', (tester) async {
      _base = (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!;
      addTearDown(_base.dispose);
      final cache = ImagePreviewCache(decoder: _fakeBitmap);
      ImagePreviewCache.shared = cache;
      final blocks = [for (var i = 0; i < 200; i++) ImageBlock(data: 'AAAA', mimeType: 'image/png', uri: 'file:///p/$i.png')];
      await tester.pumpWidget(
        host(ListView.builder(itemCount: blocks.length, itemBuilder: (_, i) => ImageBlockView(block: blocks[i]))),
      );
      await until(tester, find.byType(RawImage));
      final seen = <ui.Image>[];
      for (var i = 0; i < 30; i++) {
        for (final raw in tester.widgetList<RawImage>(find.byType(RawImage))) {
          if (raw.image != null && !seen.contains(raw.image)) seen.add(raw.image!);
        }
        await tester.drag(find.byType(ListView), const Offset(0, -900));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
      final onScreen = find.byType(ImageBlockView).evaluate().length;
      expect(cache.bitmaps, lessThanOrEqualTo(imageCacheCapacity + onScreen + 1));
      expect(cache.length, lessThan(40));
      expect(seen.length, greaterThan(imageCacheCapacity), reason: 'many pictures went by');
      expect(seen.where((i) => i.debugDisposed).length, greaterThan(seen.length - imageCacheCapacity - onScreen - 2),
          reason: 'pictures that left are disposed');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the cache drops the least recently used, never one that is drawn', (tester) async {
      _base = (await tester.runAsync(() => createTestImage(width: 4, height: 4)))!;
      addTearDown(_base.dispose);
      final cache = ImagePreviewCache(capacity: 3, decoder: _fakeBitmap);
      final blocks = [for (var i = 0; i < 6; i++) ImageBlock(data: 'AAAA', mimeType: 'image/png', uri: 'file:///$i')];
      final images = <ui.Image>[];
      final held = cache.acquire(blocks[0]);
      for (var i = 1; i < 6; i++) {
        final e = cache.acquire(blocks[i]);
        await tester.pump();
        expect(e.loading, isFalse);
        images.add(e.image!.image);
        cache.release(e);
      }
      await tester.pump();
      expect(cache.length, 3);
      expect(held.image, isNotNull, reason: 'held entry stays although it is the oldest');
      expect(held.image!.image.debugDisposed, isFalse);
      expect(images.take(3).every((i) => i.debugDisposed), isTrue, reason: 'older ones were disposed');
      expect(images.skip(3).every((i) => !i.debugDisposed), isTrue);
      cache.release(held);
      expect(cache.length, 3, reason: 'within the capacity nothing is dropped');
      expect(held.image, isNotNull);
      final next = cache.acquire(ImageBlock(data: 'AAAA', mimeType: 'image/png', uri: 'file:///next'));
      expect(held.image, isNull, reason: 'a fourth entry pushes the oldest out');
      expect(cache.length, 3);
      cache.release(next);
      cache.clear();
    });

    test('base64 length without decoding, and the isolate path rejects what is not base64', () async {
      expect(base64DecodedLength('AAAA'), 3);
      expect(base64DecodedLength('AAA='), 2);
      expect(base64DecodedLength('AA=='), 1);
      expect(base64DecodedLength(''), 0);
      await expectLater(decodeImageData('${'A' * 70000}!'), throwsA(isA<ImageProblem>()));
      expect((await decodeImageData('A' * 70000)).length, 52500);
    });
  });

  group('resource links and embedded resources', () {
    testWidgets('a resource_link row routes by uri and says where it points', (tester) async {
      final taps = Taps();
      await tester.pumpWidget(
        host(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              ResourceLinkRow(
                block: ResourceLinkBlock(uri: 'file:///home/dev/export/session.html', name: 'session.html', mimeType: 'text/html'),
              ),
              ResourceLinkRow(block: ResourceLinkBlock(uri: '/home/dev/Hà Nội/báo cáo.md', name: 'báo cáo.md', title: 'Báo cáo tuần')),
              ResourceLinkRow(block: ResourceLinkBlock(uri: 'https://docs.example.com/a/guide', name: 'guide')),
              ResourceLinkRow(block: ResourceLinkBlock(uri: 'mailto:a@b.c', name: 'mail')),
            ],
          ),
          taps: taps,
        ),
      );
      expect(rich('session.html'), findsOneWidget);
      expect(rich('Báo cáo tuần'), findsOneWidget, reason: 'the title wins');
      expect(find.byIcon(LucideIcons.fileCode), findsOneWidget, reason: 'html is code');
      expect(find.byIcon(LucideIcons.link), findsOneWidget, reason: 'a web address with no file name is a link');
      await tester.tap(rich('session.html'));
      await tester.tap(rich('Báo cáo tuần'));
      await tester.tap(rich('guide'));
      await tester.tap(rich('mail'));
      expect(taps.paths, [('/home/dev/export/session.html', null), ('/home/dev/Hà Nội/báo cáo.md', null)]);
      expect(taps.links, ['https://docs.example.com/a/guide']);
      for (final name in ['session.html', 'Báo cáo tuần', 'guide']) {
        expect(
          tester.getSize(find.ancestor(of: rich(name), matching: find.byType(PressBuilder)).first).height,
          greaterThanOrEqualTo(kMinTap),
        );
      }
      expect(find.ancestor(of: rich('mail'), matching: find.byType(PressBuilder)), findsNothing);
    });

    testWidgets('hidden and bidi characters in a name show as escapes', (tester) async {
      await tester.pumpWidget(
        host(const ResourceLinkRow(block: ResourceLinkBlock(uri: 'file:///x', name: 'fdp.\u202Etxt'))),
      );
      expect(find.textContaining('\u202E', findRichText: true), findsNothing);
      expect(find.textContaining('U+202E', findRichText: true), findsOneWidget);
    });

    testWidgets('an embedded text shows 6 lines with Show all, and copies the whole text', (tester) async {
      mockClipboard(tester);
      final text = [for (var i = 1; i <= 10; i++) 'line $i của Hà Nội'].join('\n');
      var expanded = false;
      var toggles = 0;
      late StateSetter set;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              set = setState;
              return EmbeddedResourceView(
                block: EmbeddedResourceBlock(uri: 'file:///home/dev/notes.txt', mimeType: 'text/plain', text: text),
                expanded: expanded,
                onToggle: () {
                  toggles++;
                  expanded = !expanded;
                },
              );
            },
          ),
        ),
      );
      expect(rich('notes.txt'), findsOneWidget);
      expect(find.text('line 6 của Hà Nội'), findsOneWidget);
      expect(find.text('line 7 của Hà Nội'), findsNothing);
      expect(find.text('4 more lines'), findsOneWidget);
      await tester.tap(find.text('Show all'));
      set(() {});
      await tester.pump();
      expect(toggles, 1);
      expect(find.text('line 10 của Hà Nội'), findsOneWidget);
      expect(find.text('Show less'), findsOneWidget);

      await tester.tap(find.byIcon(LucideIcons.copy));
      await tester.pump();
      expect(clipboard, text);
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a short embedded text has no foot; a blob is a line with its size', (tester) async {
      await tester.pumpWidget(
        host(
          Column(
            children: [
              EmbeddedResourceView(
                block: const EmbeddedResourceBlock(uri: 'file:///a/b.txt', text: 'one\ntwo'),
                expanded: false,
                onToggle: () {},
              ),
              EmbeddedResourceView(
                block: EmbeddedResourceBlock(uri: 'file:///a/data.bin', mimeType: 'application/octet-stream', blob: 'A' * 2048),
                expanded: false,
                onToggle: () {},
              ),
            ],
          ),
        ),
      );
      expect(find.text('Show all'), findsNothing);
      expect(find.byIcon(LucideIcons.copy), findsNothing);
      expect(find.textContaining('1.5 KB', findRichText: true), findsOneWidget);
      expect(find.byType(CodePanel), findsOneWidget);
    });

    testWidgets('the dispatcher keeps the lines for audio and unknown content', (tester) async {
      await tester.pumpWidget(
        host(
          Column(
            children: const [
              ContentBlockView(block: AudioBlock(data: '', mimeType: 'audio/wav')),
              ContentBlockView(block: UnknownBlock('hologram', {})),
            ],
          ),
        ),
      );
      expect(rich('Audio'), findsOneWidget);
      expect(rich('Content this app can’t show'), findsOneWidget);
    });
  });

  group('locations', () {
    testWidgets('path:line rows open the file at the line; four at most, then N more', (tester) async {
      final taps = Taps();
      final locations = [
        const ToolLocation(path: '/home/dev/payments-api/lib/locale/parse.dart', line: 42),
        const ToolLocation(path: 'lib/b.dart'),
        const ToolLocation(path: '/home/dev/Hà Nội/tệp.dart', line: 7),
        const ToolLocation(path: 'lib/d.dart', line: 1),
        const ToolLocation(path: 'lib/e.dart', line: 2),
        const ToolLocation(path: 'lib/f.dart', line: 3),
      ];
      await tester.pumpWidget(host(ToolLocationRows(locations: locations), taps: taps));
      expect(rich('parse.dart:42'), findsOneWidget);
      expect(rich('e.dart:2'), findsNothing);
      expect(find.text('+2 more'), findsOneWidget);
      expect(find.byType(PressBuilder), findsNWidgets(4));
      for (final row in find.byType(PressBuilder).evaluate()) {
        expect(tester.getSize(find.byElementPredicate((e) => e == row)).height, greaterThanOrEqualTo(kMinTap));
      }
      await tester.tap(rich('parse.dart:42'));
      await tester.tap(rich('b.dart'));
      await tester.tap(rich('tệp.dart:7'));
      expect(taps.paths, [
        ('/home/dev/payments-api/lib/locale/parse.dart', 42),
        ('lib/b.dart', null),
        ('/home/dev/Hà Nội/tệp.dart', 7),
      ]);
    });

    testWidgets('without a handler the rows are plain text', (tester) async {
      await tester.pumpWidget(host(const ToolLocationRows(locations: [ToolLocation(path: 'lib/a.dart', line: 3)])));
      expect(rich('a.dart:3'), findsOneWidget);
      expect(find.byType(PressBuilder), findsNothing);
    });

    testWidgets('a long folder shrinks and the file name and line stay whole at 1.6x text', (tester) async {
      final deep = '/${List.filled(14, 'very-long-folder-name').join('/')}/final_file.dart';
      await tester.pumpWidget(
        host(ToolLocationRows(locations: [ToolLocation(path: deep, line: 123)]), taps: Taps(), textScale: 1.6),
      );
      final shown = tester.widget<RichText>(rich('final_file.dart:123')).text.toPlainText();
      expect(shown, startsWith('…'), reason: 'the front of the path gave way');
      expect(shown, endsWith('/final_file.dart:123'));
      expect(tester.takeException(), isNull);
    });
  });

  group('copying', () {
    const source = '# Title\n\nSome **bold** and `code` here.\n\n- one\n- two\n\n```dart\nvoid main() {}\n```\n';

    Future<FakeAgentSession> pump(WidgetTester tester, List<TranscriptItem> items) async {
      tester.view.physicalSize = const Size(412, 892) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final session = FakeAgentSession(state: stateWith(items: items));
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: Scaffold(body: TranscriptView(session: session))),
      );
      await tester.pump(const Duration(milliseconds: 100));
      return session;
    }

    Future<void> longPressOn(WidgetTester tester, String text, {Finder? target}) async {
      final at = tester.getTopLeft(target ?? rich(text)) + const Offset(12, 10);
      await tester.longPressAt(at);
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> tapToolbar(WidgetTester tester, String label) async {
      if (find.text(label).hitTestable().evaluate().isEmpty) {
        // The toolbar ran out of room: the rest is behind its overflow button.
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(label));
      await tester.pump();
    }

    testWidgets('a long press on answer text still selects the word, and the toolbar carries the copy choices', (tester) async {
      mockClipboard(tester);
      await pump(tester, [userAt('u', 'Question', 0), agentAt('a', source, 3)]);
      await longPressOn(tester, 'Some');
      final region = tester.state<SelectableRegionState>(find.byType(SelectableRegion).first);
      expect(
        region.contextMenuButtonItems.where((i) => i.type == ContextMenuButtonType.copy),
        isNotEmpty,
        reason: 'SelectionArea kept the long press: a word is selected',
      );
      expect(find.text('Copy message'), findsOneWidget, reason: 'the toolbar carries it');
      await tapToolbar(tester, 'Copy as Markdown');
      expect(clipboard, source, reason: 'the Markdown source, byte for byte');
      expect(find.text('Copied as Markdown'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('Copy message puts the answer on the clipboard without its Markdown marks', (tester) async {
      mockClipboard(tester);
      await pump(tester, [agentAt('a', source, 3)]);
      await longPressOn(tester, 'Some');
      await tapToolbar(tester, 'Copy message');
      expect(clipboard, parseMd(source).plainText);
      expect(clipboard, isNot(contains('**')));
      expect(clipboard, contains('Some bold and code here.'));
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a message the person typed copies as typed, with no Markdown choice', (tester) async {
      mockClipboard(tester);
      await pump(tester, [userAt('u', 'Fix **this** now, please', 0), agentAt('a', 'ok', 3)]);
      await longPressOn(tester, 'Fix');
      expect(find.text('Copy as Markdown'), findsNothing);
      await tapToolbar(tester, 'Copy message');
      expect(clipboard, 'Fix **this** now, please');
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a long press elsewhere (a tool panel) gets no message actions', (tester) async {
      await pump(tester, [
        userAt('u', 'Run it', 0),
        runAt('c', 'flutter test', 2, exitCode: 1, output: 'FAILED: something broke\n'),
        agentAt('a', 'ok', 3),
      ]);
      await tester.tap(find.text('flutter test'));
      await tester.pumpAndSettle();
      await longPressOn(tester, '', target: find.text('FAILED: something broke'));
      expect(find.text('Copy message'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a screen reader gets Copy message on the answer, and the sheet copies text or Markdown', (tester) async {
      final handle = tester.ensureSemantics();
      mockClipboard(tester);
      await pump(tester, [agentAt('a', source, 3)]);

      SemanticsNode? find0() {
        SemanticsNode? found;
        void visit(SemanticsNode node) {
          final data = node.getSemanticsData();
          for (final id in data.customSemanticsActionIds ?? const <int>[]) {
            if (CustomSemanticsAction.getAction(id)!.label == 'Copy message') found ??= node;
          }
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!);
        return found;
      }

      final node = find0();
      expect(node, isNotNull, reason: 'the custom action is on the answer');
      final id = CustomSemanticsAction.getIdentifier(const CustomSemanticsAction(label: 'Copy message'));
      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(node!.id, SemanticsAction.customAction, id);
      await tester.pumpAndSettle();
      expect(find.text('Message'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      await tester.tap(find.text('Copy as Markdown'));
      await tester.pumpAndSettle();
      expect(clipboard, source);

      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(find0()!.id, SemanticsAction.customAction, id);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy text'));
      await tester.pumpAndSettle();
      expect(clipboard, parseMd(source).plainText);
      await tester.pump(const Duration(seconds: 4));
      handle.dispose();
    });

    testWidgets('no copy button is drawn on a message', (tester) async {
      await pump(tester, [userAt('u', 'Q', 0), agentAt('a', 'A plain answer with no code.', 3)]);
      expect(find.byIcon(LucideIcons.copy), findsNothing);
      expect(find.bySemanticsLabel('Copy message'), findsNothing);
    });

    testWidgets('tool output and diffs get a quiet copy action in their More row', (tester) async {
      mockClipboard(tester);
      final output = [for (var i = 1; i <= 12; i++) 'out $i'].join('\n');
      await pump(tester, [
        userAt('u', 'Run it', 0),
        runAt('c', 'flutter test', 2, exitCode: 1, output: '$output\n'),
        agentAt('a', 'ok', 3),
      ]);
      await tester.tap(find.text('flutter test'));
      await tester.pumpAndSettle();
      final panels = find.byType(CodePanel);
      expect(panels, findsWidgets);
      final copy = find.descendant(of: panels, matching: find.byIcon(LucideIcons.copy));
      expect(copy, findsOneWidget, reason: 'the output has 12 lines; the command is one');
      expect(
        tester.getSize(find.ancestor(of: copy, matching: find.byType(PressBuilder)).first).shortestSide,
        greaterThanOrEqualTo(kMinTap),
      );
      expect(find.text('12 lines'), findsOneWidget);
      await tester.tap(copy);
      await tester.pump();
      expect(clipboard, contains('out 1\nout 2'));
      expect(clipboard, contains('out 12'));
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a diff panel copies its lines as shown', (tester) async {
      mockClipboard(tester);
      await tester.pumpWidget(
        host(
          DiffPanel(
            diff: ToolDiff(path: 'lib/a.dart', oldText: 'a\nb\nc\nd\ne\nf\n', newText: 'a\nB\nc\nd\ne\nf\ng\n'),
            all: false,
            onToggleAll: () {},
          ),
        ),
      );
      final copy = find.byIcon(LucideIcons.copy);
      expect(copy, findsOneWidget);
      await tester.tap(copy);
      await tester.pump();
      expect(clipboard, contains('- b'));
      expect(clipboard, contains('+ B'));
      await tester.pump(const Duration(seconds: 4));
    });
  });

  test('message copy texts', () {
    final agent = agentAt('a', '**x** `y`', 1);
    expect(messageMarkdown(agent), '**x** `y`');
    expect(messagePlainText(agent), 'x y');
    expect(messageHasMarkdown(agent), isTrue);
    final user = userAt('u', '**x**', 1);
    expect(messagePlainText(user), '**x**');
    expect(messageHasMarkdown(user), isFalse);
  });

  test('uri targets', () {
    expect(resolveContentUri(''), isNull);
    expect(resolveContentUri('https://a.b/c'), isA<WebTarget>());
    expect(resolveContentUri('https:///c'), isNull);
    expect(resolveContentUri('data:image/png;base64,AAAA'), isNull);
    expect(resolveContentUri('file://otherhost/etc/passwd'), isNull);
    expect((resolveContentUri('file://localhost/a/b') as PathTarget).path, '/a/b');
    expect((resolveContentUri('~/x.png') as PathTarget).path, '~/x.png');
    expect(contentBaseName('https://a.b/c/d.png?x=1'), 'd.png');
    expect(contentBaseName('/a/b/c.txt'), 'c.txt');
    expect(contentBaseName('https://a.b/'), 'a.b');
  });
}

