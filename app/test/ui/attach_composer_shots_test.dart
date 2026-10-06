// Renders the composer states to PNGs for review: idle, working with the
// delivery hint, queued messages (one held with its reason), attachments (two
// pictures and a file), the sign-in panel, and the compact layout. Light and
// dark at 412x892, 320x640 at 1.6 text scale, and 892x412 with the keyboard
// up. Off by default; it writes files:
//
//   ATTACH_SHOTS=1 flutter test test/ui/attach_composer_shots_test.dart
//
// Output: $ATTACH_SHOTS_DIR (default /tmp/attach_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/auth_needed.dart';
import 'package:herdr_mobile/ui/features/attach/attach_bars.dart';
import 'package:herdr_mobile/ui/features/attach/attach_kit.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:image/image.dart' as img;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/files_support.dart';
import '../support/shot.dart' show loadAppFonts;

class _Picker implements AttachPicker {
  _Picker(this.photos);

  final List<PickedPhoto> photos;

  @override
  Future<PickedPhoto?> photo() async => photos.isEmpty ? null : photos.removeAt(0);

  @override
  Future<PickedPhoto?> camera() async => null;
}

Uint8List _picture(int hue) {
  final image = img.Image(width: 96, height: 72);
  for (final p in image) {
    final t = p.x / image.width;
    p.setRgb(
      (60 + 160 * t + hue).round() % 256,
      (200 - 120 * t + hue ~/ 2).round() % 256,
      (90 + 100 * (p.y / image.height) + hue).round() % 256,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image));
}

/// What the system picker left in the app's cache, by path: the screen reads
/// a picked picture back from there.
final _cache = <String, Uint8List>{};

PickedPhoto _photo(String name, int hue) {
  final path = '/cache/image_picker/$name';
  final bytes = _cache[path] = _picture(hue);
  return PickedPhoto(path: path, name: name, size: bytes.length);
}

Future<PreparedImage> _prepare(Uint8List b) async => PreparedImage(bytes: b, width: 96, height: 72);

const _authNeeded = AuthNeeded(
  message: 'Claude Code needs you to sign in on the host.',
  agentMessage: 'Authentication required',
  methods: [
    AuthChoice(id: 'claude-login', name: 'Log in with Claude', terminal: true, terminalCommand: 'claude /login'),
    AuthChoice(id: 'api-key', name: 'Use an API key'),
  ],
);

List<TranscriptItem> _history() => [
  userMsg('u1', 'Fix the Hà Nội locale bug in the parser and add a test.'),
  toolItem('t0', title: 'Read lib/feature/parse.dart', kind: ToolKind.read),
  agentMsg('a1', 'I will move the call below `normalize()` and add a regression test for Hà Nội.'),
];

void main() {
  if (Platform.environment['ATTACH_SHOTS'] == null) {
    test('attach shots are off (set ATTACH_SHOTS=1)', () {}, skip: 'set ATTACH_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['ATTACH_SHOTS_DIR'] ?? '/tmp/attach_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    FakeAgentSession session,
    Size size,
    Brightness brightness, {
    double scale = 1,
    double keyboard = 0,
    AttachPicker? picker,
    Future<void> Function()? then,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    if (keyboard > 0) tester.view.viewInsets = FakeViewPadding(bottom: keyboard * dpr);
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
        home: AgentSessionScreen(
          key: ObjectKey(session),
          session: session,
          picker: picker ?? _Picker([]),
          prepare: _prepare,
          attachKit: FakeKit(gallery: FakeGallery(state: GalleryAccess.unavailable)).kit,
          readFile: (path) async => _cache[path]!,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(tapGuard);
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

  // The library cannot be read here (no plugin), so the sheet offers the
  // system picker, which is what feeds this test's pictures.
  Future<void> tapAttach(WidgetTester tester, String item) async {
    await tester.tap(find.byIcon(LucideIcons.paperclip).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // On a small screen with large text the panel is longer than the room
    // above the bars: a finger scrolls it.
    final target = find.text(item == 'Photo library' ? 'Open the system picker' : item);
    if (tester.getCenter(target).dy > tester.view.physicalSize.height / tester.view.devicePixelRatio - 150) {
      await tester.drag(find.byType(ListView).last, const Offset(0, -220));
      await tester.pump();
    }
    await tester.tap(find.text(item == 'Photo library' ? 'Open the system picker' : item));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Picks AGENTS.md in the sheet's Host tab and attaches it.
  Future<void> attachHostFile(WidgetTester tester, Size size) async {
    await tester.tap(find.byIcon(LucideIcons.paperclip).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(AttachTabBar.tabKey(AttachTab.host)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // From the grabber, just above the search field.
    await tester.dragFrom(Offset(size.width / 2, tester.getTopLeft(find.textContaining('Find in')).dy - 30), Offset(0, -size.height * 0.4));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('Show all files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('AGENTS.md'));
    await tester.pump();
    await tester.tap(find.textContaining('Attach ('));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> queue(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.byIcon(LucideIcons.listPlus));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  FakeAgentSession idle() => FakeAgentSession(state: stateWith(items: _history()));
  FakeAgentSession working() => FakeAgentSession(state: stateWith(items: _history(), turnActive: true));

  final cases = <String, Future<void> Function(WidgetTester tester, Brightness b, Size size, double scale, double kb)>{
    'idle': (tester, b, size, scale, kb) => shoot(tester, 'idle', idle(), size, b, scale: scale, keyboard: kb),
    'sheet': (tester, b, size, scale, kb) => shoot(
      tester,
      'sheet-no-images',
      FakeAgentSession(state: stateWith(items: _history()), machine: machineWithFiles(projectFs()))
        ..imagesAccepted = false,
      size,
      b,
      scale: scale,
      then: () async {
        await tester.tap(find.byIcon(LucideIcons.paperclip));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      },
    ),
    'working-queue-hint': (tester, b, size, scale, kb) => shoot(
      tester,
      'working-queue-hint',
      working(),
      size,
      b,
      scale: scale,
      keyboard: kb,
      then: () async => tester.enterText(find.byType(TextField).last, 'Then run the linter on the whole repo'),
    ),
    'working-steer-hint': (tester, b, size, scale, kb) => shoot(
      tester,
      'working-steer-hint',
      working()..steerable = true,
      size,
      b,
      scale: scale,
      keyboard: kb,
      then: () async => tester.tap(find.byType(TextField).last),
    ),
    'queued': (tester, b, size, scale, kb) {
      final session = working();
      return shoot(
        tester,
        'queued-two-one-held',
        session,
        size,
        b,
        scale: scale,
        keyboard: kb,
        then: () async {
          await queue(tester, 'Sau đó chạy toàn bộ test và gửi cho tôi kết quả, kèm theo cả những test bị bỏ qua nữa nhé');
          session.cancel();
          session.update((s) => s.withTurnStarted());
          await tester.pump();
          await queue(tester, 'And update the changelog, then tag it');
          await tester.enterText(find.byType(TextField).last, 'A draft I am still typing');
        },
      );
    },
    'attachments': (tester, b, size, scale, kb) {
      final session = idle();
      return shoot(
        tester,
        'attachments',
        session,
        size,
        b,
        scale: scale,
        keyboard: kb,
        picker: _Picker([
          _photo('IMG_2031.jpg', 0),
          _photo('Ảnh chụp màn hình đăng nhập sau khi sửa.jpg', 90),
        ]),
        then: () async {
          await tapAttach(tester, 'Photo library');
          await tapAttach(tester, 'Photo library');
        },
      );
    },
    'attachments-file': (tester, b, size, scale, kb) {
      final session = FakeAgentSession(
        state: stateWith(items: _history()),
        machine: machineWithFiles(projectFs()),
        cwd: '/home/dev/herdr-mobile',
      );
      return shoot(
        tester,
        'attachments-with-file',
        session,
        size,
        b,
        scale: scale,
        keyboard: kb,
        picker: _Picker([_photo('IMG_2031.jpg', 0), _photo('b.jpg', 120)]),
        then: () async {
          await tapAttach(tester, 'Photo library');
          await tapAttach(tester, 'Photo library');
          // The Host tab's list at 1.6x text on a 320 px screen is the sheet
          // shots' business; here the chips are what is looked at.
          if (scale == 1) await attachHostFile(tester, size);
          await tester.enterText(find.byType(TextField).last, 'What do these have in common?');
        },
      );
    },
    'auth': (tester, b, size, scale, kb) =>
        shoot(tester, 'auth', idle()..auth = _authNeeded, size, b, scale: scale, keyboard: kb),
  };

  const phone = Size(412, 892);
  const small = Size(320, 640);
  for (final entry in cases.entries) {
    for (final b in Brightness.values) {
      testWidgets('${entry.key} ${b.name} 412x892', (tester) => entry.value(tester, b, phone, 1, 0));
    }
    testWidgets('${entry.key} light 320x640 x1.6', (tester) => entry.value(tester, Brightness.light, small, 1.6, 0));
  }
  // Compact: landscape with the keyboard up.
  for (final name in ['working-queue-hint', 'attachments']) {
    testWidgets('$name compact', (tester) => cases[name]!(tester, Brightness.light, const Size(892, 412), 1, 200));
  }
}
