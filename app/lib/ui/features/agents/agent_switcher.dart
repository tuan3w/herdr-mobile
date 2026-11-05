import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/attention_set.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'agent_navigation.dart';
import 'agents_grouping.dart';

/// The agent screens' way to the other agents without leaving the chat: the
/// bar's title is the switcher. It carries a chevron and, while other agents
/// need the person, their count; a tap opens [showAgentSwitcher]. Why: the
/// swipe goes one agent at a time and only tells who is next; this answers
/// "does anything else need me" from inside a chat, with no new space taken
/// on screen.

/// How many agents other than [agent] need the person now: the board's
/// Needs you (what can be answered). The caller rebuilds only when this number
/// changes (`select`), not on every event the fleet hears.
int othersNeedingYou(BuildContext context, AgentRef? agent) {
  final key = agent == null ? null : _attentionKey(agent);
  return context.select<AttentionSet?, int>(
    (attention) => attention == null ? 0 : attention.needsYou.where((item) => item.key != key).length,
  );
}

/// What the switcher title does, for a screen reader: said before the
/// title, its status and place.
const switchAgentLabel = 'Switch agent';

/// `AttentionItem.key` of [agent].
String _attentionKey(AgentRef agent) => switch (agent) {
  PaneAgent(:final machineId, :final paneId) => '$machineId/$paneId',
  SessionAgent(:final sessionKey) => 'session/$sessionKey',
};

/// The mark after the switcher title: a chevron, then the count of other
/// agents that need the person ([CountBadge]) while there are any. Nothing
/// moves at rest.
class AgentSwitchMark extends StatelessWidget {
  const AgentSwitchMark({super.key, required this.othersNeedYou});

  final int othersNeedYou;

  @override
  Widget build(BuildContext context) => Semantics(
    // The badge draws the number; this says it (`2 other agents need you`).
    label: othersNeedYou > 0 ? needYou(othersNeedYou, noun: 'other agent') : null,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(LucideIcons.chevronDown, size: IconSize.row, color: context.ds.textTertiary),
        if (othersNeedYou > 0) ...[const SizedBox(width: Gap.xs), CountBadge(count: othersNeedYou)],
      ],
    ),
  );
}

/// Every agent the board lists, in its sections and order, to switch to in
/// place. The row of [current] says `Here` and does nothing; another row
/// replaces this screen (Back still lands on the board).
/// The last row goes back to the board. Reads only what is in memory.
Future<void> showAgentSwitcher(BuildContext context, AgentRef current) => showAppSheet<void>(
  context,
  builder: (_) => _SwitcherSheet(screen: context, current: current),
);

class _SwitcherSheet extends StatelessWidget {
  const _SwitcherSheet({required this.screen, required this.current});

  /// The agent screen's context: where the switch happens.
  final BuildContext screen;
  final AgentRef current;

  /// [to] in place of this screen, as the board would open it: one agent
  /// per screen, so Back still lands on the board. It ends a swipe's walk,
  /// as opening from the board does.
  void _go(BuildContext sheet, AgentRef to) {
    Navigator.of(sheet).pop();
    unawaited(openAgent(screen, to, replace: true));
  }

  void _board(BuildContext sheet) {
    Navigator.of(sheet).pop();
    Navigator.of(screen).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    // The order follows what needs the person; AttentionSet speaks only when
    // that changes, so the open sheet does not rebuild per event.
    final attention = context.watch<AttentionSet?>();
    final layout = attention == null ? const BoardLayout() : boardLayoutOf(context, attention: attention);
    final several = context.read<FleetRepository>().connections.length > 1;
    final ds = context.ds;
    return SheetScaffold(
      title: switchAgentLabel,
      kind: SheetKind.list,
      bleed: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The board's sections and order, each row named as the board
          // names it (`repo · branch · agent`, and the machine when there are
          // several).
          for (final section in layout.sections) ...[
            SectionLabel(label: sectionLabel(section.status), count: section.count),
            for (final item in section.items) _row(context, ds, item, whereOfItem(item, showMachine: several)),
          ],
          const SizedBox(height: Gap.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
            child: SheetActionRow(
              action: SheetAction(
                label: 'All agents on the board',
                icon: HerdrIcons.agents,
                onTap: () => _board(context),
              ),
              onTap: () => _board(context),
            ),
          ),
        ],
      ),
    );
  }

  static String _titleOf(BoardItem item) => switch (item) {
    PaneItem(:final row) => row.title,
    SessionItem(:final session) => session.title,
  };

  Widget _row(BuildContext context, Ds ds, BoardItem item, String subtitle) {
    final here = item.agent == current;
    final stale = switch (item) {
      PaneItem(:final row) => row.stale,
      SessionItem(:final session) => !AttentionSet.sessionReachable(session),
    };
    return ListRow(
      key: ValueKey(item.agent),
      title: _titleOf(item),
      subtitle: subtitle,
      leading: StatusGlyph(status: statusOfItem(item), size: IconSize.lead),
      dim: stale,
      trailing: here ? Text('Here', style: Type.label.copyWith(color: ds.textMuted)) : null,
      onTap: here ? null : () => _go(context, item.agent),
    );
  }
}
