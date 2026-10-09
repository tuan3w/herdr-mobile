// The unified attach sheet in the agent session: it opens on the tap's frame,
// one tray shared by the Gallery, Files and Host tabs, the permission flow, the
// camera tile, the grid with 5,000 pictures, and the chips that follow
// (uploads with progress, cancel and retry, size caps, Send held while a file
// is on its way).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/recent_phone_files.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/data/services/phone_files.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_chips.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_select.dart';
import 'package:herdr_mobile/ui/features/attach/attach_bars.dart';
import 'package:herdr_mobile/ui/features/attach/attach_kit.dart';
import 'package:herdr_mobile/ui/features/attach/gallery_tab.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:herdr_mobile/ui/features/attach/selection_circle.dart';
import 'package:image/image.dart' as img;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/attach_fakes.dart';
import '../support/fake_agent_session.dart';
import '../support/files_support.dart';
import '../support/shot.dart' show loadAppFonts;

class _Picker implements AttachPicker {
  final shots = <PickedPhoto?>[];
  final library = <PickedPhoto?>[];
  var cameraAsked = 0;
  var libraryAsked = 0;

  @override
  Future<PickedPhoto?> camera() async {
    cameraAsked++;
    return shots.isEmpty ? null : shots.removeAt(0);
  }

  @override
  Future<PickedPhoto?> photo() async {
    libraryAsked++;
    return library.isEmpty ? null : library.removeAt(0);
  }
}

final _jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 8, height: 8)));

/// A picture the camera or the system picker left in the app's cache (the
/// screen reads it as [_jpeg]).
PickedPhoto _picked(String name) => PickedPhoto(path: '/cache/image_picker/$name', name: name, size: _jpeg.length);

Future<PreparedImage> _instantly(Uint8List input) async => PreparedImage(bytes: input, width: 8, height: 8);

FakeAgentSession _session({bool images = true}) => FakeAgentSession(
  machine: machineWithFiles(projectFs()),
  cwd: '/home/dev/herdr-mobile',
)..imagesAccepted = images;

Future<void> _open(
  WidgetTester tester,
  FakeAgentSession session,
  FakeKit fake, {
  _Picker? picker,
  Size size = const Size(412, 892),
  bool reduced = false,
  Future<PreparedImage> Function(Uint8List)? prepare,
}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      navigatorObservers: [ToastRouteObserver()],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: child!,
      ),
      home: AgentSessionScreen(
        key: ObjectKey(session),
        session: session,
        picker: picker ?? _Picker(),
        prepare: prepare ?? _instantly,
        attachKit: fake.kit,
        readFile: (_) async => _jpeg,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 500));
}

Finder get _clip => find.byIcon(LucideIcons.paperclip).first;

Future<void> _tapClip(WidgetTester tester, {bool settle = true}) async {
  await tester.tap(_clip);
  await tester.pump();
  if (settle) await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _wait(WidgetTester tester, [int ms = 400]) async {
  await tester.pump();
  await tester.pump(Duration(milliseconds: ms));
}

/// Pulls the sheet up to full height by its grabber, as a finger would.
Future<void> _expand(WidgetTester tester) async {
  await tester.dragFrom(const Offset(206, 402), const Offset(0, -380));
  await _wait(tester, 600);
}

Finder _circle(int index) => find.byType(SelectionCircle).at(index);

Finder _tab(AttachTab tab) => find.byKey(AttachTabBar.tabKey(tab));

Finder get _attachButton => find.textContaining('Attach (');

Finder get _chips => find.byType(AttachmentChips);

void main() {
  setUpAll(loadAppFonts);
  tearDown(() => debugRegionBuilt = null);

  group('opening', () {
    testWidgets('the frame of the tap holds the chrome and the camera tile: nothing awaited', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await tester.tap(_clip);
      await tester.pump(); // the ONE frame after the tap
      expect(find.byKey(AttachTabBar.tabKey(AttachTab.gallery)), findsOneWidget);
      expect(find.byKey(AttachTabBar.tabKey(AttachTab.files)), findsOneWidget);
      expect(find.byKey(AttachTabBar.tabKey(AttachTab.host)), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget, reason: 'the camera tile does not wait for the library');
    });

    testWidgets('the permission is asked only after the one-line reason and a tap, and only for the Gallery tab', (tester) async {
      final gallery = FakeGallery(state: GalleryAccess.undetermined);
      final fake = FakeKit(gallery: gallery);
      await _open(tester, _session(), fake);
      expect(gallery.requests, 0, reason: 'not at the composer');
      await _tapClip(tester);
      expect(find.text('Photos stay on your phone until you attach them.'), findsOneWidget);
      expect(gallery.requests, 0, reason: 'the reason comes first');
      await tester.tap(find.text('Allow photo access'));
      await _wait(tester);
      expect(gallery.requests, 1);
      expect(find.byType(PhotoTile), findsWidgets, reason: 'granted: the grid fills');
    });

    testWidgets('a session the person opens never asks the system before the Gallery tab is shown', (tester) async {
      final gallery = FakeGallery(state: GalleryAccess.undetermined);
      final fake = FakeKit(gallery: gallery);
      fake.kit.tab = AttachTab.files;
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      expect(find.text('Choose files\u2026'), findsOneWidget);
      await tester.tap(_tab(AttachTab.gallery));
      await _wait(tester);
      expect(gallery.requests, 0, reason: 'showing the tab shows the reason; the dialog needs a tap');
      expect(find.text('Allow photo access'), findsOneWidget);
    });

    testWidgets('warming on the finger landing loads the first page and thumbnails before the sheet opens, without asking', (tester) async {
      final gallery = FakeGallery(count: 300);
      final fake = FakeKit(gallery: gallery);
      await _open(tester, _session(), fake);
      // The screen warmed the library after its first frame.
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(gallery.pageQueries, 1, reason: 'one query for the first page');
      expect(fake.kit.thumbs.length, greaterThanOrEqualTo(24), reason: 'the first screenful of thumbnails is in memory');
      expect(gallery.requests, 0);
      final before = gallery.thumbCalls;
      await _tapClip(tester);
      expect(gallery.thumbCalls, lessThan(before + 12), reason: 'opening did not decode the first screenful again');
    });

    testWidgets('warming does nothing without the permission', (tester) async {
      final gallery = FakeGallery(state: GalleryAccess.denied);
      final fake = FakeKit(gallery: gallery);
      await _open(tester, _session(), fake);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(gallery.pageQueries, 0);
      expect(gallery.thumbCalls, 0);
      expect(gallery.requests, 0);
    });

    testWidgets('reduced motion: the sheet is in place on the first frame and the tabs switch at once', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake, reduced: true);
      await tester.tap(_clip);
      await tester.pump();
      final bar = tester.getRect(_tab(AttachTab.gallery));
      expect(bar.bottom, lessThanOrEqualTo(892), reason: 'no slide in: the bars are already on the screen');
      await tester.tap(_tab(AttachTab.files));
      await tester.pump();
      expect(find.text('Choose files\u2026').hitTestable(), findsOneWidget, reason: 'no cross-fade under reduced motion');
    });

    testWidgets('the last tab is remembered for the app run', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_tab(AttachTab.host));
      await _wait(tester);
      await tester.tapAt(const Offset(200, 40)); // the scrim above the sheet
      await _wait(tester);
      expect(find.byType(AttachTabBar), findsNothing);
      await _tapClip(tester);
      expect(fake.kit.tab, AttachTab.host);
      expect(find.textContaining('Find in'), findsOneWidget, reason: 'it opened on the Host tab');
    });

    testWidgets('a screenshot taken while the app was open is on the grid the next time the sheet opens', (tester) async {
      final gallery = FakeGallery(count: 30);
      final fake = FakeKit(gallery: gallery);
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await _wait(tester);
      expect(find.byKey(const ValueKey('30')), findsOneWidget, reason: 'the newest picture, first after the camera');
      expect(find.byKey(const ValueKey('31')), findsNothing);

      await tester.tapAt(const Offset(200, 40)); // the scrim above the sheet
      await _wait(tester);
      gallery.count = 31; // the screenshot
      await _tapClip(tester);
      await _wait(tester);
      expect(find.byKey(const ValueKey('31')), findsOneWidget);
      expect(find.byKey(const ValueKey('30')), findsOneWidget, reason: 'what was there stays');
    });
  });

  group('gallery selection', () {
    testWidgets('circles take numbers in the order picked and renumber when one is undone', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_circle(2));
      await tester.pump();
      await tester.tap(_circle(0));
      await tester.pump();
      await tester.tap(_circle(1));
      await _wait(tester);
      Finder number(int tile, String n) =>
          find.descendant(of: find.byType(PhotoTile).at(tile), matching: find.text(n));
      expect(number(2, '1'), findsOneWidget);
      expect(number(0, '2'), findsOneWidget);
      expect(number(1, '3'), findsOneWidget);
      expect(_attachButton, findsOneWidget);
      expect(find.text('Attach (3)'), findsOneWidget);
      await tester.tap(_circle(2)); // undo the first pick
      await _wait(tester);
      expect(number(0, '1'), findsOneWidget, reason: 'renumbered');
      expect(number(1, '2'), findsOneWidget);
      expect(find.text('Attach (2)'), findsOneWidget);
    });

    testWidgets('selecting rebuilds the tile that changed and not the grid', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      final built = <String, int>{};
      debugRegionBuilt = (r) => built[r] = (built[r] ?? 0) + 1;
      await tester.tap(_circle(3));
      await _wait(tester);
      expect(built['attach:tile'], 1, reason: 'only the tile whose number changed');
      expect(built['attach:grid'], isNull, reason: 'the grid is not rebuilt for a selection');
      expect(built['screen'], isNull);
    });

    testWidgets('a long press selects', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.longPress(find.byType(PhotoTile).at(1));
      await _wait(tester);
      expect(find.text('Attach (1)'), findsOneWidget);
    });

    testWidgets('the tray count sums the tabs: a photo, a file of the phone and a file of the host', (tester) async {
      final fake = FakeKit();
      fake.picker.queued.add([const PhoneFile(path: '/cache/report.pdf', name: 'report.pdf', size: 2048)]);
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_circle(0));
      await _wait(tester);
      expect(find.text('Attach (1)'), findsOneWidget);
      await tester.tap(_tab(AttachTab.files));
      await _wait(tester);
      await tester.tap(find.text('Choose files\u2026'));
      await _wait(tester);
      expect(find.text('Attach (2)'), findsOneWidget);
      await tester.tap(_tab(AttachTab.host));
      await _wait(tester, 600);
      await _expand(tester);
      await tester.tap(find.text('Show all files'));
      await _wait(tester);
      await tester.tap(find.text('AGENTS.md'));
      await _wait(tester);
      expect(find.text('Attach (3)'), findsOneWidget);
      expect(find.text('3 / 5'), findsOneWidget);
      await tester.tap(_tab(AttachTab.gallery));
      await _wait(tester);
      expect(find.text('Attach (3)'), findsOneWidget, reason: 'the bar belongs to the sheet, not to a tab');
    });

    testWidgets('a sixth pick is refused and says so', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      for (var i = 0; i < 5; i++) {
        await tester.tap(_circle(i));
        await tester.pump();
      }
      await tester.tap(_circle(5));
      await _wait(tester);
      expect(find.text('Attach (5)'), findsOneWidget);
      expect(find.text('At most 5 attachments per message.'), findsOneWidget);
    });

    testWidgets('Clear empties the tray and the bar goes', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_circle(0));
      await _wait(tester);
      await tester.tap(find.text('Clear'));
      await _wait(tester);
      expect(_attachButton, findsNothing);
    });

    testWidgets('tabs keep their state: the Gallery selection is still there after a round trip', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_circle(0));
      await _wait(tester);
      await tester.tap(_tab(AttachTab.files));
      await _wait(tester);
      await tester.tap(_tab(AttachTab.gallery));
      await _wait(tester);
      expect(find.descendant(of: find.byType(PhotoTile).at(0), matching: find.text('1')), findsOneWidget);
    });
  });

  group('fallbacks', () {
    testWidgets('denied: the reason, a way to settings, and the system picker still gives a photo', (tester) async {
      final fake = FakeKit(gallery: FakeGallery(state: GalleryAccess.denied));
      final picker = _Picker()..library.add(_picked('IMG_9.jpg'));
      await _open(tester, _session(), fake, picker: picker);
      await _tapClip(tester);
      expect(find.text('Photo access is off'), findsOneWidget);
      await tester.tap(find.text('Open settings'));
      await _wait(tester);
      expect(fake.gallery.settingsCalls, 1);
      await tester.tap(find.text('Open the system picker'));
      await _wait(tester);
      await _wait(tester);
      expect(picker.libraryAsked, 1);
      expect(find.descendant(of: _chips, matching: find.text('IMG_9.jpg')), findsOneWidget);
      expect(find.byType(AttachTabBar), findsNothing, reason: 'the sheet closed');
    });

    testWidgets('a plugin failure offers the system picker', (tester) async {
      final fake = FakeKit(gallery: FakeGallery(state: GalleryAccess.unavailable));
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      expect(find.text('Photos cannot be listed'), findsOneWidget);
      expect(find.text('Open the system picker'), findsOneWidget);
    });

    testWidgets('partial access shows a Manage chip that re-opens the selector and re-reads the library', (tester) async {
      final gallery = FakeGallery(state: GalleryAccess.limited, count: 12);
      final fake = FakeKit(gallery: gallery);
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      expect(find.text('Manage'), findsOneWidget);
      final queries = gallery.albumQueries;
      await tester.tap(find.text('Manage'));
      await _wait(tester);
      expect(gallery.manageCalls, 1);
      expect(gallery.albumQueries, greaterThan(queries));
    });

    testWidgets('the camera tile closes the sheet and opens the camera, and the shot becomes a chip', (tester) async {
      final fake = FakeKit();
      final picker = _Picker()..shots.add(_picked('camera.jpg'));
      await _open(tester, _session(), fake, picker: picker);
      await _tapClip(tester);
      await tester.tap(find.text('Camera'));
      await _wait(tester);
      await _wait(tester);
      expect(picker.cameraAsked, 1);
      expect(find.descendant(of: _chips, matching: find.text('camera.jpg')), findsOneWidget);
    });

    testWidgets('picks made before the camera tile are kept', (tester) async {
      final fake = FakeKit();
      final picker = _Picker()..shots.add(_picked('camera.jpg'));
      await _open(tester, _session(), fake, picker: picker);
      await _tapClip(tester);
      await tester.tap(_circle(0));
      await tester.pump();
      await tester.tap(find.text('Camera'));
      await _wait(tester);
      await _wait(tester);
      expect(find.descendant(of: _chips, matching: find.textContaining('IMG_')), findsOneWidget);
      expect(find.descendant(of: _chips, matching: find.text('camera.jpg')), findsOneWidget);
    });

    testWidgets('an empty library says so and keeps the camera', (tester) async {
      final fake = FakeKit(gallery: FakeGallery(count: 0));
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await _wait(tester);
      expect(find.text('No photos yet'), findsOneWidget);
      expect(find.text('Camera'), findsOneWidget);
    });
  });

  group('the grid with 5,000 pictures', () {
    testWidgets('builds a bounded number of tiles, at half height and while scrolling', (tester) async {
      final fake = FakeKit(gallery: FakeGallery(count: 5000));
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      expect(find.byType(PhotoTile).evaluate().length, lessThan(60));
      // Pull the sheet up to full height, then fling the grid several times.
      final grid = find.descendant(of: find.byType(GalleryTab), matching: find.byType(CustomScrollView));
      await tester.fling(find.text('Recent'), const Offset(0, -400), 2500);
      await _wait(tester, 700);
      var most = 0;
      final built = <int>[0];
      debugRegionBuilt = (r) {
        if (r == 'attach:tile') built[0]++;
      };
      for (var i = 0; i < 8; i++) {
        await tester.fling(grid, const Offset(0, -900), 3000);
        for (var f = 0; f < 40; f++) {
          await tester.pump(const Duration(milliseconds: 16));
          most = most < find.byType(PhotoTile).evaluate().length ? find.byType(PhotoTile).evaluate().length : most;
        }
      }
      expect(most, lessThan(70), reason: 'never more than a few screenfuls of tiles, whatever the library holds');
      expect(fake.kit.thumbs.length, lessThanOrEqualTo(200), reason: 'the LRU cap holds');
      expect(fake.gallery.pageQueries, lessThan(40), reason: 'pages, not 5,000 queries');
      expect(built[0], lessThan(600), reason: 'a fling builds the tiles that come into view, not the library');
    });
  });

  group('attaching', () {
    testWidgets('Attach closes the sheet and the chips show in that frame, with the gallery thumbnail', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_circle(0));
      await tester.pump();
      await tester.tap(_circle(1));
      await _wait(tester);
      await tester.tap(find.text('Attach (2)'));
      await tester.pump(); // the frame the sheet starts to leave in
      expect(find.descendant(of: _chips, matching: find.textContaining('IMG_')), findsNWidgets(2));
      await _wait(tester);
      await _wait(tester);
      expect(find.text('Preparing\u2026'), findsNothing);
    });

    testWidgets('a picture is encoded the moment it is picked and the work is dropped when it is undone', (tester) async {
      final started = <int>[];
      final fake = FakeKit();
      await _open(tester, _session(), fake, prepare: (b) async {
        started.add(b.length);
        return PreparedImage(bytes: _jpeg, width: 8, height: 8);
      });
      await _tapClip(tester);
      await tester.tap(_circle(0));
      await tester.pump();
      expect(started, hasLength(1), reason: 'encoding began on the pick, before Attach');
      // Undone before it finished: nothing more happens for it, and Attach has nothing to wait for.
      await tester.tap(_circle(0));
      await _wait(tester);
      expect(_attachButton, findsNothing);
    });

    testWidgets('an agent that takes no pictures: a gallery photo goes up as a file and the chip says so', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(images: false), fake);
      await _tapClip(tester);
      await tester.tap(_circle(0));
      await _wait(tester);
      await tester.tap(find.text('Attach (1)'));
      await _wait(tester);
      await _wait(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
      expect(fake.uploader.started, hasLength(1));
      fake.uploader.last.finish();
      await tester.pump();
      await tester.pump();
      expect(find.text('Sent as a file \u00b7 this agent takes no images'), findsOneWidget);
    });
  });

  group('a file of the phone', () {
    Future<FakeKit> uploading(WidgetTester tester, {int size = 5 * 1024 * 1024, String name = 'report.pdf'}) async {
      final fake = FakeKit();
      fake.picker.queued.add([PhoneFile(path: '/cache/file_picker/1/$name', name: name, size: size)]);
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_tab(AttachTab.files));
      await _wait(tester);
      await tester.tap(find.text('Choose files\u2026'));
      await _wait(tester);
      await tester.tap(find.text('Attach (1)'));
      await _wait(tester);
      await _wait(tester);
      return fake;
    }

    testWidgets('uploads after the sheet is gone; the chip shows the progress; the host path is what is sent', (tester) async {
      final fake = await uploading(tester);
      final up = fake.uploader.last;
      expect(up.localPath, '/cache/file_picker/1/report.pdf');
      expect(find.textContaining('Uploading 0%'), findsOneWidget);
      up.progress(2 * 1024 * 1024, 5 * 1024 * 1024);
      await tester.pump();
      expect(find.textContaining('Uploading 40%'), findsOneWidget);
      up.finish('/home/dev/.herdr-mobile/inbox/k/2026-05-20-report.pdf');
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Uploaded'), findsOneWidget);
      // Sent as a resource_link carrying the host path, outside the repo.
      await tester.tap(find.byIcon(LucideIcons.arrowUp));
      await _wait(tester);
      final session = tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session as FakeAgentSession;
      final link = session.sentBlocks.single.single as ResourceLinkBlock;
      expect(link.uri, 'file:///home/dev/.herdr-mobile/inbox/k/2026-05-20-report.pdf');
      expect(link.name, '/home/dev/.herdr-mobile/inbox/k/2026-05-20-report.pdf', reason: 'outside the folder: the absolute path');
    });

    testWidgets('Send waits while the upload runs and the hint says why', (tester) async {
      final fake = await uploading(tester);
      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.decoration!.hintText, 'Uploading report.pdf\u2026');
      final session = tester.widget<AgentSessionScreen>(find.byType(AgentSessionScreen)).session as FakeAgentSession;
      await tester.enterText(find.byType(TextField).last, 'see the report');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _wait(tester);
      expect(session.sent, isEmpty, reason: 'not while a file is on its way');
      fake.uploader.last.finish();
      await tester.pump();
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _wait(tester);
      expect(session.sent, ['see the report']);
    });

    testWidgets('cancel stops the transfer and takes the chip away', (tester) async {
      final fake = await uploading(tester);
      await tester.tap(find.descendant(of: _chips, matching: find.byIcon(LucideIcons.x)));
      await _wait(tester);
      expect(fake.uploader.last.cancelled, isTrue);
      expect(find.text('report.pdf'), findsNothing);
    });

    testWidgets('a failed upload shows Retry on its chip; Retry starts it again and Send stays held until it is done', (tester) async {
      final fake = await uploading(tester);
      fake.uploader.last.fail(RemoteFileException(RemoteFileErrorKind.network, 'Connection lost'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Connection lost'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.decoration!.hintText, 'An upload failed: retry it or remove it');
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(fake.uploader.started, hasLength(2));
      expect(find.descendant(of: _chips, matching: find.textContaining('Uploading')), findsOneWidget);
      fake.uploader.last.finish();
      await tester.pump();
      await tester.pump();
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('over 200 MB is refused with the reason and nothing starts', (tester) async {
      final fake = FakeKit();
      fake.picker.queued.add([const PhoneFile(path: '/cache/big.mov', name: 'big.mov', size: 312 * 1024 * 1024)]);
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(_tab(AttachTab.files));
      await _wait(tester);
      await tester.tap(find.text('Choose files\u2026'));
      await _wait(tester);
      expect(find.text('big.mov is 312 MB. Files up to 200 MB can be attached.'), findsOneWidget);
      expect(_attachButton, findsNothing);
      expect(fake.uploader.started, isEmpty);
    });

    testWidgets('over 25 MB is allowed with a warning', (tester) async {
      final fake = await uploading(tester, size: 48 * 1024 * 1024, name: 'demo.mov');
      expect(fake.uploader.started, hasLength(1));
      expect(find.text('demo.mov is large; uploading it may take a while.'), findsOneWidget);
    });

    testWidgets('a finished upload is remembered in Recent with its host copy', (tester) async {
      final fake = await uploading(tester);
      fake.uploader.last.finish('/home/dev/.herdr-mobile/inbox/k/2026-05-20-report.pdf');
      await tester.pump();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(fake.store.files, [
        const RecentPhoneFile(
          name: 'report.pdf',
          size: 5 * 1024 * 1024,
          machineId: 'm',
          hostPath: '/home/dev/.herdr-mobile/inbox/k/2026-05-20-report.pdf',
        ),
      ]);
    });
  });

  group('tiles', () {
    test('describeTaken says today, yesterday, this year and another year', () {
      final now = DateTime(2026, 10, 5, 18, 0);
      expect(describeTaken(DateTime(2026, 10, 5, 14, 2), now), 'today 14:02');
      expect(describeTaken(DateTime(2026, 10, 4, 9, 10), now), 'yesterday 09:10');
      expect(describeTaken(DateTime(2026, 5, 20, 14, 2), now), 'May 20, 14:02');
      expect(describeTaken(DateTime(2025, 5, 20, 14, 2), now), 'May 20, 2025');
    });

    test('three columns on a phone, more on a wide window', () {
      expect(galleryColumnsFor(320), 3);
      expect(galleryColumnsFor(412), 3);
      expect(galleryColumnsFor(892), 7);
      expect(galleryColumnsFor(3000), 8);
    });

    testWidgets('every tile says what it is, when it was taken and whether it is picked', (tester) async {
      final handle = tester.ensureSemantics();
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      expect(find.bySemanticsLabel(RegExp(r'^Photo 2, taken .+, not selected$')), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Select photo 2'));
      await _wait(tester);
      expect(find.bySemanticsLabel(RegExp(r'^Photo 2, taken .+, selected, number 1$')), findsOneWidget);
      expect(find.bySemanticsLabel('Deselect photo 2'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('every circle and tab is at least 44 dp to hit', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      for (final c in find.byType(SelectionCircle).evaluate().take(3)) {
        final size = tester.getSize(find.byWidget(c.widget));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      }
      for (final t in AttachTab.values) {
        expect(tester.getSize(_tab(t)).height, greaterThanOrEqualTo(44));
      }
    });

    testWidgets('a tap on the picture opens it in the photo viewer with a Select toggle that works on the tray', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await _tapClip(tester);
      await tester.tap(find.byType(PhotoTile).at(1));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PhotoViewer), findsOneWidget);
      await tester.tap(find.text('Select'));
      await tester.pump();
      expect(find.text('Selected'), findsOneWidget);
      await tester.tap(find.text('Selected'));
      await tester.pump();
      expect(find.text('Select'), findsOneWidget, reason: 'toggled off again');
      await tester.tap(find.text('Select'));
      await tester.pump();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await _wait(tester);
      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.text('Attach (1)'), findsOneWidget);
      expect(find.descendant(of: find.byType(PhotoTile).at(1), matching: find.text('1')), findsOneWidget);
    });

    testWidgets('a second tap on the paperclip while the sheet is up does not push another', (tester) async {
      final fake = FakeKit();
      await _open(tester, _session(), fake);
      await tester.tap(_clip);
      await tester.pump();
      await tester.tap(_clip, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AttachTabBar), findsOneWidget);
    });

    testWidgets('the chip of a gallery pick shows the thumbnail the grid decoded: the same image-cache entry', (tester) async {
      final fake = FakeKit();
      fake.gallery.picture = (_) => fakePicture(5);
      await _open(tester, _session(), fake);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await _tapClip(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
      ImageProvider tileImage() => tester
          .widget<Image>(find.descendant(of: find.byType(PhotoTile).at(0), matching: find.byType(Image)))
          .image;
      final provider = tileImage();
      await tester.tap(_circle(0));
      await _wait(tester);
      await tester.tap(find.text('Attach (1)'));
      await _wait(tester);
      await _wait(tester);
      final chip = tester.widget<Image>(find.descendant(of: _chips, matching: find.byType(Image)).first).image;
      expect(chip, provider, reason: 'same provider, same cache key: no second decode');
    });
  });
}
