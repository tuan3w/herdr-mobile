import 'package:flutter/widgets.dart';

import 'press.dart';
import 'theme.dart';

enum TextActionTone {
  /// The action a reader is offered (`Read all`, `Show more`): accent text.
  accent,

  /// An action that is there but not suggested (`Cancel request`, `Show
  /// fewer`): secondary text.
  quiet,
}

/// A word that does something, inline with content: `Read all`, `Show more`,
/// `12 more`, `Mark reviewed`. No fill and no underline; the colour says
/// it can be tapped. Paints its text only, takes a 44 dp touch target, and
/// warms to the primary text colour while pressed. A long label wraps to a
/// second line rather than lose its words. Disabled ([enabled] false) it
/// dims like a disabled [AppButton], takes no tap and reads as disabled.
class TextAction extends StatelessWidget {
  const TextAction({
    super.key,
    required this.label,
    required this.onTap,
    this.tone = TextActionTone.accent,
    this.haptic = true,
    this.semanticLabel,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final TextActionTone tone;

  /// The selection tick on tap. Off when the owner fires its own.
  final bool haptic;

  /// What a screen reader says in place of [label] (`12 more files`).
  final String? semanticLabel;

  /// False while the action may not be taken (a tap guard, an answer on its
  /// way): dimmed, no tap.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final rest = switch (tone) {
      TextActionTone.accent => ds.accentText,
      TextActionTone.quiet => ds.textSecondary,
    };
    final color = enabled ? rest : Ds.fade(rest, 0.4);
    return PressBuilder(
      onTap: enabled ? onTap : null,
      haptic: haptic,
      button: true,
      semanticLabel: semanticLabel,
      minTapSize: kMinTap,
      builder: (context, pressed) => Text(
        label,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Type.labelStrong.copyWith(color: pressed ? ds.text : color),
      ),
    );
  }
}
