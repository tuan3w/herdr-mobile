import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../data/services/system_clipboard.dart';
import 'motion.dart';
import 'toast.dart';

/// Copies [text] and confirms it once.
///
/// From Android 13 the system shows its own "Copied" toast for every copy, in
/// the phone's language; a second one from the app is noise (two toasts, one
/// black and one white, for one tap). So the app says [what] (`Path copied`)
/// only where the system does not ([SystemClipboard.confirms] false). A
/// [caveat] is news the system cannot give (`Only the first 1 MB was copied`)
/// and is always shown. A clipboard that refuses says so, always.
///
/// Completes true when the text is on the clipboard, so a caller that marks
/// success in place (the code block's check) marks only a real copy.
///
/// The one way the app copies (`tool/design_lint.dart` rule `clipboard`).
Future<bool> copyText(BuildContext context, String text, {required String what, String? caveat}) async {
  final toaster = Toaster.maybeOf(context);
  final copyFailed = context.l10n.uiCouldnTCopyTheClipboardRefusedIt;
  try {
    await Clipboard.setData(ClipboardData(text: text));
  } on PlatformException {
    toaster?.show(copyFailed, kind: ToastKind.failed);
    return false;
  }
  Haptics.tick();
  if (caveat != null) {
    toaster?.show(caveat);
  } else if (!SystemClipboard.confirms) {
    toaster?.show(what);
  }
  return true;
}
