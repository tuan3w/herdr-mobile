import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/agent_host.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/agent_session_settings.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/form_sections.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import '../agents/agent_navigation.dart';
import '../history/past_sessions_navigation.dart';
import '../files/files_navigation.dart';
import 'machine_field.dart';
import 'new_agent_session_view_model.dart';
import 'session_prefill.dart';
import 'session_start_support.dart' show showStartedToast;

/// Opens the new-agent-session form, on [machine] when given. With [prefill]
/// the form starts from a running session (a duplicate) instead.
Future<void> openNewAgentSession(BuildContext context, {MachineConnection? machine, SessionPrefill? prefill}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NewAgentSessionScreen(machineId: machine?.profile.id, prefill: prefill),
    ));

/// Starts an agent session (the phone is an ACP client; the agent runs on the
/// machine behind a keeper). Start goes back to where the form was opened and
/// says what started; Start and open goes to its chat.
class NewAgentSessionScreen extends StatelessWidget {
  const NewAgentSessionScreen({super.key, this.machineId, this.prefill});

  /// Preselected machine; the one used last otherwise.
  final String? machineId;

  /// A running session to start another of: its machine, folder and agent
  /// win over [machineId] and what was used last.
  final SessionPrefill? prefill;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => NewAgentSessionViewModel(
          fleet: ctx.read<FleetRepository>(),
          sessions: ctx.read<AgentSessions>(),
          settings: ctx.read<AgentSessionSettings>(),
          machineId: machineId,
          prefill: prefill,
        ),
        child: const _Form(),
      );
}

class _Form extends StatefulWidget {
  const _Form();

  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  final _formKey = GlobalKey<FormState>();
  final _folder = TextEditingController();
  late final NewAgentSessionViewModel _vm = context.read<NewAgentSessionViewModel>();

  /// The machine the folder field was last prefilled for, and what it was
  /// prefilled with: the field follows the machine until the person types.
  String? _filledFor;
  String _filled = '';

  /// Whether the start running now opens the session when it is done: picks
  /// the button that shows the spinner.
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    if (_vm.prefill case final prefill?) {
      _filled = prefill.folder;
      _filledFor = prefill.machineId;
      _folder.text = _filled;
    }
    _vm.addListener(_syncFolder);
    _syncFolder();
  }

  @override
  void dispose() {
    _vm.removeListener(_syncFolder);
    _folder.dispose();
    super.dispose();
  }

  void _syncFolder() {
    final id = _vm.machine?.profile.id;
    if (id == null || id == _filledFor) return;
    _filledFor = id;
    if (_folder.text.trim().isNotEmpty && _folder.text != _filled) return;
    _filled = _vm.rememberedFolder;
    _folder.text = _filled;
  }

  Future<void> _browse(MachineConnection machine) async {
    final start = _folder.text.trim();
    final picked = await pickRemoteDirectory(
      context,
      machine,
      startDir: start.startsWith('/') ? start : null,
    );
    if (picked != null && mounted) _folder.text = picked;
  }

  Future<void> _start({required bool open}) async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final nav = Navigator.of(context);
    final toaster = Toaster.of(context);
    setState(() => _opening = open);
    final session = await _vm.start(_folder.text);
    if (session == null) return;
    if (open) {
      if (!mounted) return;
      unawaited(openAgent(nav.context, SessionAgent(session.key), replace: true));
    } else {
      if (mounted) nav.pop();
      showStartedToast(
        toaster,
        message: '${session.agentLabel} started in ${cwdTail(session.cwd)} · ${session.machine.profile.label}',
        onOpen: () => unawaited(openAgent(nav.context, SessionAgent(session.key))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.watch<NewAgentSessionViewModel>();
    final back = CircleButton(
      icon: LucideIcons.chevronLeft,
      tooltip: 'Back',
      onPressed: () => Navigator.of(context).maybePop(),
    );

    if (vm.machines.isEmpty) {
      return Scaffold(
        backgroundColor: ds.bg,
        body: CustomScrollView(
          slivers: [
            SliverLargeTitle(title: 'New agent session', leading: back),
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                child: EmptyState(
                  icon: LucideIcons.serverOff,
                  title: 'No machine is online',
                  message: 'An agent session starts on a connected machine. Check the Machines '
                      'tab, then come back.',
                  action: AppButton(
                    label: 'Back',
                    kind: AppButtonKind.secondary,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final machine = vm.machine;
    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        children: [
          Expanded(
            child: Form(
              key: _formKey,
              onChanged: vm.dismissError,
              child: CustomScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverLargeTitle(title: 'New agent session', leading: back),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FormSection(
                          label: 'Where',
                          children: [
                            MachineField(
                              machine: vm.machine,
                              choices: vm.machines,
                              lost: vm.machineLost,
                              onSelect: vm.selectMachine,
                            ),
                            LabeledField(
                              label: 'Folder',
                              controller: _folder,
                              mono: true,
                              hint: '/home/you/code/my-project',
                              helper: 'An absolute path on the machine',
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.done,
                              validator: agentFolderError,
                              suffix: machine == null || !machineSupportsFiles(machine)
                                  ? null
                                  : Align(
                                      widthFactor: 1,
                                      heightFactor: 1,
                                      child: CircleButton(
                                        icon: LucideIcons.folderOpen,
                                        tooltip: 'Browse folders',
                                        filled: false,
                                        size: 36,
                                        onPressed: () => _browse(machine),
                                      ),
                                    ),
                            ),
                            ListenableBuilder(
                              listenable: _folder,
                              builder: (context, _) => RecentFolders(
                                paths: vm.recent,
                                selected: _folder.text.trim(),
                                onPick: (path) => _folder.text = path,
                              ),
                            ),
                          ],
                        ),
                        FormSection(
                          label: 'Agent',
                          endsWithField: false,
                          children: [_AgentChips(vm: vm)],
                        ),
                        ListRow(
                          title: 'Past sessions',
                          subtitle: 'Continue a conversation an agent kept',
                          leading: Icon(LucideIcons.history, size: 20, color: ds.textSecondary),
                          trailing: Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
                          divider: false,
                          onTap: () {
                            Haptics.tick();
                            unawaited(openPastSessions(context, machine: machine, cwd: _folder.text));
                          },
                        ),
                        const SizedBox(height: Gap.xl),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _StartBar(vm: vm, opening: _opening, onStart: vm.canStart ? _start : null),
        ],
      ),
    );
  }
}

/// The agents that have an ACP route. One the machine cannot run is dimmed and
/// cannot be chosen; the line under the chips says why.
class _AgentChips extends StatelessWidget {
  const _AgentChips({required this.vm});

  final NewAgentSessionViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final reasons = [
      for (final r in agentRoutes) ?vm.unavailableReason(r),
    ];
    final failure = vm.probeFailure;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Gap.sm,
          children: [
            for (final r in agentRoutes) _chip(r),
          ],
        ),
        if (vm.checking)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Checking what is installed…', style: Type.caption.copyWith(color: ds.textMuted)),
          ),
        for (final reason in reasons)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              reason,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: ds.textSecondary),
            ),
          ),
        if (failure != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              failure,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Type.caption.copyWith(color: ds.dangerText),
            ),
          ),
      ],
    );
  }

  Widget _chip(AgentRoute r) {
    final available = vm.isAvailable(r.id) != false;
    final chip = AppChip(
      label: r.label,
      selected: vm.agent == r.id,
      onTap: available ? () => vm.selectAgent(r.id) : null,
    );
    return available ? chip : Opacity(opacity: 0.45, child: chip);
  }
}

/// The error (if any) and the Start buttons, pinned under the form.
class _StartBar extends StatelessWidget {
  const _StartBar({required this.vm, required this.opening, required this.onStart});

  final NewAgentSessionViewModel vm;

  /// The start in flight (if any) was Start and open.
  final bool opening;
  final void Function({required bool open})? onStart;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final error = vm.error;
    final start = onStart;
    final busy = vm.busy;
    return FormActionBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
            curve: Motion.easeOut,
            alignment: Alignment.topCenter,
            child: error == null
                ? const SizedBox(width: double.infinity)
                : ConstrainedBox(
                    // A long message must not push the button off screen.
                    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: Gap.md),
                        child: StatusPanel(
                          color: ds.danger,
                          icon: LucideIcons.circleAlert,
                          title: error.title,
                          message: error.message,
                        ),
                      ),
                    ),
                  ),
          ),
          AppButton(
            label: busy && !opening ? 'Starting…' : 'Start',
            expand: true,
            loading: busy && !opening,
            onPressed: start == null || busy ? null : () => start(open: false),
          ),
          const SizedBox(height: Gap.sm),
          AppButton(
            label: busy && opening ? 'Starting…' : 'Start and open',
            kind: AppButtonKind.secondary,
            expand: true,
            loading: busy && opening,
            onPressed: start == null || busy ? null : () => start(open: true),
          ),
        ],
      ),
    );
  }
}
