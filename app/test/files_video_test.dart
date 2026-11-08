import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/files/binary_view.dart';
import 'package:herdr_mobile/ui/features/files/file_format.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/video_view.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_fs.dart';
import 'support/fake_staging.dart';
import 'support/fake_video_platform.dart';
import 'support/files_support.dart';
import 'support/photo_support.dart' show FakeExport;
import 'support/shot.dart' show loadAppFonts;

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2.625
    ..devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: AppTheme.light(), home: home));
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The viewer of [path] with the phone's video player, share sheet and storage replaced.
FileViewerScreen _viewer(FakeFs fs, String path, {required FakeStaging staging, required FakeExport export}) =>
    FileViewerScreen(
      machine: machineWithFiles(fs),
      stat: RemoteStat(
        path: path,
        kind: RemoteEntryKind.file,
        size: fs.nodes[path]!.bytes.length,
        modified: fs.nodes[path]!.modified,
      ),
      staging: staging,
      export: export,
    );

void main() {
  setUpAll(loadAppFonts);

  late FakeVideoPlatform platform;
  late FakeStaging staging;
  late FakeExport export;
  late FakeFs fs;

  setUp(() {
    platform = FakeVideoPlatform();
    final before = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = before);
    staging = FakeStaging();
    export = FakeExport();
    fs = FakeFs();
  });

  /// Leaves the screen so the player is disposed and no timer outlives the test.
  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  group('video', () {
    testWidgets('a small video is copied and plays without a tap, and Save to gallery keeps that copy', (tester) async {
      fs.addFile('/home/dev/clip.mp4', Uint8List(2000));
      await _pump(tester, _viewer(fs, '/home/dev/clip.mp4', staging: staging, export: export));
      await _settle(tester);

      expect(staging.fetched, ['clip.mp4']);
      expect(platform.calls, containsAllInOrder(['create', 'play']));
      expect(find.text('Save to gallery'), findsOneWidget);

      await tester.tap(find.text('Save to gallery'));
      await _settle(tester);

      expect(export.videos, ['clip.mp4']);
      expect(staging.fetched, ['clip.mp4'], reason: 'the copy that plays is the copy that is saved');
      expect(find.text('Saved to Pictures/herdr'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('a player that opens some frames later shows the video then, without another touch', (tester) async {
      final opening = Completer<void>();
      platform.opening = opening;
      fs.addFile('/home/dev/clip.mp4', Uint8List(2000));
      await _pump(tester, _viewer(fs, '/home/dev/clip.mp4', staging: staging, export: export));
      await _settle(tester);
      expect(find.byType(VideoStage), findsNothing, reason: 'still opening');

      opening.complete();
      await _settle(tester);
      expect(find.byType(VideoStage), findsOneWidget, reason: 'the video shows as soon as the player has opened');
      await leave(tester);
    });

    testWidgets('a big video waits for Play, shows the copy under way, and Cancel goes back without a failure', (
      tester,
    ) async {
      fs.addFile('/home/dev/long.mov', Uint8List(videoAutoCopyLimit + 1));
      staging.hold = Completer<void>();
      await _pump(tester, _viewer(fs, '/home/dev/long.mov', staging: staging, export: export));
      await _settle(tester);

      expect(find.text('Play'), findsOneWidget);
      expect(find.textContaining(formatBytes(videoAutoCopyLimit + 1)), findsWidgets, reason: 'what Play will copy');
      expect(staging.fetched, isEmpty, reason: 'nothing is copied before the tap');

      await tester.tap(find.text('Play'));
      await _settle(tester);

      expect(find.textContaining('Copying to the phone'), findsOneWidget);
      expect(find.byType(ProgressLine), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      staging.hold!.complete();
      await _settle(tester);

      expect(find.text('Play'), findsOneWidget);
      expect(find.textContaining('Couldn\u2019t copy'), findsNothing);
      expect(platform.calls, isNot(contains('create')));
      await leave(tester);
    });

    testWidgets('a copy that fails says why and Retry copies again', (tester) async {
      fs.addFile('/home/dev/clip.mp4', Uint8List(2000));
      staging.failWith = RemoteFileException(RemoteFileErrorKind.network, 'The connection dropped.');
      await _pump(tester, _viewer(fs, '/home/dev/clip.mp4', staging: staging, export: export));
      await _settle(tester);

      expect(find.text('Couldn\u2019t copy the video'), findsOneWidget);
      expect(find.text('The connection dropped.'), findsOneWidget);

      staging.failWith = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(staging.fetched, ['clip.mp4', 'clip.mp4']);
      expect(find.text('Save to gallery'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('a video the phone cannot open offers the share sheet, with the copy it already has', (tester) async {
      fs.addFile('/home/dev/odd.mkv', Uint8List(2000));
      platform.openFails = PlatformException(code: 'unsupported');
      await _pump(tester, _viewer(fs, '/home/dev/odd.mkv', staging: staging, export: export));
      await _settle(tester);

      expect(find.text('This phone can\u2019t play this video'), findsOneWidget);

      await tester.tap(find.text('Share or save\u2026'));
      await _settle(tester);

      expect(export.files, ['odd.mkv']);
      expect(staging.fetched, ['odd.mkv']);
      await leave(tester);
    });

    testWidgets(
      'a copy that finishes while the app is in the background is ready, and does not play behind another app',
      (tester) async {
        fs.addFile('/home/dev/long.mov', Uint8List(videoAutoCopyLimit + 1));
        staging.hold = Completer<void>();
        await _pump(tester, _viewer(fs, '/home/dev/long.mov', staging: staging, export: export));
        await _settle(tester);
        await tester.tap(find.text('Play'));
        await _settle(tester);

        // The order the framework allows: out through inactive and hidden, back the same way.
        for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        staging.hold!.complete();
        await _settle(tester);

        for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
        await _settle(tester);

        expect(platform.calls, contains('create'));
        expect(platform.calls, isNot(contains('play')));
        expect(find.text('Share or save\u2026'), findsOneWidget, reason: 'the player is there for when they are back');
        await leave(tester);
      },
    );

    testWidgets('a video known only by its bytes has no Save to gallery (the gallery needs a video name)', (
      tester,
    ) async {
      fs.addFile('/home/dev/capture.bin', Uint8List.fromList([0, 0, 0, 0x18, ...'ftypisom'.codeUnits, 0, 0, 0, 0]));
      await _pump(tester, _viewer(fs, '/home/dev/capture.bin', staging: staging, export: export));
      await _settle(tester);

      expect(find.text('Save to gallery'), findsNothing);
      expect(find.text('Share or save\u2026'), findsOneWidget);
      await leave(tester);
    });

    testWidgets('a name that says video over text is text: a saved error page is not a player', (tester) async {
      fs.addFile('/home/dev/broken.mp4', '<html>Not Found</html>');
      await _pump(tester, _viewer(fs, '/home/dev/broken.mp4', staging: staging, export: export));
      await _settle(tester);

      expect(find.byType(VideoView), findsNothing);
      expect(find.textContaining('Not Found'), findsWidgets);
      expect(staging.fetched, isEmpty);
      await leave(tester);
    });
  });

  group('share or save', () {
    testWidgets('a text file can be taken to another app from its options', (tester) async {
      fs.addFile('/home/dev/notes.txt', 'one\ntwo\n');
      await _pump(tester, _viewer(fs, '/home/dev/notes.txt', staging: staging, export: export));
      await _settle(tester);

      await tester.tap(find.byTooltip('File options'));
      await _settle(tester);
      await tester.tap(find.text('Share or save\u2026'));
      await _settle(tester);

      expect(staging.fetched, ['notes.txt']);
      expect(export.files, ['notes.txt']);
      await leave(tester);
    });

    testWidgets('the card of a file the viewer cannot show has it as its main action', (tester) async {
      fs.addFile('/home/dev/data.bin', Uint8List.fromList([1, 2, 0, 3, 4]));
      await _pump(tester, _viewer(fs, '/home/dev/data.bin', staging: staging, export: export));
      await _settle(tester);

      expect(find.byType(BinaryView), findsOneWidget);
      await tester.tap(find.text('Share or save\u2026'));
      await _settle(tester);

      expect(export.files, ['data.bin']);
      await leave(tester);
    });

    testWidgets('a share that fails says so, and the file stays open', (tester) async {
      fs.addFile('/home/dev/data.bin', Uint8List.fromList([1, 2, 0, 3, 4]));
      staging.failWith = RemoteFileException(RemoteFileErrorKind.failed, 'The phone is out of space for a copy.');
      await _pump(tester, _viewer(fs, '/home/dev/data.bin', staging: staging, export: export));
      await _settle(tester);

      await tester.tap(find.text('Share or save\u2026'));
      await _settle(tester);

      expect(find.text('The phone is out of space for a copy.'), findsOneWidget);
      expect(export.files, isEmpty);
      expect(find.byType(BinaryView), findsOneWidget);
      await leave(tester);
    });
  });
}
