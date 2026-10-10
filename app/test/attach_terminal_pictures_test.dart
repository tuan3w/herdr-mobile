// A picture for an agent that runs in a terminal ([AttachMode.paths]): it is
// downscaled like any picture, then uploaded to the host as a small JPEG whose
// path is typed into the terminal. The original never goes, and the copy made
// for the upload does not stay on the phone.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/repositories/attach_target.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/data/services/phone_gallery.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_model.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:herdr_mobile/ui/features/attach/tray.dart';

import 'support/attach_fakes.dart';
import 'support/fake_agent_session.dart';

/// What the encoder made of the picture: not the original's bytes.
final _prepared = Uint8List.fromList([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);

class _Picker implements AttachPicker {
  @override
  Future<PickedPhoto?> camera() async => PickedPhoto(path: '/cache/image_picker/IMG_7.heic', name: 'IMG_7.heic', size: 900);

  @override
  Future<PickedPhoto?> photo() async => camera();
}

class _Rig {
  _Rig({AttachMode mode = AttachMode.paths})
    : session = FakeAgentSession()
        ..mode = mode
        ..imagesAccepted = false {
    model = ComposerAttachments(
      target: session,
      picker: _Picker(),
      prepare: (_) async => PreparedImage(bytes: _prepared, width: 8, height: 8),
      readFile: (_) async => Uint8List.fromList([9, 9, 9]),
      writeTemp: (bytes, name) async {
        final path = '/tmp/herdr-attach-x/$name';
        written[path] = bytes;
        return path;
      },
      deleteTemp: (path) async => deleted.add(path),
      kit: fake.kit,
    );
  }

  final FakeAgentSession session;
  final fake = FakeKit();
  late final ComposerAttachments model;
  final written = <String, Uint8List>{};
  final deleted = <String>[];

  /// Lets the model's microtasks run, then finishes every upload that started.
  Future<void> settle() async {
    var finished = 0;
    for (var i = 0; i < 100 && !(model.items.isNotEmpty && model.items.every((a) => a.ready)); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      for (; finished < fake.uploader.started.length; finished++) {
        fake.uploader.started[finished].finish();
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('a gallery picture goes up as the prepared JPEG, named after the picture, and ends as a link to the host copy', () async {
    final rig = _Rig();
    addTearDown(rig.model.dispose);
    rig.model
      ..stage([GalleryPick(rig.fake.gallery.assetAt(0))])
      ..startStaged();
    await rig.settle();

    final chip = rig.model.items.single;
    expect(chip.ready, isTrue);
    expect(chip.thumb, _prepared, reason: 'the chip shows what will be sent');
    expect(chip.note, startsWith('Uploaded'), reason: 'no "takes no images" note');
    expect(chip.block, isA<ResourceLinkBlock>());
    expect((chip.block! as ResourceLinkBlock).uri, startsWith('file:///home/dev/.herdr-mobile/inbox/'));

    final upload = rig.fake.uploader.started.single;
    expect(upload.fileName, rig.fake.gallery.assetAt(0).name);
    expect(rig.written[upload.localPath], _prepared, reason: 'the prepared copy, not the original');
    expect(rig.deleted, [upload.localPath], reason: 'the phone keeps no copy once it is up');
  });

  test('a camera or system-picker photo is the same: its stem with .jpg', () async {
    for (final camera in [true, false]) {
      final rig = _Rig();
      addTearDown(rig.model.dispose);
      await rig.model.addPhoto(camera: camera);
      await rig.settle();
      expect(rig.fake.uploader.started.single.fileName, 'IMG_7.jpg', reason: 'camera: $camera');
      expect(rig.model.items.single.ready, isTrue);
    }
  });

  test('a picture over the encoder limit still goes up, as the original', () async {
    final rig = _Rig();
    addTearDown(rig.model.dispose);
    final asset = rig.fake.gallery.assetAt(0);
    rig.fake.gallery.files[asset.id] = GalleryFile(path: '/cache/huge.jpg', name: 'huge.jpg', size: 30 * 1024 * 1024);
    rig.model
      ..stage([GalleryPick(asset)])
      ..startStaged();
    await rig.settle();

    final upload = rig.fake.uploader.started.single;
    expect(upload.localPath, '/cache/huge.jpg');
    expect(rig.written, isEmpty);
    expect(rig.model.items.single.ready, isTrue);
  });

  test('a write that fails drops the chip and says so', () async {
    final problems = <String>[];
    final rig = _Rig();
    addTearDown(rig.model.dispose);
    final model = ComposerAttachments(
      target: rig.session,
      picker: _Picker(),
      prepare: (_) async => PreparedImage(bytes: _prepared, width: 8, height: 8),
      readFile: (_) async => Uint8List(3),
      writeTemp: (_, _) => throw const FileSystemException('disk full'),
      onProblem: problems.add,
      kit: rig.fake.kit,
    );
    addTearDown(model.dispose);
    await model.addPhoto(camera: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(model.items, isEmpty);
    expect(problems, ['Could not prepare that picture.']);
  });

  test('a chip removed while its copy is written leaves nothing behind', () async {
    final rig = _Rig();
    final writing = Completer<void>();
    final written = <String>[];
    final deleted = <String>[];
    final model = ComposerAttachments(
      target: rig.session,
      picker: _Picker(),
      prepare: (_) async => PreparedImage(bytes: _prepared, width: 8, height: 8),
      readFile: (_) async => Uint8List(3),
      writeTemp: (bytes, name) async {
        await writing.future;
        written.add('/tmp/$name');
        return '/tmp/$name';
      },
      deleteTemp: (path) async => deleted.add(path),
      kit: rig.fake.kit,
    );
    addTearDown(model.dispose);
    final photo = model.addPhoto(camera: true);
    for (var i = 0; i < 20 && model.items.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    model.remove(model.items.single.id);
    writing.complete();
    await photo;
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(rig.fake.uploader.started, isEmpty);
    expect(written, isNotEmpty);
    expect(deleted, written, reason: 'every copy written is removed');
  });

  test('the real temp copy is a file of that name and goes with its folder', () async {
    final path = await ComposerAttachments.writeTempFile(_prepared, 'IMG_1.jpg');
    expect(File(path).readAsBytesSync(), _prepared);
    expect(path, endsWith('/IMG_1.jpg'));
    final dir = File(path).parent;
    expect(dir.path.split('/').last, startsWith('herdr-attach-'));

    await ComposerAttachments.deleteTempFile(path);
    expect(File(path).existsSync(), isFalse);
    expect(dir.existsSync(), isFalse);
    // Never throws, even when it is already gone.
    await ComposerAttachments.deleteTempFile(path);
  });

  test('an ACP agent that takes images still gets an image block and no upload', () async {
    final rig = _Rig(mode: AttachMode.blocks);
    rig.session.imagesAccepted = true;
    addTearDown(rig.model.dispose);
    rig.model
      ..stage([GalleryPick(rig.fake.gallery.assetAt(0))])
      ..startStaged();
    await rig.settle();

    expect(rig.model.items.single.block, isA<ImageBlock>());
    expect(rig.fake.uploader.started, isEmpty);
    expect(rig.written, isEmpty);
  });
}
