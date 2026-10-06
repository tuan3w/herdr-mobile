import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/files/files_navigation.dart';
import 'package:herdr_mobile/ui/features/files/photo_files.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer.dart';
import 'package:herdr_mobile/ui/features/photos/photo_viewer_view_model.dart';

import 'support/fake_fs.dart';
import 'support/files_support.dart';
import 'support/photo_support.dart';
import 'support/shot.dart' show loadAppFonts;

RemoteEntry _file(String name, {RemoteEntryKind kind = RemoteEntryKind.file}) =>
    RemoteEntry(name: name, path: '/p/$name', kind: kind, resolvedKind: kind, size: 10);

PhotoViewerViewModel _modelOf(WidgetTester tester) => tester.state<PhotoViewerState>(find.byType(PhotoViewer)).model;

Future<void> _pumpHome(WidgetTester tester, Widget home) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(MaterialApp(key: UniqueKey(), theme: AppTheme.light(), home: home));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(loadAppFonts);

  group('which files are photos', () {
    test('the formats the engine decodes; SVG, PDF and archives are not', () {
      for (final n in ['a.png', 'A.JPG', 'b.jpeg', 'c.gif', 'd.webp', 'e.bmp']) {
        expect(isPhotoName(n), isTrue, reason: n);
      }
      for (final n in ['a.svg', 'a.pdf', 'a.zip', 'a.heic', 'png', 'notes.txt', '.png']) {
        expect(isPhotoName(n), isFalse, reason: n);
      }
    });

    test('a folder\'s photos come in natural order, case-insensitively, without folders and links to folders', () {
      final entries = [
        _file('IMG_10.jpg'),
        _file('img_2.JPG'),
        _file('IMG_1.png'),
        _file('notes.txt'),
        _file('photos.png', kind: RemoteEntryKind.dir),
        _file('Ảnh 3.webp'),
        _file('ảnh 20.webp'),
      ];
      expect([for (final e in photoEntries(entries)) e.name], ['IMG_1.png', 'img_2.JPG', 'IMG_10.jpg', 'Ảnh 3.webp', 'ảnh 20.webp']);
    });
  });

  group('opening a photo from a folder', () {
    testWidgets('a tap in the browser opens the immersive viewer, with the folder\'s photos to swipe through, in order', (tester) async {
      final fs = FakeFs();
      for (final n in ['img10.png', 'img2.png', 'img1.png']) {
        fs.addFile('/p/$n', await makePng(tester, 64, 48));
      }
      fs.addFile('/p/notes.txt', 'x');
      await _pumpHome(tester, FileBrowserScreen(machine: machineWithFiles(fs), path: '/p'));
      await pumpUntil(tester, () => find.text('img2.png').evaluate().isNotEmpty);

      await tester.tap(find.text('img2.png'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(FileViewerScreen), findsNothing, reason: 'a picture does not open in the text viewer');
      expect(find.byType(PhotoViewer), findsOneWidget);
      final model = _modelOf(tester);
      expect([for (final i in model.items) i.name], ['img1.png', 'img2.png', 'img10.png'], reason: 'natural order');
      expect(model.index, 1);
      await pumpUntil(tester, () => model.currentEntry.ready);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Photo 2 of 3'), findsOneWidget);
      expect(model.current.path, '/p/img2.png');
    });

    testWidgets('a path tapped in a chat opens the viewer, and the folder\'s other photos join it once listed', (tester) async {
      final fs = FakeFs();
      for (final n in ['a.png', 'b.png', 'c.png']) {
        fs.addFile('/home/dev/shots/$n', await makePng(tester, 64, 48));
      }
      fs.addFile('/home/dev/shots/.hidden.png', await makePng(tester, 64, 48));
      late BuildContext host;
      await _pumpHome(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      final machine = machineWithFiles(fs);

      // ignore: unawaited_futures
      openRemoteFile(host, machine, '/home/dev/shots/b.png');
      await pumpUntil(tester, () => find.byType(PhotoViewer).evaluate().isNotEmpty);
      final model = _modelOf(tester);
      await pumpUntil(tester, () => model.count == 3);
      expect(model.count, 3, reason: 'a, b and c; the dotfile stays out');
      expect(model.index, 1);
      expect(model.current.name, 'b.png');
      expect(fs.calls.where((c) => c.startsWith('list')).length, 1, reason: 'one listing of the folder');
      await pumpUntil(tester, () => model.currentEntry.ready);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Photo 2 of 3'), findsOneWidget);
    });

    testWidgets('a file called .png whose bytes are text offers to view it as text, and does', (tester) async {
      final fs = FakeFs()..addFile('/p/error.png', '<html>404 Not Found</html>');
      late BuildContext host;
      await _pumpHome(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      // ignore: unawaited_futures
      openRemoteFile(host, machineWithFiles(fs), '/p/error.png');
      await pumpUntil(tester, () => find.text('View as text').evaluate().isNotEmpty);
      expect(find.text("Can't show this as a picture"), findsOneWidget);

      await tester.tap(find.text('View as text'));
      await settleReal(tester);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsNothing);
      expect(find.byType(FileViewerScreen), findsOneWidget);
      expect(find.textContaining('404 Not Found'), findsOneWidget);
    });

    testWidgets('a picture whose name does not say so is handed to the photo viewer once its bytes are read', (tester) async {
      final fs = FakeFs()..addFile('/p/screenshot', await makePng(tester, 64, 48));
      await _pumpHome(
        tester,
        FileViewerScreen(
          machine: machineWithFiles(fs),
          stat: RemoteStat(path: '/p/screenshot', kind: RemoteEntryKind.file, size: fs.nodes['/p/screenshot']!.bytes.length),
        ),
      );
      await pumpUntil(tester, () => find.byType(PhotoViewer).evaluate().isNotEmpty);
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
      expect(find.byType(FileViewerScreen), findsNothing, reason: 'replaced, so Back does not land on a blank page');
      final model = _modelOf(tester);
      await pumpUntil(tester, () => model.currentEntry.ready);
      expect(model.count, 1, reason: 'no siblings are listed for a name that is not a photo');
    });

    testWidgets('a photo over 40 MB is refused with its size, before a byte of it is read', (tester) async {
      final fs = FakeFs()..addFile('/p/huge.jpg', Uint8List(41 * 1024 * 1024));
      late BuildContext host;
      await _pumpHome(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      // ignore: unawaited_futures
      openRemoteFile(host, machineWithFiles(fs), '/p/huge.jpg');
      await pumpUntil(tester, () => find.text('Too large to open here').evaluate().isNotEmpty);
      expect(find.text('This photo is 41 MB. The viewer opens photos up to 40 MB.'), findsOneWidget);
      expect(find.text('Share…'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(fs.calls.where((c) => c.startsWith('read')), isEmpty, reason: 'the photo itself was never fetched');
    });

    testWidgets('a photo between 8 MB and 40 MB opens: it is read in several calls, not refused', (tester) async {
      // 12 MB: over the 8 MB a single SFTP call may return. A real PNG header
      // then zeros is not decodable, so only the reading is checked here.
      final bytes = Uint8List(12 * 1024 * 1024);
      final fs = FakeFs()..addFile('/p/big.jpg', bytes);
      late BuildContext host;
      await _pumpHome(tester, Builder(builder: (c) {
        host = c;
        return const SizedBox();
      }));
      // ignore: unawaited_futures
      openRemoteFile(host, machineWithFiles(fs), '/p/big.jpg');
      await pumpUntil(tester, () => fs.calls.where((c) => c.startsWith('read')).length >= 6);
      final reads = fs.calls.where((c) => c.startsWith('read /p/big.jpg')).toList();
      expect(reads.length, greaterThanOrEqualTo(6), reason: '12 MB in 2 MB pieces');
      expect(reads.every((r) => !r.contains('+8388608')), isTrue, reason: 'no single 8 MB read');
      await pumpUntil(tester, () => find.textContaining("can't be shown").evaluate().isNotEmpty);
      expect(find.text('Too large to open here'), findsNothing);
    });
  });
}
