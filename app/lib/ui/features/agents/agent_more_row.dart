import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/controls.dart';
import '../../core/tokens.dart';
import 'agents_grouping.dart';

/// The row that stands for the rows a section folds away ("22 more idle", the
/// names of the first two under it) and opens them in place; open it says "Show
/// fewer". Quiet on purpose: it is inventory, not something that needs the
/// person. The chevron stays, since it tells something here: this opens.
class AgentMoreRow extends StatelessWidget {
  const AgentMoreRow({super.key, required this.more, required this.onTap});

  final AgentMore more;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final open = more.open;
    final title = open ? 'Show fewer' : '${more.hidden} more ${more.status.name}';
    final detail = open ? null : more.names.map((n) => n.trim()).where((n) => n.isNotEmpty).join(' \u00B7 ');
    return PressBuilder(
      onTap: onTap,
      haptic: true,
      minTapSize: kMinTap,
      semanticLabel: open ? 'Show fewer ${more.status.name} agents' : '$title agents, folded${detail == null || detail.isEmpty ? '' : '. $detail'}',
      builder: (context, pressed) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.gutter, 10, Gap.gutter, 10),
        child: Row(
          children: [
            SizedBox(
              width: 32,
              child: Icon(open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 18, color: ds.textTertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Type.row.copyWith(color: pressed ? ds.text : ds.textSecondary)),
                  if (detail != null && detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondary.copyWith(color: ds.textMuted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
