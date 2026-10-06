// Renders the attach sheet to PNGs for review: the Gallery grid with picks
// (half and full height), the permission reason, a refused permission, the
// Files and Host tabs, the chips strip with an upload in flight, and the
// worst cases (no photos, one photo, 500 photos, long and Vietnamese names).
// Light and dark at 412x892 and 320x640. Off by default; it writes files:
//
//   ATTACH_SHOTS=1 flutter test test/ui/attach_sheet_shots_test.dart
//
// Output: $ATTACH_SHOTS_DIR (default /tmp/attach_sheet_shots)/<case>-<light|dark>-<w>x<h>.png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/recent_phone_files.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/data/services/phone_files.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:herdr_mobile/ui/features/attach/attach_kit.dart';
import 'package:herdr_mobile/ui/features/attach/selection_circle.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/files_support.dart';
import '../support/shot.dart' show loadAppFonts;

class _Picker implements AttachPicker {
  @override
  Future<PickedPhoto?> photo() async => null;

  @override
  Future<PickedPhoto?> camera() async => null;
}

Future<PreparedImage> _prepare(Uint8List b) async => PreparedImage(bytes: b, width: 96, height: 96);

void main() {
  if (Platform.environment['ATTACH_SHOTS'] == null) {
    test('attach sheet shots are off (set ATTACH_SHOTS=1)', () {}, skip: 'set ATTACH_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['ATTACH_SHOTS_DIR'] ?? '/tmp/attach_sheet_shots';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  FakeGallery gallery({int count = 120, GalleryAccess state = GalleryAccess.granted}) {
    final g = FakeGallery(count: count, state: state, newest: DateTime.now().subtract(const Duration(minutes: 12)));
    g.picture = (a) => fakePicture(int.tryParse(a.id) ?? 0);
    return g;
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Size size,
    Brightness brightness, {
    FakeKit? kit,
    FakeAgentSession? session,
    Future<void> Function(FakeKit kit)? then,
    double scale = 1,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final fake = kit ?? FakeKit(gallery: gallery());
    final s = session ??
        FakeAgentSession(machine: machineWithFiles(projectFs()), cwd: '/home/dev/herdr-mobile');
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
          key: ObjectKey(s),
          session: s,
          picker: _Picker(),
          prepare: _prepare,
          attachKit: fake.kit,
          readFile: (_) async => fakePicture(3),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(tapGuard);
    await then?.call(fake);
    // Thumbnails decode on the engine's real clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
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

  Future<void> open(WidgetTester tester, {AttachTab? tab, FakeKit? kit}) async {
    if (tab != null) kit?.kit.tab = tab;
    await tester.tap(find.byIcon(LucideIcons.paperclip).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // The warmed thumbnails come from the real clock.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
  }

  Future<void> tapCircles(WidgetTester tester, List<int> which) async {
    for (final i in which) {
      await tester.tap(find.byType(SelectionCircle).at(i));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> expand(WidgetTester tester, Size size) async {
    await tester.dragFrom(Offset(size.width / 2, size.height * 0.45 + 8), Offset(0, -size.height * 0.4));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700));
  }

  final sizes = [const Size(412, 892), const Size(320, 640)];

  for (final brightness in Brightness.values) {
    for (final size in sizes) {
      final tag = '${brightness.name} ${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('gallery half height, three picks, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery());
        await shoot(tester, 'gallery-half-picks', size, brightness, kit: kit, then: (kit) async {
          await open(tester, kit: kit);
          await tapCircles(tester, [2, 0, 4]);
        });
      });

      testWidgets('gallery full height, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery(count: 500));
        await shoot(tester, 'gallery-full-500', size, brightness, kit: kit, then: (kit) async {
          await open(tester, kit: kit);
          await tapCircles(tester, [1, 3]);
          await expand(tester, size);
        });
      });

      testWidgets('permission reason, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery(state: GalleryAccess.undetermined));
        await shoot(tester, 'permission-reason', size, brightness, kit: kit, then: (kit) => open(tester, kit: kit));
      });

      testWidgets('permission refused, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery(state: GalleryAccess.denied));
        await shoot(tester, 'permission-denied', size, brightness, kit: kit, then: (kit) => open(tester, kit: kit));
      });

      testWidgets('limited access, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery(state: GalleryAccess.limited, count: 9));
        await shoot(tester, 'gallery-limited-9', size, brightness, kit: kit, then: (kit) => open(tester, kit: kit));
      });

      testWidgets('no photos, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery(count: 0));
        await shoot(tester, 'gallery-empty', size, brightness, kit: kit, then: (kit) => open(tester, kit: kit));
      });

      testWidgets('one photo, agent without images, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery(count: 1));
        final session = FakeAgentSession(machine: machineWithFiles(projectFs()), cwd: '/home/dev/herdr-mobile')
          ..imagesAccepted = false;
        await shoot(tester, 'gallery-one-no-images', size, brightness, kit: kit, session: session, then: (kit) async {
          await open(tester, kit: kit);
          await tapCircles(tester, [0]);
        });
      });

      testWidgets('files tab, $tag', (tester) async {
        final store = MemoryRecentStore([
          const RecentPhoneFile(name: 'Báo cáo quý ba — bản cuối cùng (đã chỉnh sửa) 2026.pdf', size: 3400000, machineId: 'm', hostPath: '/h/x'),
          const RecentPhoneFile(name: 'screenshot-2026-05-20.png', size: 812000),
          const RecentPhoneFile(name: 'a-very-long-file-name-that-keeps-going-and-going-and-going-until-it-needs-an-ellipsis.tar.gz', size: 48000000),
          const RecentPhoneFile(name: 'notes.txt', size: 1200),
        ]);
        final kit = FakeKit(gallery: gallery(), store: store);
        kit.picker.queued.add([
          const PhoneFile(path: '/c/design.fig', name: 'design.fig', size: 26 * 1024 * 1024),
          const PhoneFile(path: '/c/Thiết kế giao diện.md', name: 'Thiết kế giao diện.md', size: 2048),
        ]);
        await shoot(tester, 'files-tab', size, brightness, kit: kit, then: (kit) async {
          await open(tester, tab: AttachTab.files, kit: kit);
          await tester.tap(find.text('Choose files\u2026'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        });
      });

      testWidgets('host tab, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery());
        await shoot(tester, 'host-tab', size, brightness, kit: kit, then: (kit) async {
          await open(tester, tab: AttachTab.host, kit: kit);
          await expand(tester, size);
          await tester.tap(find.text('Show all files'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.tap(find.text('AGENTS.md'));
          await tester.pump();
          await tester.tap(find.text('build.log'));
          await tester.pump(const Duration(milliseconds: 400));
        });
      });

      testWidgets('chips with an upload in flight, $tag', (tester) async {
        final kit = FakeKit(gallery: gallery());
        kit.picker.queued.add([
          const PhoneFile(path: '/c/notes.txt', name: 'notes.txt', size: 1200),
          const PhoneFile(path: '/c/design-review-recording-final-v2.mp4', name: 'design-review-recording-final-v2.mp4', size: 48 * 1024 * 1024),
        ]);
        await shoot(tester, 'chips-uploading', size, brightness, kit: kit, then: (kit) async {
          await open(tester, tab: AttachTab.files, kit: kit);
          await tester.tap(find.text('Choose files\u2026'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text('Attach (2)'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          kit.uploader.started[0].fail(RemoteFileException(RemoteFileErrorKind.network, 'Connection lost'));
          kit.uploader.started[1].progress(18 * 1024 * 1024, 48 * 1024 * 1024);
          await tester.pump();
          await tester.pump();
        });
      });
    }
  }
}
