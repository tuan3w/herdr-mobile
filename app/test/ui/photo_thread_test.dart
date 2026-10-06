// Pictures in a conversation: the viewer pages through the thread's pictures,
// says which message or tool produced each, and the composer's picture chips
// open the picture that will be sent.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_chips.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_model.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_image_cache.dart';
import 'package:herdr_mobile/ui/features/agent_session/photo_thread.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer_view_model.dart';

import '../support/fake_agent_session.dart';
import '../support/files_support.dart' show makePng;
import '../support/photo_support.dart';
import '../support/shot.dart' show loadAppFonts;

Future<ImageBlock> _png(WidgetTester tester, int w, int h, {String? uri, String mime = 'image/png'}) async {
  final bytes = await makePng(tester, w, h);
  return ImageBlock(data: base64Encode(bytes), mimeType: mime, uri: uri);
}

AgentSessionState _thread(List<ImageBlock> blocks) => AgentSessionState(
  's1',
  items: [
    TranscriptMessage(key: 'm1', role: MessageRole.user, blocks: [const TextBlock('look'), blocks[0]], at: DateTime(2026, 5, 20, 9, 30)),
    TranscriptTool(
      ToolCall(
        toolCallId: 't1',
        title: 'Read screenshot.png',
        kind: ToolKind.read,
        status: ToolStatus.completed,
        content: [ToolContentBlock(blocks[1])],
      ),
    ),
    TranscriptMessage(key: 'm2', role: MessageRole.agent, blocks: [blocks[2], const TextBlock('done')]),
    // A bare uri is a link, not a picture: it is not paged to.
    const TranscriptMessage(key: 'm3', role: MessageRole.agent, blocks: [ImageBlock(data: '', mimeType: 'image/png', uri: 'https://x.test/a.png')]),
  ],
);

Future<void> _pumpThread(WidgetTester tester, FakeAgentSession session, List<ImageBlock> blocks) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      theme: AppTheme.light(),
      home: Scaffold(
        body: ThreadPhotos(
          session: session,
          child: Column(children: [for (final b in blocks) ImageBlockView(block: b)]),
        ),
      ),
    ),
  );
  await pumpUntil(tester, () => find.byType(RawImage).evaluate().length == blocks.length);
}

void main() {
  setUpAll(loadAppFonts);
  late ImagePreviewCache saved;
  setUp(() => saved = ImagePreviewCache.shared);
  tearDown(() {
    ImagePreviewCache.shared.clear();
    ImagePreviewCache.shared = saved;
  });

  group('the pictures of a thread', () {
    testWidgets('in the order of the conversation, with where each came from', (tester) async {
      final blocks = [await _png(tester, 40, 30), await _png(tester, 50, 30), await _png(tester, 60, 30)];
      final photos = threadPhotos(_thread(blocks), agentLabel: 'omp');
      expect(photos.map((p) => p.block), orderedEquals(blocks), reason: 'message, tool result, message; the bare uri is skipped');
      expect(photos[0].origin, startsWith('You attached it · May 20, 2026 at 09:30'));
      expect(photos[1].origin, 'Tool result · Read screenshot.png');
      expect(photos[2].origin, 'Sent by omp');
    });

    testWidgets('what an agent writes in a title or a name cannot hide anything', (tester) async {
      final block = await _png(tester, 40, 30);
      final state = AgentSessionState(
        's',
        items: [
          TranscriptTool(
            ToolCall(
              toolCallId: 't',
              title: 'Read a\u202Etxt.png',
              status: ToolStatus.completed,
              content: [ToolContentBlock(block)],
            ),
          ),
        ],
      );
      final origin = threadPhotos(state, agentLabel: 'omp').single.origin;
      expect(origin, isNot(contains('\u202E')));
      expect(origin, contains('U+202E'));
    });

    test('a name is the uri\'s last segment, else image-N with the right extension', () {
      expect(imageExtension('image/png'), 'png');
      expect(imageExtension('image/webp'), 'webp');
      expect(imageExtension('image/jpeg'), 'jpg');
      expect(imageExtension(''), 'jpg');
      expect(imageExtension('IMAGE/GIF; charset=x'), 'gif');
      const withName = ImageBlock(data: 'AAAA', mimeType: 'image/png', uri: 'file:///home/dev/Hà Nội/chart.png');
      const without = ImageBlock(data: 'AAAA', mimeType: 'image/webp');
      expect(chatPhotoItem(const ThreadPhoto(block: withName, origin: 'o'), 1).name, 'chart.png');
      expect(chatPhotoItem(const ThreadPhoto(block: without, origin: 'o'), 4).name, 'image-4.webp');
    });
  });

  group('opening from the transcript', () {
    testWidgets('a tap opens the viewer on that picture, among all the thread\'s, with the tool named in the info', (tester) async {
      final blocks = [await _png(tester, 40, 30), await _png(tester, 50, 30), await _png(tester, 60, 30)];
      final session = FakeAgentSession(state: _thread(blocks), agentLabel: 'omp');
      await _pumpThread(tester, session, blocks);

      await tester.tap(find.byType(RawImage).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PhotoViewer), findsOneWidget);
      final model = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
      expect(model.count, 3, reason: 'all the pictures of the thread');
      expect(model.index, 1, reason: 'the one that was tapped');
      expect(find.text('Photo 2 of 3'), findsOneWidget);
      await pumpUntil(tester, () => model.currentEntry.ready);
      await tester.pump(const Duration(milliseconds: 50));

      await tester.tap(find.byTooltip('Photo info'));
      await tester.pumpAndSettle();
      expect(find.text('Tool result · Read screenshot.png'), findsOneWidget, reason: 'which tool produced it');
      expect(find.text('image-2.png'), findsWidgets);
      expect(find.text('Dimensions'), findsOneWidget);
      expect(find.text('50 × 30'), findsOneWidget);
    });

    testWidgets('while the picture loads the inline preview stands in for it', (tester) async {
      final blocks = [await _png(tester, 40, 30), await _png(tester, 50, 30), await _png(tester, 60, 30)];
      final session = FakeAgentSession(state: _thread(blocks));
      await _pumpThread(tester, session, blocks);
      final item = chatPhotoItem(ThreadPhoto(block: blocks[0], origin: 'o'), 1);
      final holder = item.placeholder!();
      expect(holder, isNotNull, reason: 'the decoded preview is cloned for the viewer');
      expect(holder!.width, 40);
      holder.dispose();
      final unseen = chatPhotoItem(ThreadPhoto(block: const ImageBlock(data: 'AAAA', mimeType: 'image/png'), origin: 'o'), 2);
      expect(unseen.placeholder!(), isNull, reason: 'nothing decoded: nothing to show');
    });

    testWidgets('outside a transcript the picture opens alone', (tester) async {
      final block = await _png(tester, 40, 30);
      usePhoneSurface(tester);
      await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: Scaffold(body: ImageBlockView(block: block))));
      await pumpUntil(tester, () => find.byType(RawImage).evaluate().isNotEmpty);
      await tester.tap(find.byType(RawImage));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final model = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
      expect(model.count, 1);
      expect(find.text('Photo 1 of 1'), findsNothing);
    });

    testWidgets('a picture too large to show says so in the viewer instead of failing silently', (tester) async {
      // 13 MB of base64 text decodes to ~9.7 MB: under the cap; use a block that
      // claims more than the 12 MB cap through its padding.
      final huge = ImageBlock(data: 'A' * (17 * 1024 * 1024), mimeType: 'image/png');
      final item = chatPhotoItem(ThreadPhoto(block: huge, origin: 'Sent by omp'), 1);
      final model = PhotoViewerViewModel(items: [item], export: FakeExport())..setViewport(const Size(412, 892), 2.625);
      addTearDown(model.dispose);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      expect(model.currentEntry.failure!.kind, PhotoFailureKind.tooLarge);
      expect(model.currentEntry.failure!.message, contains('Too large to show here'));
    });
  });

  group('attachments', () {
    testWidgets('a ready picture chip opens the picture that will be sent', (tester) async {
      usePhoneSurface(tester);
      final session = FakeAgentSession();
      final jpeg = jpegWithExif(64, 48);
      final attachments = ComposerAttachments(
        session: session,
        picker: _Picker(PickedPhoto(path: '/cache/image_picker/IMG_2031.jpg', name: 'IMG_2031.jpg', size: jpeg.length)),
        prepare: (input) async => PreparedImage(bytes: input, width: 64, height: 48),
        readFile: (_) async => jpeg,
      );
      addTearDown(attachments.dispose);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: AttachmentChips(attachments: attachments)))),
      );
      await tester.runAsync(() => attachments.addPhoto(camera: false));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('IMG_2031.jpg'), findsOneWidget);

      await tester.tap(find.text('IMG_2031.jpg'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PhotoViewer), findsOneWidget);
      final model = tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;
      expect(model.current.name, 'IMG_2031.jpg');
      await pumpUntil(tester, () => model.currentEntry.ready);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byTooltip('Photo info'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Attached to your message'), findsOneWidget);
      expect(find.text('64 × 48'), findsOneWidget);
    });
  });
}

class _Picker implements AttachPicker {
  _Picker(this.photoToGive);

  final PickedPhoto photoToGive;

  @override
  Future<PickedPhoto?> photo() async => photoToGive;

  @override
  Future<PickedPhoto?> camera() async => photoToGive;
}
