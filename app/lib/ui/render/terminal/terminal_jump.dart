import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/herdr_models.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

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
/// A compact [FloatingPill]: it comes and goes with opacity and a small scale,
/// and while it fades out it keeps what it last said, so it does not turn
/// into a chevron on the way out. The owner fires the haptic and scrolls in
/// [onPressed].
class TerminalJumpPill extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
    final label = needsYou ? 'Needs you' : (unseen > 0 ? newLinesLabel(unseen) : null);
    return FloatingPill(
      icon: label == null ? LucideIcons.chevronsDown : null,
      leading: needsYou ? const StatusGlyph(status: AgentStatus.blocked, size: IconSize.row) : null,
      label: label,
      trailing: label == null
          ? null
          : Icon(LucideIcons.chevronsDown, size: IconSize.row, color: context.ds.textSecondary),
      size: FloatingPillSize.compact,
      tooltip: context.l10n.uiJumpToLatest,
      semanticLabel: label == null ? context.l10n.uiJumpToLatest : context.l10n.messageJumpToLatest(label),
      haptic: false,
      visible: visible,
      onTap: onPressed,
    );
  }
}
