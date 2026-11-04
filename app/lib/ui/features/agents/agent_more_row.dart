import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'agents_grouping.dart';

/// The row that stands for the rows a section folds away ("22 more idle", the
/// names of the first two under it) and opens them in place; open it says "Show
/// fewer". Quiet on purpose: it is inventory, not something that needs the
/// person. The caret stays, since it tells something here: this opens.
class AgentMoreRow extends StatelessWidget {
  const AgentMoreRow({super.key, required this.more, required this.onTap});

  final AgentMore more;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final open = more.open;
    final title = open ? 'Show less' : '${more.hidden} more ${more.status.name}';
    final detail = open ? null : more.names.map((n) => n.trim()).where((n) => n.isNotEmpty).join(' \u00B7 ');
    return PressRow(
      onTap: () {
        Haptics.tick();
        onTap();
      },
      minHeight: kMinTap,
      semanticLabel: open
          ? context.l10n.messageShowLessAgents(more.status.name)
          : context.l10n.messageAgentsFolded(title, detail == null || detail.isEmpty ? '' : '. $detail'),
      padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - PressRow.inset, vertical: Gap.sm),
      child: Row(
        children: [
          SizedBox(
            width: Gap.xxl,
            child: Caret(open: open),
          ),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Type.row.copyWith(color: ds.textSecondary)),
                if (detail != null && detail.isNotEmpty) ...[
                  const SizedBox(height: Gap.hair),
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
    );
  }
}
