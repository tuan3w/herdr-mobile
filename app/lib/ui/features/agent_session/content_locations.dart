import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/acp_models.dart';
import '../../core/controls.dart';
import '../../core/markdown/markdown.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import '../files/file_viewer_screen.dart' show shortenFront;
import 'visible_text.dart';

/// Locations listed before `N more`.
const locationsShown = 4;

/// The files a tool call touched, as `path:line` rows: a tap opens the file
/// viewer at that line on the session's machine (the route a path in the
/// Markdown takes; the host is asked only now). The folder shrinks and the file
/// name and line never do. At most [locationsShown] rows, then `N more`.
/// Without an `MdActions` above (no machine to ask) the rows are plain text.
class ToolLocationRows extends StatelessWidget {
  const ToolLocationRows({super.key, required this.locations});

  final List<ToolLocation> locations;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final onPath = MdActions.maybeOf(context)?.onPath;
    final shown = [
      for (final l in locations)
        if (l.path.trim().isNotEmpty) l,
    ];
    final rows = shown.take(locationsShown).toList();
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final l in rows)
          _LocationRow(location: l, onTap: onPath == null ? null : () => onPath(context, l.path, l.line)),
        if (shown.length > locationsShown)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.sm + 15 + Gap.sm, Gap.xs, 0, 0),
            child: Text('+${shown.length - locationsShown} more', style: Type.caption.copyWith(color: ds.textMuted)),
          ),
      ],
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.location, required this.onTap});

  final ToolLocation location;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final path = visibleText(location.path.trim());
    final cut = path.lastIndexOf('/');
    final file = cut >= 0 ? path.substring(cut + 1) : path;
    final line = location.line;
    final tail = line == null ? file : '$file:$line';
    final full = cut >= 0 ? '${path.substring(0, cut + 1)}$tail' : tail;
    final tappable = onTap != null;
    final mono = TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.4);
    final scaler = MediaQuery.textScalerOf(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      child: Row(
        children: [
          Icon(LucideIcons.fileText, size: 15, color: ds.textTertiary),
          const SizedBox(width: Gap.sm),
          // The folder gives way (`…/deep/folder/`), the file name and the line
          // never do, short of a name wider than the screen.
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                final shown = shortenFront(full, box.maxWidth, mono, scaler);
                final head = shown.endsWith(tail) ? shown.substring(0, shown.length - tail.length) : '';
                return Text.rich(
                  TextSpan(
                    children: [
                      if (head.isNotEmpty) TextSpan(text: head, style: TextStyle(color: ds.textMuted)),
                      TextSpan(
                        text: shown.substring(head.length),
                        style: TextStyle(color: tappable ? ds.accentText : ds.textSecondary),
                      ),
                    ],
                    style: mono,
                  ),
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.clip,
                  textDirection: TextDirection.ltr,
                );
              },
            ),
          ),
        ],
      ),
    );
    if (!tappable) return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: row);
    return PressBuilder(
      onTap: onTap,
      semanticLabel: line == null ? 'Open $path' : 'Open $path at line $line',
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: kMinTap),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: pressed ? ds.fillPressed : const Color(0x00000000),
          borderRadius: BorderRadius.circular(Radii.row),
        ),
        child: row,
      ),
    );
  }
}
