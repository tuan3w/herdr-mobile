import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/new_session_settings.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/form_sections.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/tokens.dart';
import '../files/files_navigation.dart';
import '../pane/pane_navigation.dart';
import 'new_session_view_model.dart';

/// Opens the new-session form, on [machine] when given.
Future<void> openNewSession(BuildContext context, {MachineConnection? machine}) =>
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => NewSessionScreen(machineId: machine?.profile.id),
    ));

/// Starts a workspace on one of the online machines, optionally running an
/// agent in it, and opens its terminal.
class NewSessionScreen extends StatelessWidget {
  const NewSessionScreen({super.key, this.machineId});

  /// Preselected machine; the one used last otherwise.
  final String? machineId;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => NewSessionViewModel(
          fleet: ctx.read<FleetRepository>(),
          settings: ctx.read<NewSessionSettings>(),
          machineId: machineId,
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
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _prompt = TextEditingController();
  late final NewSessionViewModel _vm = context.read<NewSessionViewModel>();

  /// The machine and kind the command field was last filled for.
  (String?, String?) _commandFor = (null, null);

  @override
  void initState() {
    super.initState();
    _vm.addListener(_syncCommand);
    _syncCommand();
  }

  @override
  void dispose() {
    _vm.removeListener(_syncCommand);
    for (final c in [_folder, _name, _command, _prompt]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Another machine or agent brings its own remembered command. Typing in the
  /// field never comes through here, so it is never overwritten mid-edit.
  void _syncCommand() {
    final key = (_vm.machine?.profile.id, _vm.kind);
    if (key == _commandFor) return;
    _commandFor = key;
    final kind = _vm.kind;
    _command.text = kind == null ? '' : _vm.commandFor(kind);
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

  Future<void> _start() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final kind = _vm.kind;
    final prompt = _prompt.text.trim();
    final launch = await _vm.start(NewSessionValues(
      folder: _folder.text,
      name: _name.text,
      command: _command.text,
      prompt: _prompt.text,
    ));
    if (launch == null || !mounted) return;
    unawaited(openPaneTab(nav.context, launch.machine, launch.paneId, replace: true));
    if (launch.notice case final notice?) {
      messenger.showSnackBar(SnackBar(content: Text(notice)));
    }
    // The pane is already open; the first message follows once the agent is up.
    final delivery = launch.prompt;
    if (delivery != null && kind != null) {
      unawaited(delivery.then((outcome) {
        final text = promptNotice(outcome, kind);
        if (text == null) return;
        messenger.showSnackBar(SnackBar(
          content: Text(text),
          duration: const Duration(seconds: 8),
          action: SnackBarAction(
            label: 'Copy',
            onPressed: () => Clipboard.setData(ClipboardData(text: prompt)),
          ),
        ));
      }));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final vm = context.watch<NewSessionViewModel>();
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
            SliverLargeTitle(title: 'New session', leading: back),
            SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                child: EmptyState(
                  icon: LucideIcons.serverOff,
                  title: 'No machine is online',
                  message: 'A session starts on a connected machine. Check the Machines '
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
                  SliverLargeTitle(title: 'New session', leading: back),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        FormSection(
                          label: 'Where',
                          children: [
                            _MachineField(vm: vm),
                            LabeledField(
                              label: 'Folder',
                              controller: _folder,
                              mono: true,
                              hint: '~/code/my-project',
                              helper: 'An absolute path, or ~ for home',
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              validator: folderError,
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
                              builder: (context, _) => _RecentFolders(
                                paths: vm.recent,
                                selected: _folder.text.trim(),
                                onPick: (path) => _folder.text = path,
                              ),
                            ),
                            ListenableBuilder(
                              listenable: _folder,
                              builder: (context, _) => LabeledField(
                                label: 'Workspace name',
                                controller: _name,
                                hint: _folder.text.trim().isEmpty
                                    ? 'The folder name'
                                    : defaultWorkspaceName(_folder.text),
                                textInputAction: TextInputAction.next,
                              ),
                            ),
                          ],
                        ),
                        FormSection(
                          label: 'Start with',
                          endsWithField: false,
                          children: [
                            _KindChips(
                              kinds: vm.kinds,
                              kind: vm.kind,
                              onSelect: vm.selectKind,
                            ),
                            Collapse(
                              open: vm.kind != null,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  LabeledField(
                                    label: 'Command',
                                    controller: _command,
                                    mono: true,
                                    textInputAction: TextInputAction.next,
                                    validator: (v) => vm.kind == null ? null : commandError(v),
                                    helper: machine == null
                                        ? null
                                        : 'Typed into the new terminal. Remembered for ${machine.profile.label}.',
                                  ),
                                  const SizedBox(height: Gap.sm),
                                  LabeledField(
                                    label: 'First message (optional)',
                                    controller: _prompt,
                                    minLines: 3,
                                    maxLines: 6,
                                    keyboardType: TextInputType.multiline,
                                    helper: 'Sent once ${vm.kind ?? 'the agent'} is running.',
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Gap.xl),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _StartBar(vm: vm, onStart: machine == null ? null : _start),
        ],
      ),
    );
  }
}

/// The machine, as a field that opens a sheet of the online ones. With one
/// machine it only says where.
class _MachineField extends StatelessWidget {
  const _MachineField({required this.vm});

  final NewSessionViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final machine = vm.machine;
    final choices = vm.machines;
    final canChoose = choices.length > 1;
    final lost = vm.machineLost;

    void choose() => showActionSheet(
          context,
          title: 'Machine',
          actions: [
            for (final c in choices)
              SheetAction(
                label: c.profile.label,
                icon: c.profile.id == machine?.profile.id ? LucideIcons.check : LucideIcons.server,
                onTap: () => vm.selectMachine(c.profile.id),
              ),
          ],
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ExcludeSemantics(
            child: Text('Machine', style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        PressBuilder(
          onTap: canChoose ? choose : null,
          semanticLabel: 'Machine, ${machine?.profile.label ?? 'none chosen'}',
          button: canChoose,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: 46),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: pressed ? ds.fill : ds.surface,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: lost ? ds.danger : ds.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    machine?.profile.label ?? 'Choose a machine',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.body.copyWith(
                      fontSize: 16,
                      color: machine == null ? ds.textMuted : ds.text,
                    ),
                  ),
                ),
                if (canChoose) ...[
                  const SizedBox(width: Gap.sm),
                  Icon(LucideIcons.chevronsUpDown, size: 16, color: ds.textTertiary),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text(
            lost
                ? 'That machine went offline. Pick another.'
                : machine == null
                    ? ' '
                    : '${machine.profile.username}@${machine.profile.host}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Type.caption.copyWith(color: lost ? ds.dangerText : ds.textMuted),
          ),
        ),
      ],
    );
  }
}

/// Folders already open on the machine, one tap to reuse.
class _RecentFolders extends StatelessWidget {
  const _RecentFolders({required this.paths, required this.selected, required this.onPick});

  final List<String> paths;
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text(
            'Open on this machine',
            style: Type.label.copyWith(color: context.ds.textSecondary),
          ),
        ),
        Wrap(
          spacing: Gap.sm,
          children: [
            for (final path in paths)
              AppChip(
                label: shortPath(path),
                selected: path == selected,
                onTap: () => onPick(path),
              ),
          ],
        ),
      ],
    );
  }
}

/// `…/workspace/herdr-mobile`: the last two segments, cut from the front when
/// still long, so a chip is never wider than the screen.
String shortPath(String path, {int max = 26}) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  final tail = parts.length <= 2 ? parts.join('/') : '…/${parts.sublist(parts.length - 2).join('/')}';
  if (tail.length <= max) return tail;
  return '…${tail.substring(tail.length - (max - 1))}';
}

class _KindChips extends StatelessWidget {
  const _KindChips({required this.kinds, required this.kind, required this.onSelect});

  final List<String> kinds;
  final String? kind;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Wrap(
      spacing: Gap.sm,
      children: [
        AppChip(
          label: 'Shell',
          leading: Icon(LucideIcons.squareTerminal, size: 14, color: ds.textSecondary),
          selected: kind == null,
          onTap: () => onSelect(null),
        ),
        for (final k in kinds)
          AppChip(label: k, selected: kind == k, onTap: () => onSelect(k)),
      ],
    );
  }
}

/// The error (if any) and the Start button, pinned under the form.
class _StartBar extends StatelessWidget {
  const _StartBar({required this.vm, required this.onStart});

  final NewSessionViewModel vm;
  final VoidCallback? onStart;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final error = vm.error;
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
            label: vm.busy ? 'Starting…' : 'Start',
            expand: true,
            loading: vm.busy,
            onPressed: onStart,
          ),
        ],
      ),
    );
  }
}
