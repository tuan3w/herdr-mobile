import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Sends the app's task to the background the way Home does, without
/// finishing the activity. Back at the root would finish it, which ends the
/// engine and every connection the "Watching" notice stands for.
abstract interface class TaskMover {
  /// False when the platform could not (or does not) move the task.
  Future<bool> moveToBack();
}

class PlatformTaskMover implements TaskMover {
  const PlatformTaskMover();

  static const channelName = 'dev.herdrmobile/task';

  static const _channel = MethodChannel(channelName);

  @override
  Future<bool> moveToBack() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
    try {
      return await _channel.invokeMethod<bool>('moveTaskToBack') ?? false;
    } on Object {
      return false;
    }
  }
}
