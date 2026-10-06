import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/batch_actions.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../core/tokens.dart';
import 'agents_grouping.dart';

/// How the selection names a terminal agent row (`AgentRowData.key`).
String paneRef(String rowKey) => 'p:$rowKey';

/// How the selection names an agent session (`AgentSessionView.key`).
String sessionRef(String sessionKey) => 's:$sessionKey';

/// Which board rows are picked for a batch action, and whether the board is
/// picking at all. Its own small notifier: only the rows (through
/// [rowSelect]) and the bars listen, so `AgentsOverview` and the sections
/// never rebuild for a tap. Not saved: a restart starts without it.
class BoardSelection extends ChangeNotifier {
  final Set<String> _refs = {};
  bool _active = false;
  String? _busy;
  bool _disposed = false;

  /// The board is picking agents.
  bool get active => _active;
  int get count => _refs.length;

  /// A copy, in no particular order.
  Set<String> get refs => Set.of(_refs);

  /// What the running batch says ("Interrupting 3 agents"), null when none
  /// runs. While one runs the selection is frozen.
  String? get busy => _busy;

  bool isSelected(String ref) => _refs.contains(ref);

  /// Picks or drops [ref]. The first pick (a long press) enters selection
  /// mode.
  void toggle(String ref) {
    if (_busy != null) return;
    if (!_refs.remove(ref)) _refs.add(ref);
    _active = true;
    _notify();
  }

  void selectAll(Iterable<String> refs) {
    if (_busy != null) return;
    _refs.addAll(refs);
    _active = true;
    _notify();
  }

  /// Drops what the board no longer lists. Silent for the person: the count
  /// just goes down.
  void retain(Set<String> live) {
    final before = _refs.length;
    _refs.removeWhere((r) => !live.contains(r));
    if (_refs.length != before) _notify();
  }

  /// Leaves selection mode. Does nothing while a batch runs.
  void cancel() {
    if (_busy != null || !_active) return;
    _refs.clear();
    _active = false;
    _notify();
  }

  void begin(String label) {
    _busy = label;
    _notify();
  }

  /// The batch is over: ends selection mode.
  void finish() {
    _busy = null;
    _refs.clear();
    _active = false;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// What a board row needs of the selection.
typedef RowSelect = ({bool active, bool selected});

/// Whether the board is picking and whether [ref] is picked, for a row to draw
/// itself. Rebuilds the row only when one of the two changes. A tree with no
/// [BoardSelection] is "not picking".
RowSelect rowSelect(BuildContext context, String ref) => context.select<BoardSelection?, RowSelect>(
      (s) => (active: s?.active ?? false, selected: s?.isSelected(ref) ?? false),
    );

/// The round mark of a picked (or pickable) row.
class SelectMark extends StatelessWidget {
  const SelectMark({super.key, required this.selected, this.size = 20});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // The row says "selected" once; the mark is only the picture.
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? ds.accent : ds.surface,
          border: Border.all(color: selected ? ds.accent : ds.textTertiary, width: 1.5),
        ),
        child: selected ? Icon(LucideIcons.check, size: size - 8, color: ds.onAccent) : null,
      ),
    );
  }
}

/// The look of a flat board row (the compact list, an agent session) while the
/// board is picking: a soft rounded tint inset like the pressed highlight, and
/// the selected state for screen readers. The structure is the same whether
/// or not the board is picking, so a long press that starts picking does not
/// rebuild the row's press state.
class SelectableRowFrame extends StatelessWidget {
  const SelectableRowFrame({super.key, required this.state, required this.child});

  final RowSelect state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      selected: state.active ? state.selected : null,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: state.selected ? ds.accent.withValues(alpha: ds.isDark ? 0.16 : 0.09) : Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.row),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Shows [child] only while the board is not picking (the triage pill).
class HideWhileSelecting extends StatelessWidget {
  const HideWhileSelecting({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      context.select<BoardSelection?, bool>((s) => s?.active ?? false) ? const SizedBox.shrink() : child;
}

/// The picked agents as they are right now: the terminal agents by section,
/// then the agent sessions. A pane or session that is gone is simply not
/// there.
List<BatchTarget> resolveBatchTargets({
  required Set<String> refs,
  required FleetRepository fleet,
  AgentSessions? sessions,
}) {
  final agents = fleet.agents;
  final rows = [for (final a in agents) agentRow(a, showMachine: false)];
  final byKey = {for (final (i, r) in rows.indexed) r.key: agents[i]};
  final terminals = [
    for (final group in groupByStatus(rows).values)
      for (final r in group)
        if (refs.contains(paneRef(r.key)))
          BatchTarget.terminal(
            machine: byKey[r.key]!.machine,
            paneId: r.paneId,
            title: r.title,
            agent: byKey[r.key]!.pane.agent ?? 'terminal',
            status: r.status,
          ),
  ];
  final list = sessions?.sessions ?? const <AgentSessionView>[];
  final picked = [
    for (final s in list)
      if (refs.contains(sessionRef(s.key))) BatchTarget.session(session: s, status: boardStatus(s)),
  ];
  return [...terminals, ...picked];
}
