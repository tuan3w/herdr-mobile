// A picture becomes the same attachment whichever way it was chosen (the
// gallery, the camera, the system picker): an image for an agent that takes
// images, a file uploaded to the host for one that takes none.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/services/image_prep.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_model.dart';
import 'package:herdr_mobile/ui/features/agent_session/attach_picker.dart';
import 'package:herdr_mobile/ui/features/attach/tray.dart';

import 'support/attach_fakes.dart';
import 'support/fake_agent_session.dart';

final _jpeg = fakePicture(1);

/// Hands out the one picture the camera or the system picker gave.
class _Picker implements AttachPicker {
  final _shot = PickedPhoto(path: '/cache/image_picker/IMG_7.jpg', name: 'IMG_7.jpg', size: _jpeg.length);

  @override
  Future<PickedPhoto?> camera() async => _shot;

  @override
  Future<PickedPhoto?> photo() async => _shot;
}

enum _Source { gallery, camera, systemPicker }

/// Attaches one picture from [source], lets every upload finish, and returns
/// its chip once ready with the number of uploads it took.
Future<(Attachment, int)> _attach(_Source source, {required bool images}) async {
  final session = FakeAgentSession()..imagesAccepted = images;
  final fake = FakeKit();
  final model = ComposerAttachments(
    session: session,
    picker: _Picker(),
    prepare: (b) async => PreparedImage(bytes: b, width: 96, height: 96),
    readFile: (_) async => _jpeg,
    kit: fake.kit,
  );
  addTearDown(model.dispose);
  switch (source) {
    case _Source.gallery:
      model.stage([GalleryPick(fake.gallery.assetAt(0))]);
      model.startStaged();
    case _Source.camera:
      unawaited(model.addPhoto(camera: true));
    case _Source.systemPicker:
      unawaited(model.addPhoto(camera: false));
  }
  var finished = 0;
  for (var i = 0; i < 100 && !(model.items.isNotEmpty && model.items.single.ready); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    for (; finished < fake.uploader.started.length; finished++) {
      fake.uploader.started[finished].finish();
    }
  }
  return (model.items.single, fake.uploader.started.length);
}

void main() {
  test('an agent that takes no images: a camera or system-picker photo goes up as a file, as a gallery photo does', () async {
    final (gallery, galleryUploads) = await _attach(_Source.gallery, images: false);
    expect(gallery.block, isA<ResourceLinkBlock>());
    expect(galleryUploads, 1);
    for (final source in [_Source.camera, _Source.systemPicker]) {
      final (chip, uploads) = await _attach(source, images: false);
      expect(chip.ready, isTrue, reason: '$source');
      expect(chip.block, isA<ResourceLinkBlock>(), reason: '$source: never an image block the agent refuses');
      expect(uploads, 1, reason: '$source: the original goes to the host');
      expect(chip.kind, gallery.kind, reason: '$source');
      expect(chip.note, gallery.note, reason: '$source: the chip says it goes as a file');
    }
  });

  test('an agent that takes images: every source gives an image block and uploads nothing', () async {
    for (final source in _Source.values) {
      final (chip, uploads) = await _attach(source, images: true);
      expect(chip.ready, isTrue, reason: '$source');
      expect(chip.block, isA<ImageBlock>(), reason: '$source');
      expect(uploads, 0, reason: '$source');
      expect(chip.note, isNull, reason: '$source');
    }
  });
}
