import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/app_settings.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/attention_set.dart';
import '../../core/approval_button.dart';
import '../../core/brand_mark.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/tap_guard.dart';
import '../../core/tokens.dart';
import '../create/new_agent_session_screen.dart';
import '../history/past_sessions_navigation.dart';
import '../machines/machine_form_screen.dart';
import 'agent_card.dart';
import 'agent_session_rows.dart';
import 'agents_grouping.dart';
import 'batch_action_bar.dart';
import 'batch_actions_sheet.dart';
import 'board_selection.dart';
import 'reply_sheet.dart';
import 'swipe_review.dart';
import 'triage_pill.dart';

/// Every agent across every machine, grouped by how much it needs you:
/// terminal agents and agent sessions in the same sections, so "what waits"
/// has one place to look and the sections never trade places as sessions
/// start or stop waiting (they used to lead the board then, moving every card
/// under the thumb). Needs you and Done count and order what [AttentionSet]
/// says, the same as the badge, the pill and the triage sheet.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key, this.onShowMachines, this.onSelectingChanged});

  /// Takes the person to the Machines tab, where connection problems are
  /// explained and fixed.
  final VoidCallback? onShowMachines;

  /// Called with true when the board starts picking agents for a batch action
  /// and false when it stops: the shell hides its tab bar meanwhile.
  final ValueChanged<bool>? onSelectingChanged;

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> with RestorationMixin {
  AgentStatus? _filter;
  bool? _reportedVisible;
  AgentSessions? _sessions;

  // Collapsed sections, one bit per status, so the set survives the process
  // being reclaimed. Nothing secret lives here.
  final _collapsedBits = RestorableInt(0);

  // The last page built. A hidden tab hands this back instead of rebuilding,
  // so fleet updates cost the tab that is not on screen one cheap build call.
  Widget? _page;

  // Which agents are picked for a batch action. Not restored: a restart
  // starts without it. Only the rows and the two bars listen to it.
  final _selection = BoardSelection();
  List<String> _visibleRefs = const [];
  Set<String> _liveRefs = const {};
  bool _retainQueued = false;
  bool _wasSelecting = false;

  // Answers on cards move when a card above them comes or goes: the gate
  // closes for a moment so a tap aimed at the old place cannot answer for
  // another agent. [_answerLayout] is the lines down to the last answerable
  // card, as the last build saw them.
  final _gate = SettleGate();
  List<Key>? _answerLayout;

  // A line's last laid-out height is read through the key its child carries,
  // at the moment the agent stops waiting: [_folding] holds those that left
  // Needs you, each a gap shrinking where the card stood. [_lastEntries] is
  // the list the last build showed.
  final _measure = <String, GlobalKey>{};
  final _folding = <String, ({double height, Key? after, int at})>{};
  List<AgentEntry> _lastEntries = const [];

  @override
  String get restorationId => 'agents';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_collapsedBits, 'collapsed');
  }

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
  }

  /// Tells the shell when picking starts and ends, so it can put its tab bar
  /// away.
  void _onSelection() {
    final active = _selection.active;
    if (active == _wasSelecting) return;
    _wasSelecting = active;
    widget.onSelectingChanged?.call(active);
  }

  @override
  void dispose() {
    _sessions?.setBoardVisible(false);
    _selection
      ..removeListener(_onSelection)
      ..dispose();
    _gate.dispose();
    _collapsedBits.dispose();
    super.dispose();
  }

  Set<AgentStatus> get _collapsed => {
        for (final s in AgentStatus.values)
          if (_collapsedBits.value & (1 << s.index) != 0) s,
      };

  void _addMachine() => openMachineForm(context);

  void _newSession() => unawaited(openNewAgentSession(context));

  void _pastSessions() => unawaited(openPastSessions(context));

  void _toggleFilter(AgentStatus s) => setState(() => _filter = _filter == s ? null : s);

  void _toggleSection(AgentStatus s) =>
      setState(() => _collapsedBits.value ^= 1 << s.index);

  /// Tells the sessions when the tab is on screen: they list their hosts
  /// every minute only then.
  void _reportVisible(bool visible) {
    if (_reportedVisible == visible) return;
    _reportedVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _sessions?.setBoardVisible(_reportedVisible ?? false);
    });
  }

  /// An explicit choice, from what the board shows now (which `auto` may have
  /// decided): the other look, and it stays.
  void _toggleDensity({required bool cards}) => unawaited(
        context.read<AppSettings>().setDensity(cards ? BoardDensity.compact : BoardDensity.cards),
      );

  @override
  Widget build(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled;
    _reportVisible(visible);
    if (!visible) {
      if (_page case final page?) return page;
    }
    final overview = context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    // Rebuilds on a density choice; what the choice means depends on how many
    // agents there are (`auto`), so it is read with the overview in hand.
    context.select<AppSettings, BoardDensity>((s) => s.density);
    final sessions = _sessions = context.watch<AgentSessions?>();
    final attention = context.watch<AttentionSet>();
    final cards = context.read<AppSettings>().cardsFor(overview.agents.length);
    return _page = _buildPage(context, overview, sessions, attention, cards: cards);
  }

  Widget _buildPage(
    BuildContext context,
    AgentsOverview overview,
    AgentSessions? sessions,
    AttentionSet attention, {
    required bool cards,
  }) {
    final ds = context.ds;
    final clearance = FloatingTabBar.clearance(context);

    if (overview.machineCount == 0) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          const SliverLargeTitle(title: 'Agents'),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: clearance),
              child: EmptyState(
                mark: const BrandMark(),
                title: 'Your agents, in your pocket',
                message: 'Connect a machine running herdr to see every coding '
                    'agent, know the moment one needs you, and reply from anywhere.',
                action: AppButton(
                  label: 'Add your first machine',
                  icon: LucideIcons.plus,
                  onPressed: _addMachine,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final sessionList = sessions?.sessions ?? const <AgentSessionView>[];
    final sections = boardSections(overview.agents, sessionList, attention);
    // A filter whose agents are all gone cannot be cleared by its chip any
    // more. Drop it for good, so it does not come back by itself when an
    // agent of that status shows up again.
    if (_filter != null && !sections.any((s) => s.status == _filter)) _filter = null;
    final filter = _filter;
    final entries = agentEntries(sections, filter: filter, collapsed: _collapsed);
    _armGateWhenAnswersMove(entries);
    final listed = _withFolding(entries, overview);
    final indexes = entryIndexes(listed);

    final chips = [for (final s in sections) if (filterableStatuses.contains(s.status)) s];
    final chipsHeight = chips.isEmpty ? 0.0 : AppChip.height;
    final troubled = overview.troubled;
    final blockedCount = attention.needsYou.length;
    final review = attention.toReview.length;
    // Room under the last row for the floating triage pill.
    final pillSpace = blockedCount == 0 ? 0.0 : TriagePill.height + Gap.md;

    // What All picks: the rows the board shows (open sections, this filter),
    // and what a pane that went away takes out of the selection.
    _visibleRefs = [
      for (final e in entries)
        if (e is AgentLine && e.open)
          paneRef(e.agent.key)
        else if (e is SessionLine && e.open)
          sessionRef(e.session.key),
    ];
    _liveRefs = {
      for (final a in overview.agents) paneRef(a.key),
      for (final s in sessionList) sessionRef(s.key),
    };
    if (_selection.active) _queueRetain();

    final list = AppRefresh(
      onRefresh: () async {
        await Future.wait([
          context.read<FleetRepository>().retryAll(),
          if (sessions != null) sessions.refresh(),
        ]);
      },
      edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true, bottomHeight: chipsHeight),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverLargeTitle(
            title: 'Agents',
            subtitle: Text(
              _summary(overview, sessionList.length),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
            actions: [
              CircleButton(
                icon: cards ? LucideIcons.list : LucideIcons.layoutGrid,
                tooltip: cards ? 'Compact list' : 'Cards with preview',
                onPressed: () => _toggleDensity(cards: cards),
              ),
              CircleButton(
                icon: LucideIcons.history,
                tooltip: 'Past sessions',
                onPressed: _pastSessions,
              ),
              CircleButton(
                icon: LucideIcons.plus,
                tooltip: 'New agent session',
                onPressed: _newSession,
              ),
            ],
            bottom: chips.isEmpty
                ? null
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    // Chips slide out through the page gutter, not under it.
                    clipBehavior: Clip.none,
                    child: Row(
                      children: [
                        for (final (i, s) in chips.indexed) ...[
                          if (i > 0) const SizedBox(width: Gap.sm),
                          AppChip(
                            label: s.status.label,
                            count: s.count,
                            leading: StatusGlyph(status: s.status, size: 14),
                            selected: filter == s.status,
                            onTap: () => _toggleFilter(s.status),
                          ),
                        ],
                      ],
                    ),
                  ),
            bottomHeight: chipsHeight,
          ),
          if (troubled.isNotEmpty)
            SliverPadding(
              // The chip row's 44dp box and the section label's top padding
              // already leave air around the strip.
              padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
              sliver: SliverToBoxAdapter(
                child: _ConnectionStrip(
                  troubled: troubled,
                  onShowMachines: widget.onShowMachines,
                ),
              ),
            ),
          if (overview.agents.isEmpty && troubled.isEmpty && sessionList.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: clearance),
                child: const EmptyState(
                  icon: LucideIcons.moon,
                  title: 'No agents running',
                  message: 'Start one in herdr and it will appear here.',
                ),
              ),
            )
          else ...[
            SliverList.builder(
              itemCount: listed.length,
              findChildIndexCallback: (key) => indexes[key],
              itemBuilder: (context, i) => switch (listed[i]) {
                final AgentHeader h => SectionLabel(
                    key: h.key,
                    label: h.status.label,
                    // Only offline ones listed: "Needs you · 2 offline", not
                    // a 0 that reads as a count of nothing beside them.
                    count: h.count == 0 && h.offline > 0 ? null : h.count,
                    expanded: h.expanded,
                    onTap: () => _toggleSection(h.status),
                    trailing: _headerTrailing(h, review: review),
                  ),
                final AgentLine l => Collapse(
                    key: l.key,
                    open: l.open,
                    // Measured when the agent stops waiting (see
                    // [_withFolding]); the key follows the line.
                    child: KeyedSubtree(
                      key: _measure.putIfAbsent(l.agent.key, GlobalKey.new),
                      // The board's job is to let you answer: an agent that is
                      // blocked and reachable keeps its card and its answers
                      // even in the compact list.
                      child: cards || (l.agent.status == AgentStatus.blocked && !l.agent.stale)
                          ? AgentCard(agent: l.agent)
                          : AgentCompactRow(agent: l.agent, divider: !l.last),
                    ),
                  ),
                final SessionLine l => Collapse(
                    key: l.key,
                    open: l.open,
                    child: AgentSessionRow(session: l.session, divider: !l.last),
                  ),
                final AgentFolding f => _FoldAway(
                    key: f.key,
                    height: f.height,
                    onDone: () => _folded(f.agentKey),
                  ),
              },
            ),
            SliverToBoxAdapter(child: SizedBox(height: clearance + pillSpace)),
          ],
        ],
      ),
    );
    // Always a Stack, so the list keeps its elements (rows, scroll offset)
    // when the pill comes and goes. Picking agents puts a bar over the title
    // bar and one over the tab bar's place (the shell hides its own), and the
    // pill steps aside.
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<BoardSelection>.value(value: _selection),
        ChangeNotifierProvider<SettleGate>.value(value: _gate),
      ],
      child: _BackLeavesSelection(
        selection: _selection,
        child: Stack(
          children: [
            Positioned.fill(child: list),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SelectionHeader(onAll: () => _selection.selectAll(_visibleRefs)),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: BatchActionBar(
                onAction: (action) => unawaited(performBatchAction(context, action, _selection)),
              ),
            ),
            if (blockedCount > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: clearance,
                child: Center(
                  child: HideWhileSelecting(
                    child: TriagePill(
                      count: blockedCount,
                      review: review,
                      // The sheet walks the same set, in the same order:
                      // terminal agents and agent sessions.
                      onTap: () => showTriageSheet(context),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Closes [_gate] when the cards above an answer changed: one was removed or
  /// inserted, or the order changed. A card appended below the last answer
  /// moves nothing.
  void _armGateWhenAnswersMove(List<AgentEntry> entries) {
    var last = -1;
    for (final (i, e) in entries.indexed) {
      if (e is AgentLine && e.agent.status == AgentStatus.blocked && !e.agent.stale) last = i;
    }
    final layout = [for (final e in entries.take(last + 1)) e.key];
    final before = _answerLayout;
    _answerLayout = layout;
    if (before == null || before.isEmpty) return;
    final unmoved = before.length <= layout.length &&
        listEquals(before, layout.sublist(0, before.length));
    if (unmoved) return;
    _gate.arm();
  }

  /// [entries] with a gap, shrinking over [Motion.expand], where a card that
  /// stopped waiting stood. The card itself goes to its new section at once;
  /// the cards below glide up into the gap instead of jumping by a whole card
  /// (the next question moving up under a thumb that has not lifted yet).
  List<AgentEntry> _withFolding(List<AgentEntry> entries, AgentsOverview overview) {
    final now = {for (final a in overview.agents) a.key: a.status};
    _measure.removeWhere((key, _) => !now.containsKey(key));
    final before = _lastEntries;
    _lastEntries = entries;
    if (!Motion.reduced(context)) {
      bool leaves(AgentEntry e) =>
          e is AgentLine &&
          e.open &&
          e.agent.status == AgentStatus.blocked &&
          now[e.agent.key] != null &&
          now[e.agent.key] != AgentStatus.blocked;
      for (final (i, e) in before.indexed) {
        if (e is! AgentLine || !leaves(e) || _folding.containsKey(e.agent.key)) continue;
        final box = _measure[e.agent.key]?.currentContext?.findRenderObject();
        final height = box is RenderBox && box.hasSize ? box.size.height : 0.0;
        if (height <= 0) continue;
        var anchor = i - 1;
        while (anchor >= 0 && leaves(before[anchor])) {
          anchor--;
        }
        _folding[e.agent.key] = (height: height, after: anchor < 0 ? null : before[anchor].key, at: i);
      }
    }
    if (_folding.isEmpty) return entries;
    final out = [...entries];
    for (final MapEntry(key: agentKey, value: gap) in _folding.entries) {
      var at = 0;
      if (gap.after != null) {
        final anchor = out.indexWhere((e) => e.key == gap.after);
        at = anchor < 0 ? math.min(gap.at, out.length) : anchor + 1;
      }
      out.insert(at, AgentFolding(agentKey, gap.height));
    }
    return out;
  }

  void _folded(String agentKey) {
    if (mounted && _folding.remove(agentKey) != null) setState(() {});
  }

  /// What a section header carries on its right. Needs you: how many of its
  /// rows are out of reach. Done: the same, then "Mark all reviewed" when
  /// something can be marked (an offline agent cannot: it is not counted and
  /// the note says why, instead of a button that would do nothing) and
  /// "Select all".
  Widget? _headerTrailing(AgentHeader h, {required int review}) => switch (h.status) {
        AgentStatus.blocked when h.offline > 0 => _OfflineNote(count: h.offline),
        AgentStatus.done => _ReviewActions(
            offline: h.offline,
            onMarkAll: review > 0 ? _markAllReviewed : null,
            onSelectAll: _selectAllDone,
          ),
        _ => null,
      };

  /// Picks every finished agent (terminal and session), opening the section
  /// they sit in so that what is picked is on screen.
  void _selectAllDone() {
    final overview = AgentsOverview.of(context.read<FleetRepository>());
    final sessions = _sessions?.sessions ?? const <AgentSessionView>[];
    final done = [
      for (final a in overview.agents)
        if (a.status == AgentStatus.done) paneRef(a.key),
      for (final s in sessions)
        if (boardStatus(s) == AgentStatus.done) sessionRef(s.key),
    ];
    if (done.isEmpty) return;
    setState(() => _collapsedBits.value &= ~(1 << AgentStatus.done.index));
    _selection.selectAll(done);
  }

  /// Marks every finished terminal agent and agent session reviewed at once,
  /// with one toast and one Undo: the "to review" of [AttentionSet], what a
  /// swipe could mark (reachable).
  void _markAllReviewed() {
    final toReview = context.read<AttentionSet>().toReview;
    final n = markAllReviewedWithUndo(
      context,
      panes: [
        for (final item in toReview)
          if (item case PaneAttention(:final agent)) (machine: agent.machine, paneId: agent.pane.id),
      ],
      sessions: [
        for (final item in toReview)
          if (item case SessionAttention(:final session)) session,
      ],
    );
    if (n > 0) Haptics.sent();
  }

  void _queueRetain() {
    if (_retainQueued) return;
    _retainQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _retainQueued = false;
      if (mounted) _selection.retain(_liveRefs);
    });
  }
}

/// "2 offline" on a section header: rows listed as last known, whose machine
/// or link is down. They are not in the section's count, the badge or the
/// pill, and nothing on the board can act on them until they are back.
class _OfflineNote extends StatelessWidget {
  const _OfflineNote({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) => Text(
        '$count offline',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Type.label.copyWith(color: context.ds.textMuted, fontFeatures: Type.tabular),
      );
}

/// The ghost buttons on the header of finished work: clear it all as reviewed
/// (one Undo; absent when nothing can be reached to mark), or pick it all for
/// a batch action, after the note of how many are offline. The row shrinks
/// (the labels ellipsize) before it can push the section's name off a narrow,
/// large-text screen.
class _ReviewActions extends StatelessWidget {
  const _ReviewActions({required this.onMarkAll, required this.onSelectAll, this.offline = 0});

  final VoidCallback? onMarkAll;
  final VoidCallback onSelectAll;
  final int offline;

  @override
  Widget build(BuildContext context) {
    final room = MediaQuery.sizeOf(context).width - 2 * Gap.gutter - 96;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.max(room, 120)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (offline > 0) ...[
            Flexible(child: _OfflineNote(count: offline)),
            const SizedBox(width: Gap.sm),
          ],
          if (onMarkAll case final markAll?)
            Flexible(
              child: AppButton(
                key: const ValueKey('mark-all-reviewed'),
                label: 'Mark all reviewed',
                kind: AppButtonKind.ghost,
                compact: true,
                onPressed: markAll,
              ),
            ),
          Flexible(
            child: AppButton(
              key: const ValueKey('select-all-done'),
              label: 'Select all',
              kind: AppButtonKind.ghost,
              compact: true,
              onPressed: onSelectAll,
            ),
          ),
        ],
      ),
    );
  }
}

/// Back leaves selection mode before it leaves anything else.
class _BackLeavesSelection extends StatelessWidget {
  const _BackLeavesSelection({required this.selection, required this.child});

  final BoardSelection selection;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !context.select<BoardSelection?, bool>((s) => s?.active ?? false),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) selection.cancel();
        },
        child: child,
      );
}

String _summary(AgentsOverview o, int agentSessions) {
  String count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
  return [
    count(o.machineCount, 'machine'),
    o.agents.isEmpty ? 'no agents' : count(o.agents.length, 'agent'),
    if (agentSessions > 0) count(agentSessions, 'agent session'),
    if (o.troubled.isNotEmpty) '${o.troubled.length} not connected',
  ].join(' · ');
}

/// Machines that are not connected, in one line. One machine is named and can
/// be retried here; several are summed up and the detail lives on the
/// Machines tab, so the agents stay on the first screen.
class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip({required this.troubled, required this.onShowMachines});

  final List<TroubledMachine> troubled;
  final VoidCallback? onShowMachines;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    if (troubled.length > 1) {
      final state = worstLinkState(troubled.map((t) => t.state));
      return StatusStrip(
        color: state.color(ds),
        leading: LinkDot(state: state),
        title: '${troubled.length} machines not connected',
        action: Icon(LucideIcons.chevronRight, size: 16, color: ds.textSecondary),
        onTap: onShowMachines,
      );
    }
    final t = troubled.single;
    return StatusStrip(
      key: ValueKey(t.machine.profile.id),
      color: t.state.color(ds),
      leading: LinkDot(state: t.state),
      title: t.label,
      detail: t.state.label,
      action: switch (t.approvalUrl) {
        final url? => ApprovalButton(url: url),
        null => AppButton(
            label: 'Retry',
            compact: true,
            kind: AppButtonKind.secondary,
            onPressed: t.machine.retry,
          ),
      },
    );
  }
}

/// A gap that was a card, closing. Not a card: it shows nothing, takes no tap.
class _FoldAway extends StatelessWidget {
  const _FoldAway({super.key, required this.height, required this.onDone});

  final double height;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: height, end: 0),
        duration: Motion.expand,
        curve: Motion.easeOut,
        onEnd: onDone,
        builder: (context, h, _) => SizedBox(height: h, width: double.infinity),
      );
}
