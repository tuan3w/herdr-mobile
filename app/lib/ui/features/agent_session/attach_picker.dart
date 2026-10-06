import 'package:flutter/services.dart' show PlatformException;
import 'package:image_picker/image_picker.dart';

import '../../../data/services/image_prep.dart' show ImagePrepException;

/// A picture the person chose, where the picker left it on the phone: any
/// format, at full size, not read yet. The composer decides what it becomes
/// (an image the agent sees, or a file uploaded to the host), by the same rule
/// as a picture of the gallery.
class PickedPhoto {
  const PickedPhoto({required this.path, required this.name, required this.size});

  /// The picker's copy (the app's cache).
  final String path;

  /// The file's name (`IMG_2031.jpg`).
  final String name;

  /// Bytes.
  final int size;
}

/// Where the composer's pictures come from: the phone's gallery or its camera.
/// A small interface so a test hands the composer pictures without a system
/// picker (which a widget test cannot open).
///
/// Both return null when the person backs out. A failure the person can act on
/// is an [ImagePrepException] (its message is shown as it is).
abstract interface class AttachPicker {
  Future<PickedPhoto?> photo();

  Future<PickedPhoto?> camera();
}

/// The phone's pickers through `image_picker`: the system photo picker (no
/// storage permission) and the camera app's capture intent (no camera
/// permission: the app does not declare `CAMERA`, so the plugin hands the shot
/// to the camera app, which has it). Nothing in the manifest is needed beyond
/// what the plugin merges in (its `FileProvider`).
class DevicePicker implements AttachPicker {
  const DevicePicker();

  @override
  Future<PickedPhoto?> photo() => _pick(ImageSource.gallery);

  @override
  Future<PickedPhoto?> camera() => _pick(ImageSource.camera);

  static Future<PickedPhoto?> _pick(ImageSource source) async {
    final XFile? file;
    try {
      file = await ImagePicker().pickImage(source: source);
    } on PlatformException catch (e) {
      throw ImagePrepException(switch (e.code) {
        'camera_access_denied' => 'The camera is not allowed. Allow it in the phone\u2019s settings for this app.',
        'no_available_camera' => 'This phone has no camera to use.',
        _ => source == ImageSource.camera ? 'The camera could not be opened.' : 'The photo picker could not be opened.',
      });
    }
    if (file == null) return null;
    // Nothing is read here: an agent that takes no images gets the file as it
    // is, and a picture over the encoder's limit goes up as a file too.
    return PickedPhoto(
      path: file.path,
      name: file.name.isEmpty ? file.path.split('/').last : file.name,
      size: await file.length(),
    );
  }
}
