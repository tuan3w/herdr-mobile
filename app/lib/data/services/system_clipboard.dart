import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether the system shows its own confirmation when the app copies text:
/// Android 13 (API 33) and later do ("Copied to clipboard", in the phone's
/// language). Android's guidance is that an app then shows none of its own, or
/// the person reads two confirmations for one copy.
abstract final class SystemClipboard {
  /// Set by [detect] at start-up; false everywhere else (tests, other
  /// platforms, older Android), where the app says it itself.
  static bool confirms = false;

  static const _channel = MethodChannel('dev.herdrmobile/task');

  static Future<void> detect() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      confirms = (await _channel.invokeMethod<int>('sdkInt') ?? 0) >= 33;
    } on Object {
      confirms = false;
    }
  }
}
