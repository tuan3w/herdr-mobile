import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/release_info.dart';

/// What happened when the APK was handed to Android.
enum InstallStart {
  /// Android's installer is open on the APK; it asks the person to confirm,
  /// and restarts the app when the install is done.
  started,

  /// This app is not yet allowed to install apps ("Install unknown apps").
  /// The page where the person allows it has been opened.
  needsPermission,
}

/// Hands a downloaded APK to Android's package installer. The person always
/// confirms in the system's own dialog: nothing is installed silently.
abstract interface class ApkInstaller {
  /// Throws [UpdateException] when Android cannot open the installer.
  Future<InstallStart> install(File apk);
}

/// Android only, through `MainActivity` (`dev.herdrmobile/update`): the file
/// is shared with the installer through a FileProvider limited to the
/// `updates/` cache folder.
class PlatformApkInstaller implements ApkInstaller {
  const PlatformApkInstaller();

  static const channelName = 'dev.herdrmobile/update';

  static const _channel = MethodChannel(channelName);

  @override
  Future<InstallStart> install(File apk) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      throw const UpdateException('Installing updates works on Android only.');
    }
    try {
      final answer = await _channel.invokeMethod<String>('install', {'path': apk.path});
      return answer == 'needsPermission' ? InstallStart.needsPermission : InstallStart.started;
    } on PlatformException catch (e) {
      throw UpdateException(e.message ?? 'Android could not open the installer.');
    } on MissingPluginException {
      throw const UpdateException('Installing updates works on Android only.');
    }
  }
}
