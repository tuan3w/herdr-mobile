import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;
import 'package:herdr_mobile/data/services/photo_export.dart';
import 'package:herdr_mobile/data/services/remote_file_staging.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';
import 'package:herdr_mobile/ui/features/files/file_copy_model.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';
import 'support/photo_support.dart' show FakeExport;

/// [n] bytes that differ from one place to the next, so a piece copied twice or
/// out of order is noticed.
Uint8List _bytes(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 7 + i ~/ 251) & 0xFF]);

void main() {
  late Directory root;
  late FakeFs fs;
  late RemoteFiles files;
  late RemoteFileStaging staging;

  setUp(() {
    root = Directory.systemTemp.createTempSync('remote_file_staging_test');
    addTearDown(() => root.deleteSync(recursive: true));
    fs = FakeFs();
    files = RemoteFiles(FakeTransport()..fs = fs, machineId: 'm1');
    staging = RemoteFileStaging(root: () async => Directory('${root.path}/copies'));
  });

  int reads() => fs.calls.where((c) => c.startsWith('read')).length;

  group('staging', () {
    test('a file bigger than one piece arrives whole, in order, one piece at a time', () async {
      final data = _bytes(copyChunk * 2 + 12345);
      fs.addFile('/v/clip.mp4', data);
      final progress = <int>[];

      final file = await staging.fetch(files, await fs.stat('/v/clip.mp4'), onProgress: progress.add);

      expect(file.uri.pathSegments.last, 'clip.mp4');
      expect(file.readAsBytesSync(), data);
      expect(progress, [copyChunk, copyChunk * 2, data.length]);
      expect(fs.calls.where((c) => c.startsWith('read')).map((c) => c.split('@')[1].split('+')[0]), [
        '0',
        '$copyChunk',
        '${copyChunk * 2}',
      ]);
    });

    test('the same file again is not read again, and says it is all there', () async {
      fs.addFile('/v/clip.mp4', _bytes(1000));
      final stat = await fs.stat('/v/clip.mp4');
      final first = await staging.fetch(files, stat);
      final before = reads();
      final heard = <int>[];

      final again = await staging.fetch(files, stat, onProgress: heard.add);

      expect(again.path, first.path);
      expect(reads(), before);
      expect(heard, [1000]);
    });

    test('a file that changed on the machine is copied again, and the old copy goes', () async {
      fs.addFile('/v/clip.mp4', _bytes(1000), modified: DateTime.utc(2026, 1, 1));
      final old = await staging.fetch(files, await fs.stat('/v/clip.mp4'));
      fs.addFile('/v/clip.mp4', _bytes(1500), modified: DateTime.utc(2026, 1, 2));

      final fresh = await staging.fetch(files, await fs.stat('/v/clip.mp4'));

      expect(fresh.lengthSync(), 1500);
      expect(old.existsSync(), isFalse, reason: 'one copy at a time');
      expect(Directory('${root.path}/copies').listSync().length, 1);
    });

    List<String> readOffsets() =>
        fs.calls.where((c) => c.startsWith('read')).map((c) => c.split('@')[1].split('+')[0]).toList();

    List<File> leftOver() => Directory('${root.path}/copies').listSync(recursive: true).whereType<File>().toList();

    test('a copy that is cancelled keeps what it has; the next copy continues there and reads only the rest', () async {
      final data = _bytes(copyChunk * 3);
      fs.addFile('/v/clip.mp4', data);
      final stat = await fs.stat('/v/clip.mp4');
      final cancel = ReadCancel();

      await expectLater(
        staging.fetch(files, stat, cancel: cancel, onProgress: (_) => cancel.cancel()),
        throwsA(isA<ReadCancelled>()),
      );
      final kept = leftOver();
      expect(kept.single.path, endsWith('clip.mp4.part'));
      expect(kept.single.lengthSync(), copyChunk, reason: 'the first piece is on the phone');

      final heard = <int>[];
      final file = await staging.fetch(files, stat, onProgress: heard.add);

      expect(file.readAsBytesSync(), data, reason: 'one file, no piece twice or out of place');
      expect(readOffsets(), ['0', '$copyChunk', '${copyChunk * 2}'], reason: 'the first piece was not read again');
      expect(heard, [copyChunk, copyChunk * 2, copyChunk * 3], reason: 'it starts at what it already has');
      expect(leftOver().map((f) => f.path), [file.path]);
    });

    test('a connection that drops keeps the part too', () async {
      final data = _bytes(copyChunk * 2 + 5);
      fs.addFile('/v/clip.mp4', data);
      final stat = await fs.stat('/v/clip.mp4');

      await expectLater(
        staging.fetch(files, stat, onProgress: (_) => fs.fail = const HerdrTransportException('link dropped')),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.network)),
      );
      expect(leftOver().single.lengthSync(), copyChunk);

      fs.fail = null;
      final file = await staging.fetch(files, stat);
      expect(file.readAsBytesSync(), data);
    });

    test('a file that changed since the part was written starts over from the first byte', () async {
      final old = _bytes(copyChunk * 2);
      fs.addFile('/v/clip.mp4', old, modified: DateTime.utc(2026, 1, 1));
      final stat = await fs.stat('/v/clip.mp4');
      final cancel = ReadCancel();
      await expectLater(
        staging.fetch(files, stat, cancel: cancel, onProgress: (_) => cancel.cancel()),
        throwsA(isA<ReadCancelled>()),
      );
      // Same size, new time: the part holds the old file's first piece.
      final changed = Uint8List.fromList(old.map((b) => b ^ 0x5A).toList());
      fs.addFile('/v/clip.mp4', changed, modified: DateTime.utc(2026, 1, 2));
      fs.calls.clear();

      final file = await staging.fetch(files, stat);

      expect(file.readAsBytesSync(), changed, reason: 'nothing of the old first piece survives');
      expect(readOffsets(), ['0', '$copyChunk'], reason: 'all of it read again');
    });

    test(
      'a file that changes under a continued copy is refused by the host: the part goes, the copy starts over',
      () async {
        final racy = _Racy();
        final files = RemoteFiles(FakeTransport()..fs = racy, machineId: 'm1');
        final old = _bytes(copyChunk * 2);
        racy.addFile('/v/clip.mp4', old, modified: DateTime.utc(2026, 1, 1));
        final stat = await racy.stat('/v/clip.mp4');
        final cancel = ReadCancel();
        await expectLater(
          staging.fetch(files, stat, cancel: cancel, onProgress: (_) => cancel.cancel()),
          throwsA(isA<ReadCancelled>()),
        );
        // The file is rewritten after the continued copy looked at it and before
        // it reads: only the read's own check can notice.
        final changed = Uint8List.fromList(old.map((b) => b ^ 0x5A).toList());
        racy.beforeRead = () => racy.addFile('/v/clip.mp4', changed, modified: DateTime.utc(2026, 1, 2));
        racy.calls.clear();

        final file = await staging.fetch(files, stat);

        expect(file.readAsBytesSync(), changed, reason: 'whole and from one version of the file');
        expect(racy.calls.where((c) => c.startsWith('read')).map((c) => c.split('@')[1].split('+')[0]).toList(), [
          '$copyChunk',
          '0',
          '$copyChunk',
        ], reason: 'the continued read was refused, then everything again from 0');
      },
    );

    test('a file that is shorter than it was said to be is an error, not a short copy', () async {
      fs.addFile('/v/clip.mp4', _bytes(1000));
      final said = RemoteStat(path: '/v/clip.mp4', kind: RemoteEntryKind.file, size: 5000);

      await expectLater(
        staging.fetch(files, said),
        throwsA(isA<RemoteFileException>().having((e) => e.message, 'message', contains('changed while'))),
      );

      expect(Directory('${root.path}/copies').listSync(recursive: true).whereType<File>(), isEmpty);
    });

    test('a refused read is the machine\u2019s own error, and removes the half copy', () async {
      fs.addFile('/v/clip.mp4', _bytes(1000));
      final stat = await fs.stat('/v/clip.mp4');
      fs.deny.add('/v/clip.mp4');

      await expectLater(
        staging.fetch(files, stat),
        throwsA(isA<RemoteFileException>().having((e) => e.kind, 'kind', RemoteFileErrorKind.permission)),
      );

      expect(Directory('${root.path}/copies').listSync(recursive: true).whereType<File>(), isEmpty);
    });

    test('two copies of the same file at once leave one whole file, not two writers on one part', () async {
      final data = _bytes(copyChunk * 2 + 77);
      fs.addFile('/v/clip.mp4', data);
      final stat = await fs.stat('/v/clip.mp4');

      final both = await Future.wait([staging.fetch(files, stat), staging.fetch(files, stat)]);

      expect(both[0].path, both[1].path);
      expect(both[0].readAsBytesSync(), data);
      expect(reads(), 3, reason: 'the second one finds the first one\u2019s copy');
    });

    test('a copy cancelled while it waits its turn never starts', () async {
      fs.addFile('/v/a.mp4', _bytes(copyChunk * 2));
      fs.addFile('/v/b.mp4', _bytes(10));
      final waiting = ReadCancel()..cancel();

      final first = staging.fetch(files, await fs.stat('/v/a.mp4'));
      await expectLater(
        staging.fetch(files, await fs.stat('/v/b.mp4'), cancel: waiting),
        throwsA(isA<ReadCancelled>()),
      );
      await first;

      expect(fs.calls.where((c) => c.contains('/v/b.mp4')).where((c) => c.startsWith('read')), isEmpty);
    });

    test('the copy of a file with an odd name stays inside its folder', () async {
      fs.addFile('/v/a\u0001b.mp4', _bytes(10));

      final file = await staging.fetch(files, await fs.stat('/v/a\u0001b.mp4'));

      expect(file.parent.parent.path, '${root.path}/copies');
      expect(file.uri.pathSegments.last, 'a_b.mp4');
    });
  });

  group('copy model', () {
    late FakeExport export;
    late FileCopyModel model;

    setUp(() {
      export = FakeExport();
      model = FileCopyModel(files: files, staging: staging, export: export);
      addTearDown(model.dispose);
    });

    test('share copies first, then hands the copy over, and a second share does not copy again', () async {
      fs.addFile('/v/clip.mp4', _bytes(3000));
      final stat = await fs.stat('/v/clip.mp4');

      expect((await model.share(stat)).done, isTrue);
      final once = reads();
      expect((await model.share(stat)).done, isTrue);

      expect(export.files, ['clip.mp4', 'clip.mp4']);
      expect(reads(), once);
      expect(model.phase, CopyPhase.done);
      expect(model.file!.lengthSync(), 3000);
    });

    test('a video goes to the gallery from the same copy', () async {
      fs.addFile('/v/clip.mp4', _bytes(3000));
      final stat = await fs.stat('/v/clip.mp4');
      await model.copy(stat);
      final once = reads();

      expect((await model.saveVideo(stat)).done, isTrue);

      expect(export.videos, ['clip.mp4']);
      expect(reads(), once);
    });

    test('a failed copy says why and offers nothing to share; the next ask tries again', () async {
      fs.addFile('/v/clip.mp4', _bytes(3000));
      final stat = await fs.stat('/v/clip.mp4');
      fs.deny.add('/v/clip.mp4');

      final result = await model.share(stat);

      expect(result.done, isFalse);
      expect(result.problem, isNotEmpty);
      expect(model.phase, CopyPhase.failed);
      expect(model.failure, result.problem);
      expect(export.files, isEmpty);
      fs.deny.clear();
      expect((await model.share(stat)).done, isTrue);
      expect(model.phase, CopyPhase.done);
      expect(model.failure, isNull);
    });

    test('a share sheet that cannot open is reported, and the copy stays', () async {
      fs.addFile('/v/clip.mp4', _bytes(300));
      final stat = await fs.stat('/v/clip.mp4');
      export.failWith = const PhotoExportException('The share sheet could not be opened.');

      final result = await model.share(stat);

      expect(result, (done: false, problem: 'The share sheet could not be opened.'));

      expect(model.phase, CopyPhase.done);
      expect(model.file, isNotNull);
    });

    test('cancelling stops the copy without calling it a failure', () async {
      fs.addFile('/v/clip.mp4', _bytes(copyChunk * 3));
      final stat = await fs.stat('/v/clip.mp4');
      void cancelOnFirstPiece() {
        if (model.written > 0) model.cancel();
      }

      model.addListener(cancelOnFirstPiece);

      final result = await model.copy(stat);
      model.removeListener(cancelOnFirstPiece);

      expect(result, isNull);
      expect(model.phase, CopyPhase.idle);
      expect(model.failure, isNull);
      expect((await model.share(stat)).done, isTrue, reason: 'it can be asked for again after a cancel');
      expect(model.phase, CopyPhase.done);
    });

    test('a share cancelled during the copy ends without a word and shares nothing', () async {
      fs.addFile('/v/clip.mp4', _bytes(copyChunk * 3));
      final stat = await fs.stat('/v/clip.mp4');
      model.addListener(() {
        if (model.written > 0) model.cancel();
      });

      final result = await model.share(stat);

      expect(result, (done: false, problem: null));
      expect(export.files, isEmpty);
    });

    test('a second tap while the share is being made does not open a second share sheet', () async {
      fs.addFile('/v/clip.mp4', _bytes(copyChunk * 2));
      final stat = await fs.stat('/v/clip.mp4');

      final first = model.share(stat);
      final second = await model.share(stat);
      await first;

      expect(second, (done: false, problem: null));
      expect(export.files, ['clip.mp4']);
      expect(model.handing, isFalse);
    });

    test('a copy that was removed from the phone is made again, not handed over as a missing path', () async {
      fs.addFile('/v/clip.mp4', _bytes(500));
      final stat = await fs.stat('/v/clip.mp4');
      final first = (await model.copy(stat))!;
      first.deleteSync();

      final again = (await model.copy(stat))!;

      expect(again.existsSync(), isTrue);
      expect(again.lengthSync(), 500);
    });

    test('a file that changed on the machine while it was copied is copied again, not served old', () async {
      fs.addFile('/v/clip.mp4', _bytes(copyChunk * 2), modified: DateTime.utc(2026, 1, 1));
      final old = await fs.stat('/v/clip.mp4');
      final slow = model.copy(old);
      fs.addFile('/v/clip.mp4', _bytes(900), modified: DateTime.utc(2026, 1, 2));

      final fresh = await model.copy(await fs.stat('/v/clip.mp4'));
      await slow;

      expect(fresh!.lengthSync(), 900);
      expect(model.file!.lengthSync(), 900);
    });

    test('asks that arrive while a copy runs join it', () async {
      fs.addFile('/v/clip.mp4', _bytes(copyChunk * 2));
      final stat = await fs.stat('/v/clip.mp4');

      final both = await Future.wait([model.copy(stat), model.copy(stat)]);

      expect(both[0]!.path, both[1]!.path);
      expect(reads(), 2);
    });
  });
}

/// A [FakeFs] that lets a test change the file just before the next read.
class _Racy extends FakeFs {
  void Function()? beforeRead;

  @override
  Future<Uint8List> read(String path, int offset, int length, {RemoteStat? ifMatch}) {
    final hook = beforeRead;
    beforeRead = null;
    hook?.call();
    return super.read(path, offset, length, ifMatch: ifMatch);
  }
}
