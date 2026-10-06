import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/models/herdr_models.dart';
import 'controls.dart';
import 'glyphs.dart';
import 'motion.dart';
import 'theme.dart';

/// What the pill says about output that arrived while the reader was away:
/// `1 new line`, `3 new lines`, and past 99 just `99+ new`.
String newLinesLabel(int lines) {
  if (lines > 99) return '99+ new';
  return lines == 1 ? '1 new line' : '$lines new lines';
}

/// The way back to the newest line of a terminal, shown while the reader is
/// away from it.
///
/// - nothing arrived since they left: the round chevron;
/// - lines arrived ([unseen]): a pill that counts them (`3 new lines`);
/// - the agent started waiting on them ([needsYou]): a pill that says `Needs
///   you`, with the blocked glyph. It wins over the count.
///
/// It comes and goes with opacity and a small scale ([Motion.release], none
/// under reduced motion). While it fades out it keeps what it last said, so it
/// does not turn into a chevron on the way out. The pill paints 36 high inside a
/// 44 dp target. The owner fires the haptic and scrolls in [onPressed].
class TerminalJumpPill extends StatefulWidget {
  const TerminalJumpPill({
    super.key,
    required this.visible,
    required this.unseen,
    required this.needsYou,
    required this.onPressed,
  });

  final bool visible;

  /// Rows that arrived since the reader left the end.
  final int unseen;

  /// The pane is waiting for the reader.
  final bool needsYou;

  final VoidCallback onPressed;

  static const _height = 36.0;

  @override
  State<TerminalJumpPill> createState() => _TerminalJumpPillState();
}

class _TerminalJumpPillState extends State<TerminalJumpPill> {
  late int _unseen = widget.unseen;
  late bool _needsYou = widget.needsYou;

  @override
  void didUpdateWidget(TerminalJumpPill old) {
    super.didUpdateWidget(old);
    if (widget.visible) {
      _unseen = widget.unseen;
      _needsYou = widget.needsYou;
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = widget.visible;
    final duration = Motion.reduced(context) ? Duration.zero : Motion.release;
    return ExcludeSemantics(
      excluding: !visible,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: duration,
          curve: Motion.easeOut,
          child: AnimatedScale(
            scale: visible ? 1 : 0.92,
            duration: duration,
            curve: Motion.easeOut,
            child: _content(context),
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (!_needsYou && _unseen <= 0) {
      return CircleButton(
        icon: LucideIcons.chevronsDown,
        tooltip: 'Jump to latest',
        size: TerminalJumpPill._height,
        onPressed: widget.onPressed,
      );
    }
    final ds = context.ds;
    final label = _needsYou ? 'Needs you' : newLinesLabel(_unseen);
    final tint = _needsYou ? ds.blocked : ds.accent;
    final textColor = _needsYou ? ds.blockedText : ds.accentText;
    return Tooltip(
      message: 'Jump to latest',
      excludeFromSemantics: true,
      child: PressBuilder(
        onTap: widget.onPressed,
        scale: 0.96,
        semanticLabel: '$label, jump to latest',
        button: true,
        minTapSize: kMinTap,
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          height: TerminalJumpPill._height,
          padding: EdgeInsets.only(left: _needsYou ? 10 : 14, right: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(TerminalJumpPill._height / 2),
            // Opaque: it floats over text, which must not show through.
            color: Color.alphaBlend(
              tint.withValues(
                alpha: ds.isDark ? (pressed ? 0.3 : 0.22) : (pressed ? 0.2 : 0.14),
              ),
              ds.bg,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_needsYou) ...[
                const StatusGlyph(status: AgentStatus.blocked, size: 16),
                const SizedBox(width: 6),
              ],
              ExcludeSemantics(
                child: Text(
                  label,
                  maxLines: 1,
                  style: Type.label.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                    fontFeatures: Type.tabular,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(LucideIcons.chevronsDown, size: 16, color: textColor),
            ],
          ),
        ),
      ),
    );
  }
}
