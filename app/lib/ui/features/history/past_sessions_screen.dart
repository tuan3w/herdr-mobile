import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/past_session.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/agent_session_settings.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import '../agents/agent_navigation.dart';
import '../agent_session/visible_text.dart';
import 'past_session_row.dart';
import 'past_sessions_view_model.dart';

/// What the agents remember: every session an agent kept in its own store on a
/// machine, newest first, whether or not a keeper holds it now. Tap one to
/// bring it back (a new keeper replays it) or, when it is open already, to
/// show it.
class PastSessionsScreen extends StatelessWidget {
  const PastSessionsScreen({super.key, this.machineId, this.cwd});

  /// Preselected machine; the one used last otherwise.
  final String? machineId;

  /// The folder the opener works in: adds the `This folder` chip, on.
  final String? cwd;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
    create: (ctx) => PastSessionsViewModel(
      fleet: ctx.read<FleetRepository>(),
      sessions: ctx.read<AgentSessions>(),
      settings: ctx.read<AgentSessionSettings>(),
      machineId: machineId,
      cwd: cwd,
    ),
    child: const _Body(),
  );
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  final _search = TextEditingController();

  /// A list this short needs no search.
  static const _searchFrom = 6;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _tap(PastSessionsViewModel vm, PastSession past) async {
    final held = vm.openKeyFor(past);
    if (held != null) {
      Haptics.tick();
      unawaited(openAgent(context, SessionAgent(held)));
      return;
    }
    if (vm.resumingId != null) return;
    Haptics.tick();
    final toaster = Toaster.of(context);
    final nav = Navigator.of(context);
    final result = await vm.resume(past);
    final error = result.error;
    if (error != null) {
      toaster.show(error, kind: ToastKind.failed);
      return;
    }
    final session = result.session;
    if (session == null) return;
    if (mounted) {
      unawaited(openAgent(context, SessionAgent(session.key)));
    } else {
      // The person left while it came back: the session runs; say so.
      toaster.show(
        '${session.agentLabel} is back in ${cwdTail(past.cwd)}',
        action: ToastAction('Open', () => unawaited(openAgent(nav.context, SessionAgent(session.key)))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.watch<PastSessionsViewModel>();
    return Scaffold(
      backgroundColor: ds.bg,
      body: CustomScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverLargeTitle(
            title: 'Past sessions',
            leading: CircleButton(
              icon: LucideIcons.chevronLeft,
              tooltip: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ),
          if (vm.machines.isNotEmpty) SliverToBoxAdapter(child: _Filters(vm: vm)),
          if (vm.phase == PastPhase.ready && (vm.history?.sessions.length ?? 0) > _searchFrom)
            SliverToBoxAdapter(child: _SearchField(controller: _search, onChanged: vm.setQuery)),
          ..._content(context, vm),
        ],
      ),
    );
  }

  List<Widget> _content(BuildContext context, PastSessionsViewModel vm) {
    final inset = MediaQuery.paddingOf(context).bottom;
    Widget filler(Widget child) => SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(padding: EdgeInsets.only(bottom: inset), child: child),
    );
    final machine = vm.machine;
    switch (vm.phase) {
      case PastPhase.offline:
        return [
          filler(
            EmptyState(
              icon: LucideIcons.serverOff,
              title: vm.machineLost ? 'That machine went offline' : 'No machine is online',
              message: vm.machineLost
                  ? 'Pick another machine above.'
                  : 'Past sessions are read from the machine that ran them. Check the Machines tab, then come back.',
            ),
          ),
        ];
      case PastPhase.checking:
        return [_waiting('Asking ${machine?.profile.label ?? 'the machine'} which agents it has…')];
      case PastPhase.loading:
        return [_waiting('Reading what ${vm.agentLabel} remembers…')];
      case PastPhase.failed:
        return [
          filler(
            EmptyState(
              icon: LucideIcons.circleAlert,
              title: 'Couldn’t read past sessions',
              message: vm.failure ?? 'The machine did not answer.',
              action: AppButton(label: 'Retry', kind: AppButtonKind.secondary, onPressed: vm.retry),
            ),
          ),
        ];
      case PastPhase.noAgents:
        return [
          filler(
            EmptyState(
              icon: LucideIcons.bot,
              title: 'No agent installed',
              message: 'None of omp, Claude Code, Codex or pi is installed on ${machine?.profile.label ?? 'this machine'}.',
            ),
          ),
        ];
      case PastPhase.ready:
        return _ready(context, vm, inset, filler);
    }
  }

  Widget _waiting(String text) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: Gap.xl),
      child: Row(
        children: [
          const BusySpinner(),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Text(
              text,
              style: Type.secondary.copyWith(color: context.ds.textSecondary),
            ),
          ),
        ],
      ),
    ),
  );

  List<Widget> _ready(BuildContext context, PastSessionsViewModel vm, double inset, Widget Function(Widget) filler) {
    final ds = context.ds;
    final history = vm.history!;
    final label = vm.agentLabel;
    if (!history.canList) {
      return [
        filler(
          EmptyState(
            icon: LucideIcons.history,
            title: 'Not listed',
            message: "$label doesn't keep a list the phone can read.",
          ),
        ),
      ];
    }
    if (history.sessions.isEmpty) {
      return [
        filler(
          EmptyState(
            icon: LucideIcons.history,
            title: 'No past sessions',
            message: vm.folderOnly
                ? 'Nothing remembered for $label in this folder yet.'
                : 'Nothing remembered for $label here yet.',
          ),
        ),
      ];
    }
    final shown = vm.visible;
    if (shown.isEmpty) {
      return [
        filler(
          EmptyState(
            icon: LucideIcons.searchX,
            title: 'No matches',
            message: 'Nothing in the sessions listed matches “${visibleText(vm.query.trim())}”.',
          ),
        ),
      ];
    }
    final now = DateTime.now();
    final reopen = history.canReopen;
    return [
      if (!reopen)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.sm),
            child: Text(
              "$label can't reopen a past session from the phone.",
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ),
        ),
      SliverList.builder(
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final past = shown[i];
          final open = vm.openKeyFor(past) != null;
          return PastSessionRow(
            key: ValueKey(past.sessionId),
            session: past,
            now: now,
            open: open,
            busy: vm.resumingId == past.sessionId,
            onTap: open || reopen ? () => unawaited(_tap(vm, past)) : null,
          );
        },
      ),
      if (history.more)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, 0),
            child: Text(
              'Showing the newest ${history.sessions.length}',
              textAlign: TextAlign.center,
              style: Type.caption.copyWith(color: ds.textMuted),
            ),
          ),
        ),
      SliverToBoxAdapter(child: SizedBox(height: inset + Gap.xl)),
    ];
  }
}

/// The machine (when there is a choice), the agent, and the folder, as chip
/// rows that scroll sideways.
class _Filters extends StatelessWidget {
  const _Filters({required this.vm});

  final PastSessionsViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final machines = vm.machines;
    final agents = vm.agents;
    final folder = vm.folder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (machines.length > 1)
          _ChipRow(
            label: 'Machine',
            chips: [
              for (final c in machines)
                _capped(
                  AppChip(
                    label: visibleText(c.profile.label),
                    leading: Icon(LucideIcons.server, size: 14, color: ds.textSecondary),
                    selected: c.profile.id == vm.machine?.profile.id,
                    onTap: () => vm.selectMachine(c.profile.id),
                  ),
                ),
            ],
          ),
        if (agents.isNotEmpty)
          _ChipRow(
            label: 'Agent',
            chips: [
              for (final r in agents)
                AppChip(label: r.label, selected: r.id == vm.agent, onTap: () => vm.selectAgent(r.id)),
            ],
          ),
        if (folder != null)
          _ChipRow(
            label: 'Folder',
            chips: [
              _capped(
                AppChip(
                  label: 'This folder',
                  semanticLabel: 'This folder, ${visibleText(cwdTail(folder))}',
                  leading: Icon(LucideIcons.folder, size: 14, color: ds.textSecondary),
                  selected: vm.folderOnly,
                  onTap: () => vm.setFolderOnly(!vm.folderOnly),
                ),
              ),
            ],
          ),
      ],
    );
  }

  static Widget _capped(Widget chip) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 240), child: chip);
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.label, required this.chips});

  /// What the row chooses, for a screen reader.
  final String label;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: AppChip.height,
    child: Semantics(
      container: true,
      label: label,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: Gap.sm),
        itemBuilder: (_, i) => Center(child: chips[i]),
      ),
    ),
  );
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, Gap.xs),
      child: Semantics(
        label: 'Search past sessions',
        textField: true,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => TextField(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onChanged: onChanged,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            style: Type.body.copyWith(fontSize: 15, color: ds.text),
            cursorColor: ds.accent,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: 'Search sessions',
              constraints: const BoxConstraints(minHeight: kMinTap, maxHeight: kMinTap),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              prefixIcon: Icon(LucideIcons.search, size: 16, color: ds.textTertiary),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : PressBuilder(
                      onTap: () {
                        controller.clear();
                        onChanged('');
                      },
                      semanticLabel: 'Clear search',
                      minTapSize: kMinTap,
                      builder: (context, pressed) =>
                          Icon(LucideIcons.x, size: 16, color: pressed ? ds.text : ds.textSecondary),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
