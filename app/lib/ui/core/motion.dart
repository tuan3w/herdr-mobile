import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Motion tokens. UI motion stays under ~300ms and uses strong ease-out curves:
/// built-in curves are too weak, and ease-in delays the moment the user is
/// watching most closely.
abstract final class Motion {
  /// Entering / responding to input. Starts fast, settles gently.
  static const easeOut = Cubic(0.23, 1, 0.32, 1);

  /// Press-down feedback: snap in.
  static const press = Duration(milliseconds: 100);

  /// Release: slightly slower than the press, so the response never feels abrupt.
  static const release = Duration(milliseconds: 180);

  /// Default for state changes (colour, size of small elements).
  static const standard = Duration(milliseconds: 200);

  /// Expanding/collapsing sections.
  static const expand = Duration(milliseconds: 220);

  /// Honour the platform's reduced-motion setting: drop movement, keep
  /// colour/opacity changes.
  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  /// Duration for a control's pressed/released colour and scale: snap in,
  /// ease out.
  static Duration pressing(bool down) => down ? press : release;

  /// Bottom sheet open / close.
  static const sheetIn = Duration(milliseconds: 280);
  static const sheetOut = Duration(milliseconds: 200);

  /// Page push/pop (the Cupertino slide, shortened from the SDK's 500 ms).
  static const page = Duration(milliseconds: 300);
}

/// Light tap feedback shared by list rows.
void tapFeedback() => HapticFeedback.selectionClick();
