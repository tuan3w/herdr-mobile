import 'package:flutter/widgets.dart';

import '../../core/theme.dart';

/// The composer's text controller, which draws what a just-picked command takes
/// (its hint, `<branch name>`) in the muted colour right after the command, as
/// ghost text. It is not in the field: it is not selected, copied or sent, and
/// it goes with the first character typed.
///
/// Why in the field and not only in the palette: the palette closes the moment
/// a command is picked, so the person is left with `/review ` and nothing to
/// say what goes after it.
class CommandHintController extends TextEditingController {
  CommandHintController({super.text, required this.hintFor});

  /// What the field's [text] is waiting for, or null (see
  /// `CommandPaletteModel.hintFor`). Read on every build of the field.
  final String? Function(String text) hintFor;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    // While an IME composes a word the text is not settled.
    if (withComposing && value.composing.isValid && !value.composing.isCollapsed) return base;
    final hint = hintFor(text);
    if (hint == null) return base;
    return TextSpan(
      style: style,
      children: [
        base,
        TextSpan(text: hint, style: style?.copyWith(color: context.ds.textMuted)),
      ],
    );
  }
}
