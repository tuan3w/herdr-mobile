import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';

/// Added lines as TEXT: >= 4.5:1 on the page, on `fill` and on `fillPressed`
/// (the theme's `done` is a fill colour for shapes and reaches 4.2:1 on paper
/// only). Dark reuses `done` (6.7:1 or better).
Color addedText(Ds ds) => ds.isDark ? ds.done : const Color(0xFF1B7343);

/// Removed lines as text: the theme's danger text tone.
Color removedText(Ds ds) => ds.dangerText;

/// `+3 −1`: lines added and removed, in the done and danger text tones. A side
/// that is zero is left out. Read aloud as words, not as signs.
class DiffStats extends StatelessWidget {
  const DiffStats({super.key, required this.added, required this.removed, this.style});

  final int added;
  final int removed;
  final TextStyle? style;

  /// The words a screen reader says.
  static String words(int added, int removed) => [
    if (added > 0) '$added ${added == 1 ? 'line' : 'lines'} added',
    if (removed > 0) '$removed ${removed == 1 ? 'line' : 'lines'} removed',
  ].join(', ');

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final base = (style ?? Type.caption).copyWith(fontFeatures: Type.tabular, fontWeight: FontWeight.w600);
    return Semantics(
      label: words(added, removed),
      excludeSemantics: true,
      // Never wider than 40% of the screen: past that it shrinks to fit
      // instead of pushing the line it belongs to out of its row.
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.4),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerRight,
          child: Text.rich(
            TextSpan(
              children: [
                if (added > 0) TextSpan(text: '+$added', style: base.copyWith(color: addedText(ds))),
                if (added > 0 && removed > 0) const TextSpan(text: ' '),
                if (removed > 0) TextSpan(text: '\u2212$removed', style: base.copyWith(color: removedText(ds))),
              ],
            ),
            maxLines: 1,
            softWrap: false,
          ),
        ),
      ),
    );
  }
}

/// The small disclosure caret of a fold: points right when folded, down when
/// open, turning over [Motion.expand] (a rotation, nothing else moves). Still
/// at rest once it has turned; reduced motion turns it at once.
class Caret extends StatelessWidget {
  const Caret({super.key, required this.open, this.size = 14});

  final bool open;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AnimatedRotation(
      turns: open ? 0.25 : 0,
      duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
      curve: Motion.easeOut,
      child: Icon(LucideIcons.chevronRight, size: size, color: context.ds.textTertiary),
    ),
  );
}
