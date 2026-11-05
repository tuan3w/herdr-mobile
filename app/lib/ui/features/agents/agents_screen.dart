import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/words/plural.dart';
import '../../../data/repositories/attention_set.dart';
import '../machines/approval_button.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../shell/home_pages.dart';
import '../../support/step_clock.dart';
import '../../support/tap_guard.dart';
import '../create/new_agent_session_screen.dart';
import '../machines/machine_form_screen.dart';
import 'agent_card.dart';
import 'agent_more_row.dart';
import 'agent_session_rows.dart';
import 'agents_grouping.dart';
import 'batch_action_bar.dart';
import 'batch_actions_sheet.dart';
import 'board_selection.dart';
import 'reply_sheet.dart';
import 'swipe_review.dart';

/// Every agent across every machine, in one section per status: Needs you,
/// Working, To review, Idle ([boardLayout]), newest first within each, every
/// agent a row named by its task with `repo · branch · agent` under it. Why
/// (owner decision): grouped by project in start order, the board on the
/// phone gave no idea what to look at; by status, what needs the person and
/// what just changed are on top. Terminal agents and agent sessions share the
/// sections, so "what waits" has one place to look. Needs you and the status
/// line's `to review` count and order what [AttentionSet] says, the same as
/// the triage sheet and the notifications.
///
/// Calm by default: one status line says the count once, the first waiting
/// agent is a card with its answers and every other agent is a row. Why: the
/// count used to be said four times on one screen (a filter chip, the section
/// header, a floating pill and the tab badge), and chrome costs the focus a
/// glance is made of.
///
/// This is home: no bar under it. Its header opens Machines (the chip that
/// says how many are online) and Settings (the gear), as pages pushed over it
/// ([HomePages]). A pushed page leaves a picked set waiting for the person's
/// return, as any other pushed screen does: Back always comes home.
class AgentsScreen extends StatefulWidget {
  const AgentsScreen({super.key, this.pages = const HomePages(), this.onSelectingChanged});

  /// Opens Machines (where connection problems are explained and fixed) and
  /// Settings, and carries the update for the gear's dot.
  final HomePages pages;

  /// Called with true when the board starts picking agents for a batch action
  /// and false when it stops: Back is the board's then, not the app's.
  final ValueChanged<bool>? onSelectingChanged;

  @override
  State<AgentsScreen> createState() => _AgentsScreenState();
}

class _AgentsScreenState extends State<AgentsScreen> with RestorationMixin {
  // Idle shows its newest rows and folds the rest ([idleShown]); true opens
  // them. Not kept: the board opens folded again, the way a long inbox does.
  bool _idleOpen = false;

  // The rows the person has seen during this look, until they look afresh
  // (the board shown again, the app resumed): the idle fold never takes one,
  // so a row never slips into it under their eyes ([idleFoldFor]).
  SeenRows _seen = {};
  late final AppLifecycleListener _lifecycle;
  bool? _reportedVisible;
  AgentSessions? _sessions;

  // Folded sections, by status name, one per line, so the set survives the
  // process being reclaimed. Needs you never folds; a name this version does
  // not know is ignored. Its own id: 0.1.45 kept an int under `collapsed` and
  // 0.1.47 project keys under `folded-groups`, and a restored value of
  // another type read as this string would throw.
  final _foldedSections = RestorableString('');

  // The last page built. Hidden under a pushed page, the board hands this
  // back instead of rebuilding, so fleet updates cost it one cheap build call.
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
    registerForRestoration(_foldedSections, 'folded-sections');
  }

  @override
  void initState() {
    super.initState();
    _selection.addListener(_onSelection);
    _lifecycle = AppLifecycleListener(onResume: () => setState(() => _seen = {}));
  }

  /// Tells the shell when picking starts and ends (Back is the board's
  /// then), and makes room at the list's end for the batch bar.
  void _onSelection() {
    final active = _selection.active;
    if (active == _wasSelecting) return;
    _wasSelecting = active;
    widget.onSelectingChanged?.call(active);
    setState(() {});
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _sessions?.setBoardVisible(false);
    _selection
      ..removeListener(_onSelection)
      ..dispose();
    _gate.dispose();
    _foldedSections.dispose();
    super.dispose();
  }

  Set<AgentStatus> get _collapsed => foldedSectionsOf(_foldedSections.value);

  void _setCollapsed(Set<AgentStatus> sections) => _foldedSections.value = foldedSectionsText(sections);

  void _addMachine() => openMachineForm(context);

  void _newSession() => unawaited(openNewAgentSession(context));

  void _showMachines() => widget.pages.open(context, HomePage.machines);

  void _showSettings() => widget.pages.open(context, HomePage.settings);

  /// Settings, with a quiet dot while a newer version waits there (a
  /// suggestion, never a count: it is not something that needs the person).
  Widget _settingsButton() => ListenableBuilder(
    listenable: widget.pages.update ?? _noUpdate,
    builder: (context, _) => CircleButton(
      key: const ValueKey('settings'),
      icon: HerdrIcons.settings,
      tooltip: 'Settings',
      mark: widget.pages.update?.release != null,
      markLabel: 'update available',
      onPressed: _showSettings,
    ),
  );

  static final _noUpdate = Listenable.merge(const <Listenable>[]);

  void _toggleSection(AgentStatus s) => setState(() {
    final collapsed = _collapsed;
    if (!collapsed.remove(s)) collapsed.add(s);
    _setCollapsed(collapsed);
  });

  void _toggleIdle() => setState(() => _idleOpen = !_idleOpen);

  /// Reads the branches of a machine with a board row in a repo that has
  /// several open checkouts, once per machine for the app run
  /// ([MachineConnection.loadBranchesOnce]), after the frame: the rows are
  /// named by their checkout's folder until then. Never per rebuild: a
  /// machine already asked is skipped here.
  void _askBranches(BoardLayout layout) {
    final machines = <MachineConnection>{};
    for (final item in layout.items) {
      final (machine, cwd) = switch (item) {
        PaneItem(:final row) => (row.machine, row.machine.paneById(row.paneId)?.cwd),
        SessionItem(:final session) => (session.machine, session.cwd),
      };
      if (machines.contains(machine) || !machine.isLive || machine.branchesAsked) continue;
      final place = machine.places.of(cwd);
      if (place != null && machine.places.groupOf(place.workspaceId) != null) machines.add(machine);
    }
    if (machines.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final m in machines) {
        m.loadBranchesOnce();
      }
    });
  }

  /// Tells the sessions when the board is on screen (not under a pushed
  /// page): they list their hosts every minute only then.
  void _reportVisible(bool visible) {
    if (_reportedVisible == visible) return;
    if (visible) _seen = {};
    _reportedVisible = visible;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sessions?.setBoardVisible(_reportedVisible ?? false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final visible = TickerMode.valuesOf(context).enabled;
    _reportVisible(visible);
    if (!visible) {
      if (_page case final page?) return page;
    }
    final overview = context.select<FleetRepository, AgentsOverview>(AgentsOverview.of);
    final sessions = _sessions = context.watch<AgentSessions?>();
    final attention = context.watch<AttentionSet>();
    return _page = _buildPage(context, overview, sessions, attention);
  }

  Widget _buildPage(BuildContext context, AgentsOverview overview, AgentSessions? sessions, AttentionSet attention) {
    // No bar under home: the list ends above the system inset, and keeps the
    // batch bar's room only while it is up, so the last row can be read
    // above it.
    final inset = MediaQuery.paddingOf(context).bottom;
    final listEnd = _selection.active ? FloatingBar.listEnd(context) : inset + Gap.xl;

    if (overview.machineCount == 0) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // Settings stays one tap away before the first machine; there is no
          // fleet yet for the chip to sum up, and nothing to start.
          SliverLargeTitle(title: 'Agents', actions: [_settingsButton()]),
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: inset),
              child: EmptyState(
                mark: const BrandMark(),
                title: 'No machines yet',
                message: 'Add a machine running herdr and its agents show here.',
                action: AppButton(label: 'Add your first machine', icon: LucideIcons.plus, onPressed: _addMachine),
              ),
            ),
          ),
        ],
      );
    }

    final sessionList = sessions?.sessions ?? const <AgentSessionView>[];
    final layout = boardLayout(overview.agents, sessionList, attention);
    _askBranches(layout);
    final entries = boardEntries(
      layout,
      collapsed: _collapsed,
      idleOpen: _idleOpen,
      showMachine: overview.machineCount > 1,
      idleFold: idleFoldFor(layout, _seen),
    );
    _armGateWhenAnswersMove(entries);
    final listed = _withFolding(entries, overview);
    final indexes = entryIndexes(listed);

    final troubled = overview.troubled;
    final needYouCount = attention.needsYou.length;
    final working = layout.working;

    // What All picks: the rows the board shows (open sections),
    // and what a pane that went away takes out of the selection.
    _visibleRefs = [
      for (final e in entries)
        if (e is AgentLine && e.open)
          paneRef(e.agent.key)
        else if (e is SessionLine && e.open)
          sessionRef(e.session.key),
    ];
    _liveRefs = {for (final a in overview.agents) paneRef(a.key), for (final s in sessionList) sessionRef(s.key)};
    if (_selection.active) _queueRetain();

    final status = _StatusLine(
      waiting: needYouCount,
      review: layout.toReviewCount,
      reviewOffline: layout.toReviewOffline,
      onReview: _selectToReview,
      working: working,
      agents: overview.agents.length + sessionList.length,
      machines: overview.machineCount,
      troubled: troubled.length,
    );
    // Measured once per build with the longest "heard" the minute can grow
    // into, so the header does not change height (and move the list) as the
    // minutes tick.
    final heard = heardLabel(context.read<FleetRepository>().connections);
    final statusLines = status.lines(context, heard: heard == null ? null : _StatusLine.longestHeard);

    final list = AppRefresh(
      onRefresh: () async {
        await Future.wait([context.read<FleetRepository>().retryAll(), if (sessions != null) sessions.refresh()]);
      },
      edgeOffset: SliverLargeTitle.extent(context, hasSubtitle: true, subtitleLines: statusLines),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverLargeTitle(
            title: 'Agents',
            // The board's one status line. Steps once a minute, so "heard 3m
            // ago" grows while nothing else changes: a board that went quiet
            // says so instead of looking live. It takes a second line rather
            // than cut its end ("1 not connected") on a narrow phone.
            subtitle: MinuteBuilder(
              builder: (context, _) => Text.rich(
                status.span(context, heard: heardLabel(context.read<FleetRepository>().connections)),
                maxLines: statusLines,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            subtitleLines: statusLines,
            // Scrolled, the bar keeps the chip and the two actions, and no
            // centred `Agents` to collide with the chip (home needs no name).
            compactTitle: false,
            // The fleet's health, and the way to Machines: status first, a
            // way in second.
            leading: _MachineHealth(
              online: overview.enabledCount - troubled.length,
              enabled: overview.enabledCount,
              worst: troubled.isEmpty ? null : worstLinkState(troubled.map((t) => t.state)),
              onTap: _showMachines,
            ),
            // Two actions, the budget (DESIGN.md Hierarchy 6): start an agent,
            // and Settings. Past sessions is a row of the `+` form, where
            // resuming is one of the ways to start.
            actions: [
              CircleButton(icon: LucideIcons.plus, tooltip: 'New agent session', onPressed: _newSession),
              _settingsButton(),
            ],
          ),
          // Kept as a strip, not folded into the status line: it carries the
          // next step (Retry, Approve, or Machines), which words in a subtitle
          // cannot. It sits right under the header, where the status line is,
          // and both come back with the top of the list.
          if (troubled.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
              sliver: SliverToBoxAdapter(
                child: _ConnectionStrip(troubled: troubled, onShowMachines: _showMachines),
              ),
            ),
          if (overview.agents.isEmpty && troubled.isEmpty && sessionList.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: inset),
                child: const EmptyState(
                  icon: LucideIcons.moon,
                  title: 'No agents running',
                  message: 'Start one in herdr and it shows here.',
                ),
              ),
            )
          else ...[
            SliverList.builder(
              itemCount: listed.length,
              findChildIndexCallback: (key) => indexes[key],
              itemBuilder: (context, i) => switch (listed[i]) {
                final AgentHeader h => _SectionHeader(
                  key: h.key,
                  label: sectionLabel(h.status),
                  // Needs you, Working and To review are counted by the
                  // status line, so their headers do not say it again.
                  count: _countedAbove(h.status) ? null : h.section.count,
                  expanded: h.collapsible ? h.expanded : null,
                  onTap: h.collapsible ? () => _toggleSection(h.status) : null,
                  actions: h.status == AgentStatus.blocked ? _needsYouActions(h.section, needYou: needYouCount) : null,
                ),
                final AgentLine l => Collapse(
                  key: l.key,
                  open: l.open,
                  // Measured when the agent stops waiting (see
                  // [_withFolding]); the key follows the line.
                  child: KeyedSubtree(
                    key: _measure.putIfAbsent(l.agent.key, GlobalKey.new),
                    // The board's job is to let you answer: the agent in
                    // front of Needs you keeps its card and its answers;
                    // every other agent is a row (the triage walk, from the
                    // header, answers the waiting ones in turn).
                    child: l.front ? AgentCard(agent: l.agent) : AgentCompactRow(agent: l.agent, divider: !l.last),
                  ),
                ),
                final SessionLine l => Collapse(
                  key: l.key,
                  open: l.open,
                  child: AgentSessionRow(session: l.session, divider: !l.last, where: l.where),
                ),
                final AgentMore m => AgentMoreRow(key: m.key, more: m, onTap: _toggleIdle),
                final AgentFolding f => _FoldAway(key: f.key, height: f.height, onDone: () => _folded(f.agentKey)),
              },
            ),
            SliverToBoxAdapter(child: SizedBox(height: listEnd)),
          ],
        ],
      ),
    );
    // Picking agents puts a bar over the title bar and the batch bar at the
    // bottom, the one bar home ever has there.
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
                onReview: _markReviewed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Closes [_gate] when the lines above the card's answers changed: one was
  /// removed or inserted, or the order changed. A line appended below the
  /// card moves nothing.
  void _armGateWhenAnswersMove(List<AgentEntry> entries) {
    var last = -1;
    for (final (i, e) in entries.indexed) {
      if (e is AgentLine && e.front) last = i;
    }
    final layout = [for (final e in entries.take(last + 1)) e.key];
    final before = _answerLayout;
    _answerLayout = layout;
    if (before == null || before.isEmpty) return;
    final unmoved = before.length <= layout.length && listEquals(before, layout.sublist(0, before.length));
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

  /// What the Needs you header carries on its right: how many of its rows are
  /// out of reach, then the walk through every waiting agent (the triage
  /// sheet) when more than one waits: only the first is a card.
  _HeaderActions _needsYouActions(BoardSection section, {required int needYou}) => _HeaderActions(
    offline: section.offline,
    // The action's room is kept while there is no action (its 44 dp box,
    // and the choice of line made as if it were there): a second agent
    // starting to wait must not move the card in front under the thumb.
    holdsFor: _answerOneByOne,
    actions: [
      if (needYou > 1)
        // The sheet walks the same set, in the same order: terminal agents
        // and agent sessions.
        (
          key: const ValueKey('answer-one-by-one'),
          label: _answerOneByOne,
          tone: TextActionTone.accent,
          onTap: () => unawaited(showTriageSheet(context)),
        ),
    ],
  );

  static const _answerOneByOne = 'Answer one by one';

  /// Whether the status line already counts this section.
  static bool _countedAbove(AgentStatus s) =>
      s == AgentStatus.blocked || s == AgentStatus.working || s == AgentStatus.done;

  /// The status line's `3 to review`: picks exactly the finished agents that
  /// can be marked ([toReviewRefs]), for the batch bar's Reviewed (one toast,
  /// one Undo) or any other batch action, and opens To review if it was
  /// folded so that what is picked is on screen. Why a selection and not a
  /// Mark reviewed at once: the person sees what they clear before they clear
  /// it, and can drop one.
  void _selectToReview() {
    final refs = toReviewRefs(context.read<AttentionSet>());
    if (refs.isEmpty) return;
    final collapsed = _collapsed;
    if (collapsed.remove(AgentStatus.done)) setState(() => _setCollapsed(collapsed));
    _selection.selectOnly(refs);
  }

  /// The batch bar's Reviewed: marks the picked agents that are to review
  /// ([refs]) reviewed at once, under one toast whose Undo restores them
  /// all, and ends picking.
  void _markReviewed(Set<String> refs) {
    final toReview = context.read<AttentionSet>().toReview;
    final n = markAllReviewedWithUndo(
      context,
      panes: [
        for (final item in toReview)
          if (item case PaneAttention(:final agent) when refs.contains(paneRef(item.key)))
            (machine: agent.machine, paneId: agent.pane.id),
      ],
      sessions: [
        for (final item in toReview)
          if (item case SessionAttention(:final session) when refs.contains(sessionRef(session.key))) session,
      ],
    );
    if (n > 0) Haptics.sent();
    _selection.cancel();
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
/// or link is down. They are not in the status line's count,
/// and nothing on the board can act on them until they are back.
class _OfflineNote extends StatelessWidget {
  const _OfflineNote({required this.count});

  final int count;

  static String words(int count) => '$count offline';

  static TextStyle style(Ds ds) => Type.label.copyWith(color: ds.textMuted, fontFeatures: Type.tabular);

  @override
  Widget build(BuildContext context) =>
      Text(words(count), maxLines: 1, overflow: TextOverflow.ellipsis, style: style(context.ds));
}

/// One ghost button on a section header, as data, so the header can measure
/// its words before it decides where they go.
typedef _HeaderAction = ({Key key, String label, TextActionTone tone, VoidCallback onTap});

/// What a header carries after its name: the note of how many of its agents
/// are offline, then its ghost buttons (Needs you's walk).
class _HeaderActions {
  const _HeaderActions({required this.actions, this.offline = 0, this.holdsFor});

  final List<_HeaderAction> actions;
  final int offline;

  /// The label of an action that may come and go: its room is kept, and the
  /// header is laid out as if it were there, so its arrival moves nothing.
  final String? holdsFor;

  bool get isEmpty => actions.isEmpty && offline == 0 && holdsFor == null;

  /// The width the note and the buttons take on one line.
  double width(BuildContext context) {
    final ds = context.ds;
    final scaler = MediaQuery.textScalerOf(context);
    final labels = [
      for (final a in actions) a.label,
      if (holdsFor case final held? when !actions.any((a) => a.label == held)) held,
    ];
    final parts = [
      if (offline > 0) _textWidth(_OfflineNote.words(offline), _OfflineNote.style(ds), scaler),
      for (final l in labels) _textWidth(l, Type.labelStrong, scaler),
    ];
    final gaps = offline > 0 && labels.isNotEmpty
        ? Gap.sm + Gap.md * (labels.length - 1)
        : Gap.md * (labels.length - 1);
    return parts.fold(0.0, (a, b) => a + b) + (parts.length > 1 ? gaps : 0);
  }

  List<Widget> children() => [
    if (offline > 0) _OfflineNote(count: offline),
    for (final a in actions) TextAction(key: a.key, label: a.label, tone: a.tone, onTap: a.onTap),
  ];
}

double _textWidth(String text, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// A board section's header. Its name always shows whole: when the name and
/// the actions do not fit on one line (a narrow phone, large text), the
/// actions drop to their own line under it, left-aligned with the name, and
/// wrap if they must. Why not shrink them: an ellipsized "Mark re…" is an
/// action the person cannot read, and squeezing the name ("Do…") hid which
/// section the actions belong to.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.label,
    required this.count,
    required this.expanded,
    required this.onTap,
    required this.actions,
  });

  final String label;
  final int? count;
  final bool? expanded;
  final VoidCallback? onTap;
  final _HeaderActions? actions;

  /// The width the header's name, count and caret need on one line.
  double _labelWidth(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return _textWidth(label, Type.labelStrong, scaler) +
        (count == null ? 0 : Gap.sm + _textWidth('$count', Type.label.copyWith(fontFeatures: Type.tabular), scaler)) +
        (expanded == null ? 0 : Gap.xs + IconSize.row);
  }

  @override
  Widget build(BuildContext context) {
    final actions = this.actions;
    SectionLabel header({Widget? trailing}) =>
        SectionLabel(label: label, count: count, expanded: expanded, onTap: onTap, trailing: trailing);
    if (actions == null) return header();
    if (actions.isEmpty) return header();
    final room = MediaQuery.sizeOf(context).width - 2 * Gap.gutter;
    // One dp of slack for rounding between the measure and the layout.
    final oneLine = _labelWidth(context) + Gap.sm + actions.width(context) + 1 <= room;
    final items = actions.children();
    if (oneLine) {
      if (items.isEmpty) return header(trailing: const SizedBox(height: kMinTap));
      return header(
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, w) in items.indexed) ...[
              if (i > 0) SizedBox(width: i == 1 && actions.offline > 0 ? Gap.sm : Gap.md),
              w,
            ],
          ],
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header(),
        Container(
          constraints: const BoxConstraints(minHeight: kMinTap),
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
          child: Wrap(
            spacing: Gap.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final w in items)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: kMinTap),
                  child: Align(widthFactor: 1, heightFactor: 1, child: w),
                ),
            ],
          ),
        ),
      ],
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

/// How fresh the board is: the connected machine heard from longest ago, so
/// one that stopped answering shows before it is declared offline. Null when
/// no connected machine has answered yet.
String? heardLabel(List<MachineConnection> connections) {
  Duration? oldest;
  for (final c in connections) {
    if (c.state != LinkState.online) continue;
    final ago = c.heardAgo();
    if (ago != null && (oldest == null || ago > oldest)) oldest = ago;
  }
  if (oldest == null) return null;
  // design-lint: allow(raw-duration) the label's own resolution, not a timer
  return oldest < const Duration(minutes: 1)
      ? 'heard just now'
      : 'heard ${Elapsed.compact(oldest, seconds: false)} ago';
}

/// The board's one status line: `2 need you · 3 to review · 3 working ·
/// heard just now · 1 not connected`. The needs-you count is the only loud
/// words on it (the blocked text colour), and the only place the board says
/// it. `3 to review` is a quiet button: a tap picks those agents for the
/// batch bar's Reviewed. A board with nothing waiting or working says
/// `nothing running`, so the line always answers "is everything alive?".
/// Counts are tabular, so a number that changes does not shift the words
/// after it.
class _StatusLine {
  const _StatusLine({
    required this.waiting,
    required this.review,
    required this.reviewOffline,
    required this.onReview,
    required this.working,
    required this.agents,
    required this.machines,
    required this.troubled,
  });

  final int waiting;

  /// Finished agents that can be marked reviewed, and those out of reach
  /// (listed, last known, but not counted: nothing can mark them now).
  final int review;
  final int reviewOffline;
  final VoidCallback onReview;
  final int working;
  final int agents;
  final int machines;
  final int troubled;

  /// The longest [heardLabel] in practice (`Elapsed.compact` past an hour),
  /// for measuring.
  static const longestHeard = 'heard 23h 59m ago';

  /// The facts in order; the needs-you count is the loud one, the review
  /// count the button.
  List<_Fact> _facts(String? heard) {
    final quiet = [
      if (working > 0) '$working working' else if (waiting == 0 && agents > 0) 'nothing running',
      ?heard,
      if (troubled > 0) '$troubled not connected',
    ];
    if (waiting == 0 && review + reviewOffline == 0 && quiet.isEmpty) quiet.add(countOf(machines, 'machine'));
    return [
      if (waiting > 0) (text: needYou(waiting), kind: _FactKind.loud, tail: ''),
      // Offline ones are said, not counted: `3 to review, 1 offline`, or
      // `2 offline to review` when none can be marked now.
      if (review > 0)
        (text: '$review to review', kind: _FactKind.review, tail: reviewOffline > 0 ? ', $reviewOffline offline' : '')
      else if (reviewOffline > 0)
        (text: '$reviewOffline offline to review', kind: _FactKind.quiet, tail: ''),
      for (final q in quiet) (text: q, kind: _FactKind.quiet, tail: ''),
    ];
  }

  /// The line. [onReview] null: for measuring, the button as plain words of
  /// the same style and width.
  static TextSpan _join(Ds ds, List<_Fact> facts, {int breakAt = -1, VoidCallback? onReview}) => TextSpan(
    style: Type.secondary.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
    children: [
      for (final (i, f) in facts.indexed) ...[
        if (i > 0) TextSpan(text: i == breakAt ? '\n' : ' · '),
        switch (f.kind) {
          _FactKind.loud => TextSpan(
            text: f.text,
            style: Type.secondaryStrong.copyWith(color: ds.blockedText, fontFeatures: Type.tabular),
          ),
          _FactKind.quiet => TextSpan(text: f.text),
          _FactKind.review when onReview == null => TextSpan(
            text: f.text,
            style: _ReviewCount.style(ds, pressed: false),
          ),
          _FactKind.review => WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: _ReviewCount(key: const ValueKey('to-review'), text: f.text, onTap: onReview!),
          ),
        },
        if (f.tail.isNotEmpty) TextSpan(text: f.tail),
      ],
    ],
  );

  /// The line, with [heard] for this minute. When it does not fit one line
  /// it breaks between two facts, never inside one: `2 not` / `connected`
  /// read as two broken facts.
  TextSpan span(BuildContext context, {required String? heard}) {
    final ds = context.ds;
    final facts = _facts(heard);
    if (_fits(context, _join(ds, facts))) return _join(ds, facts, onReview: onReview);
    var at = facts.length - 1;
    while (at > 1 && !_fits(context, _join(ds, facts.sublist(0, at)))) {
      at--;
    }
    return _join(ds, facts, breakAt: at, onReview: onReview);
  }

  /// 1, or 2 when the line does not fit the large title's width.
  int lines(BuildContext context, {required String? heard}) => _fits(context, _join(context.ds, _facts(heard))) ? 1 : 2;

  /// Whether [text] fits one line of the large title (with the header's own
  /// text-scale cap, [kBarTextScale]).
  static bool _fits(BuildContext context, TextSpan text) {
    final painter = TextPainter(
      text: text,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: kBarTextScale),
      maxLines: 1,
    )..layout(maxWidth: math.max(0, MediaQuery.sizeOf(context).width - 2 * Gap.gutter));
    final fits = !painter.didExceedMaxLines;
    painter.dispose();
    return fits;
  }
}

enum _FactKind { loud, quiet, review }

/// One fact of the status line: its words, how they are drawn, and words
/// that follow it without a break (`, 1 offline`).
typedef _Fact = ({String text, _FactKind kind, String tail});

/// `3 to review` on the status line: a quiet button (secondary words, bold as
/// a quiet [TextAction] is, warming to the text colour on pointer-down). It
/// paints at the line's height; the large title gives the status line a
/// 44 dp band to hit ([SliverLargeTitle]), so the thumb need not find a
/// 22 dp line.
class _ReviewCount extends StatelessWidget {
  const _ReviewCount({super.key, required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  // A dotted underline says it can be tapped: weight alone (500 among 400)
  // read as one more count.
  static TextStyle style(Ds ds, {required bool pressed}) => Type.secondaryStrong.copyWith(
    color: pressed ? ds.text : ds.textSecondary,
    fontFeatures: Type.tabular,
    decoration: TextDecoration.underline,
    decorationStyle: TextDecorationStyle.dotted,
    decorationColor: ds.textTertiary,
  );

  @override
  // A node of its own: inline, its button would take the whole line's words.
  Widget build(BuildContext context) => Semantics(
    container: true,
    child: PressBuilder(
      onTap: onTap,
      haptic: true,
      button: true,
      semanticLabel: '$text, select them',
      // The line scales an inline widget by its text scale itself.
      builder: (context, pressed) => MediaQuery.withNoTextScaling(
        child: Text(text, maxLines: 1, style: style(context.ds, pressed: pressed)),
      ),
    ),
  );
}

/// Machines that are not connected, in one line. One machine is named and can
/// be retried here; several are summed up and the detail lives on Machines,
/// so the agents stay on the first screen.
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
        title: '${countOf(troubled.length, 'machine')} not connected',
        action: Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textSecondary),
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
        null => AppButton(label: 'Retry', compact: true, kind: AppButtonKind.secondary, onPressed: t.machine.retry),
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

/// The fleet at a glance, on the left of home's header: `2 of 3 machines`
/// with a mark, and a tap opens Machines. It reads as status, not as a
/// button: no fill at rest (the round buttons on the right have one),
/// secondary words, and its mark and words start on the large title's edge.
/// The mark is the [LinkDot] of the machine that most needs the person, the
/// same shape as its row on Machines: the quiet filled dot when every machine
/// that is on is online, the working ring while one connects, the blocked
/// ring with a dot for one to fix or approve, a quiet ring when every machine
/// is off. A switched-off machine is neither a problem nor online: it is not
/// counted.
class _MachineHealth extends StatelessWidget {
  const _MachineHealth({required this.online, required this.enabled, required this.worst, required this.onTap});

  final int online;
  final int enabled;

  /// The state that most needs the person among the machines not online;
  /// null when every one that is on is.
  final LinkState? worst;
  final VoidCallback onTap;

  static const _height = 36.0;

  /// From the bar's padded edge to the large title's: the mark lines up
  /// with the title's first letter.
  static const _inset = Gap.gutter - AppTopBar.edge;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final state = worst ?? (enabled == 0 ? LinkState.disabled : LinkState.online);
    final words = enabled == 0 ? 'All machines off' : '$online of ${countOf(enabled, 'machine')}';
    final spoken = enabled == 0 ? words : '$words online';
    return PressBuilder(
      key: const ValueKey('machine-health'),
      onTap: onTap,
      scale: PressScale.chip,
      button: true,
      minTapSize: kMinTap,
      semanticLabel: spoken,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: _height,
        padding: const EdgeInsets.symmetric(horizontal: _inset),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LinkDot(key: const ValueKey('machine-health-mark'), state: state),
            const SizedBox(width: Gap.sm),
            Flexible(
              child: Text(
                words,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.label.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
