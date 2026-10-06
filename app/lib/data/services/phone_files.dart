import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show PlatformException;

/// A file the person chose on the phone, as a local path. Its bytes are never
/// read here: an upload streams from [path].
class PhoneFile {
  const PhoneFile({required this.path, required this.name, required this.size});

  final String path;
  final String name;
  final int size;
}

/// The system document picker could not be used; [message] is for the person.
class PhoneFileException implements Exception {
  const PhoneFileException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Files on the phone: the Storage Access Framework picker. A small interface
/// so a test hands the sheet files without a system dialog.
abstract interface class PhoneFilePicker {
  /// Opens the system picker (any file type, several at once). Empty when the
  /// person backs out. Throws [PhoneFileException] for a failure worth saying.
  Future<List<PhoneFile>> pick();

  /// Deletes the copy the picker made of [path], once it has been sent.
  Future<void> release(String path);
}

/// [PhoneFilePicker] over `file_picker`. On Android the plugin copies the
/// chosen document into the app's cache (`cache/file_picker/<time>/<name>`),
/// a native stream copy, so a 150 MB video never passes through Dart memory;
/// [release] removes that copy after the upload.
class DevicePhoneFilePicker implements PhoneFilePicker {
  const DevicePhoneFilePicker();

  @override
  Future<List<PhoneFile>> pick() async {
    final List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles();
    } on PlatformException {
      throw const PhoneFileException('The file picker could not be opened.');
    }
    final out = <PhoneFile>[];
    for (final f in picked) {
      final path = f.path;
      if (path == null) continue;
      final size = await f.length();
      if (size == null) continue;
      out.add(PhoneFile(path: path, name: f.name, size: size));
    }
    if (picked.isNotEmpty && out.isEmpty) {
      throw const PhoneFileException('Could not read that file from the phone.');
    }
    return out;
  }

  @override
  Future<void> release(String path) async {
    if (!path.contains('/file_picker/')) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } on Object {
      // The cache is the system's to trim.
    }
  }
}
