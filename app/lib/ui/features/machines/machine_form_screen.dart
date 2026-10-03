import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/form_sections.dart';
import '../../core/status_panel.dart';
import '../../core/tokens.dart';
import 'machine_form_view_model.dart';

final _sessionName = RegExp(r'^[A-Za-z0-9._-]+$');

String? _sessionError(String? v) {
  final t = v?.trim() ?? '';
  return t.isNotEmpty && !_sessionName.hasMatch(t) ? 'Letters, digits, . _ - only' : null;
}

/// Opens the add form, or the edit form for [existing].
///
/// Pushed restorably: if Android reclaims the process while the person is off
/// copying a key from another app, the form comes back with its plain fields.
/// The route argument is the machine's id, never a secret.
void openMachineForm(BuildContext context, {MachineProfile? existing}) =>
    Navigator.of(context).restorablePush(_formRoute, arguments: existing?.id);

@pragma('vm:entry-point')
Route<void> _formRoute(BuildContext context, Object? machineId) {
  final machines = context.read<MachineRepository>().machines;
  final existing = machineId is String ? machines.where((m) => m.id == machineId).firstOrNull : null;
  return MaterialPageRoute<void>(builder: (_) => MachineFormScreen(existing: existing));
}

class MachineFormScreen extends StatelessWidget {
  const MachineFormScreen({super.key, this.existing, @visibleForTesting this.transportFactory});

  final MachineProfile? existing;

  /// Replaces the [TransportFactory] the app provides for "Test connection"
  /// (widget tests only).
  final TransportFactory? transportFactory;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => MachineFormViewModel(
          repo: ctx.read<MachineRepository>(),
          existing: existing,
          transportFactory: transportFactory ?? ctx.read<TransportFactory>(),
        ),
        child: _Form(existing: existing),
      );
}

class _Form extends StatefulWidget {
  const _Form({this.existing});

  final MachineProfile? existing;

  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> with RestorationMixin {
  final _formKey = GlobalKey<FormState>();
  final _sessionKey = GlobalKey();

  // Plain fields survive process death. The key, passphrase and password are
  // deliberately not restorable: restoration state is written to disk.
  late final _labelR = RestorableTextEditingController(text: widget.existing?.label);
  late final _hostR = RestorableTextEditingController(text: widget.existing?.host);
  late final _portR = RestorableTextEditingController(text: '${widget.existing?.port ?? 22}');
  late final _userR = RestorableTextEditingController(text: widget.existing?.username);
  late final _sessionR = RestorableTextEditingController(text: widget.existing?.session ?? 'default');
  late final _socketR = RestorableTextEditingController(text: widget.existing?.socketPath);
  late final _authR = RestorableInt((widget.existing?.auth ?? SshAuth.key).index);
  late final _advancedR = RestorableBool(
    (widget.existing?.session ?? 'default') != 'default' || (widget.existing?.socketPath ?? '').isNotEmpty,
  );

  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;

  TextEditingController get _label => _labelR.value;
  TextEditingController get _host => _hostR.value;
  TextEditingController get _port => _portR.value;
  TextEditingController get _user => _userR.value;
  TextEditingController get _session => _sessionR.value;
  TextEditingController get _socket => _socketR.value;
  SshAuth get _auth => SshAuth.values[_authR.value];
  bool get _advanced => _advancedR.value;

  bool get _editing => widget.existing != null;

  @override
  String? get restorationId => 'machine_form';

  @override
  void restoreState(RestorationBucket? oldBucket, bool initialRestore) {
    registerForRestoration(_labelR, 'label');
    registerForRestoration(_hostR, 'host');
    registerForRestoration(_portR, 'port');
    registerForRestoration(_userR, 'user');
    registerForRestoration(_sessionR, 'session');
    registerForRestoration(_socketR, 'socket');
    registerForRestoration(_authR, 'auth');
    registerForRestoration(_advancedR, 'advanced');
  }

  @override
  void dispose() {
    for (final r in [_labelR, _hostR, _portR, _userR, _sessionR, _socketR]) {
      r.dispose();
    }
    _authR.dispose();
    _advancedR.dispose();
    for (final c in [_key, _passphrase, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  MachineFormValues _values() => MachineFormValues(
        label: _label.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _user.text.trim(),
        auth: _auth,
        privateKey: _key.text.trim(),
        passphrase: _passphrase.text,
        password: _password.text,
        session: _session.text.trim(),
        socketPath: _socket.text.trim(),
      );

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (data?.text case final text? when text.trim().isNotEmpty) {
      _key.text = text.trim();
      context.read<MachineFormViewModel>().invalidateTest();
    }
  }

  /// Validates every field. Fields inside a collapsed "Advanced" are not built,
  /// so a bad session name there would slip through: open the section and
  /// validate again once its fields exist.
  bool _validate() {
    final hiddenProblem = !_advanced && _sessionError(_session.text) != null;
    if (hiddenProblem) {
      setState(() => _advancedR.value = true);
      _validateOnceMounted();
    }
    final ok = _formKey.currentState!.validate();
    return ok && !hiddenProblem;
  }

  /// [Collapse] mounts its child a frame or more after it starts opening, so
  /// wait for the session field to exist before asking the form to validate.
  void _validateOnceMounted([int frames = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_sessionKey.currentContext != null) {
        _formKey.currentState?.validate();
      } else if (frames < 60) {
        _validateOnceMounted(frames + 1);
      }
    });
  }

  Future<void> _test() async {
    if (!_validate()) return;
    FocusScope.of(context).unfocus();
    await context.read<MachineFormViewModel>().test(_values());
  }

  Future<void> _save() async {
    if (!_validate()) return;
    final vm = context.read<MachineFormViewModel>();
    final nav = Navigator.of(context);
    await vm.save(_values());
    if (mounted) nav.pop();
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  /// Host and port side by side; one under the other with large system text,
  /// where a quarter-width port field would clip its own number.
  List<Widget> _hostAndPort(BuildContext context) {
    final host = LabeledField(
      label: 'Host',
      controller: _host,
      hint: 'workbox.local or 100.64.0.5',
      validator: _required,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.next,
    );
    final port = LabeledField(
      label: 'Port',
      controller: _port,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      validator: (v) {
        final p = int.tryParse(v?.trim() ?? '');
        return (p == null || p < 1 || p > 65535) ? 'Invalid' : null;
      },
    );
    if (MediaQuery.textScalerOf(context).scale(16) > 21) return [host, port];
    return [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: host),
          const SizedBox(width: Gap.md),
          Expanded(child: port),
        ],
      ),
    ];
  }

  Widget _toggle() => CircleButton(
        icon: _obscure ? LucideIcons.eye : LucideIcons.eyeOff,
        tooltip: _obscure ? 'Show' : 'Hide',
        filled: false,
        size: 36,
        onPressed: () => setState(() => _obscure = !_obscure),
      );

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MachineFormViewModel>();
    final ds = context.ds;
    const gutter = EdgeInsets.symmetric(horizontal: Gap.gutter);

    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        children: [
          Expanded(
            child: Form(
              key: _formKey,
              onChanged: vm.invalidateTest,
              child: CustomScrollView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverLargeTitle(
                    title: _editing ? 'Edit machine' : 'Add machine',
                    leading: CircleButton(
                      icon: LucideIcons.chevronLeft,
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: gutter,
                          child: Text(
                            'herdr is reached over SSH. Nothing is exposed publicly and no '
                            'relay is involved.',
                            style: Type.body.copyWith(color: ds.textSecondary, fontSize: 14.5),
                          ),
                        ),
                        FormSection(
                          label: 'Machine',
                          children: [
                            LabeledField(
                              label: 'Name',
                              controller: _label,
                              hint: 'Build server',
                              textInputAction: TextInputAction.next,
                            ),
                            ..._hostAndPort(context),
                            LabeledField(
                              label: 'Username',
                              controller: _user,
                              validator: _required,
                              textInputAction: TextInputAction.next,
                            ),
                          ],
                        ),
                        FormSection(
                          label: 'Authentication',
                          endsWithField: _auth != SshAuth.none,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: Gap.sm),
                              child: _AuthPicker(
                                value: _auth,
                                onChanged: (a) {
                                  setState(() => _authR.value = a.index);
                                  vm.invalidateTest();
                                },
                              ),
                            ),
                            if (_auth == SshAuth.none)
                              Text(
                                'Nothing is stored. Tailscale already knows this phone, so no key '
                                'or password is needed. If your tailnet asks for an extra check, '
                                'the app shows a link to approve the sign-in.',
                                style: Type.secondary.copyWith(color: ds.textSecondary),
                              ),
                            if (_auth == SshAuth.key) ...[
                              LabeledField(
                                label: 'Private key (PEM / OpenSSH)',
                                controller: _key,
                                mono: true,
                                minLines: 4,
                                maxLines: 6,
                                hint: _editing
                                    ? 'Leave blank to keep the saved key'
                                    : '-----BEGIN OPENSSH PRIVATE KEY-----',
                                validator: (v) => !_editing && (v == null || v.trim().isEmpty)
                                    ? 'Paste your private key'
                                    : null,
                                suffix: Align(
                                  widthFactor: 1,
                                  heightFactor: 1,
                                  alignment: Alignment.topCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: Gap.xs),
                                    child: CircleButton(
                                      icon: LucideIcons.clipboardPaste,
                                      tooltip: 'Paste from clipboard',
                                      filled: false,
                                      size: 36,
                                      onPressed: _paste,
                                    ),
                                  ),
                                ),
                              ),
                              LabeledField(
                                label: 'Key passphrase (if any)',
                                controller: _passphrase,
                                obscure: _obscure,
                                suffix: _toggle(),
                              ),
                            ],
                            if (_auth == SshAuth.password)
                              LabeledField(
                                label: 'Password',
                                controller: _password,
                                obscure: _obscure,
                                hint: _editing ? 'Leave blank to keep the saved password' : null,
                                validator: (v) => !_editing && (v == null || v.isEmpty) ? 'Required' : null,
                                suffix: _toggle(),
                              ),
                          ],
                        ),
                        FormSectionHeader(
                          label: 'Advanced',
                          expanded: _advanced,
                          onTap: () => setState(() => _advancedR.value = !_advanced),
                        ),
                        Collapse(
                          open: _advanced,
                          child: FormPanel(
                            children: [
                              LabeledField(
                                key: _sessionKey,
                                label: 'herdr session',
                                controller: _session,
                                helper: 'Named sessions need herdr 0.9+ on the machine',
                                validator: _sessionError,
                              ),
                              LabeledField(
                                label: 'API socket path (optional)',
                                controller: _socket,
                                hint: '~/.config/herdr/herdr.sock',
                                helper: 'Only used when herdr lacks remote-api-bridge',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: Gap.xl),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _ActionBar(
            vm: vm,
            editing: _editing,
            onTest: _test,
            onSave: _save,
          ),
        ],
      ),
    );
  }
}

/// Test result and the two actions, pinned under the form so they are never a
/// scroll away. It sits above the keyboard (the Scaffold body shrinks), and the
/// form scrolls independently, so a focused field is never covered by it.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.vm,
    required this.editing,
    required this.onTest,
    required this.onSave,
  });

  final MachineFormViewModel vm;
  final bool editing;
  final VoidCallback onTest;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final testing = vm.testState == TestState.testing;
    // Side by side when both labels fit; stacked (primary first) on a narrow
    // phone or with large system text.
    final sideBySide = MediaQuery.sizeOf(context).width >= 360 &&
        MediaQuery.textScalerOf(context).scale(15) <= 17;

    final test = AppButton(
      label: testing ? 'Connecting…' : 'Test connection',
      icon: sideBySide ? null : LucideIcons.zap,
      kind: AppButtonKind.secondary,
      expand: true,
      loading: testing,
      onPressed: onTest,
    );
    final save = AppButton(
      label: editing ? 'Save' : 'Add machine',
      expand: true,
      loading: vm.saving,
      onPressed: onSave,
    );

    return FormActionBar(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TestResult(vm: vm),
          if (sideBySide)
            Row(children: [
              Expanded(child: test),
              const SizedBox(width: Gap.md),
              Expanded(child: save),
            ])
          else ...[
            save,
            // Stacked and typing: two full-width buttons would leave the
            // focused field almost no room. Test returns with the keyboard.
            if (MediaQuery.viewInsetsOf(context).bottom == 0) ...[
              const SizedBox(height: Gap.sm),
              test,
            ],
          ],
        ],
      ),
    );
  }
}

/// Private key / Password / Tailscale. Icons are dropped when the three labels
/// would not fit beside them (narrow phone or large system text).
class _AuthPicker extends StatelessWidget {
  const _AuthPicker({required this.value, required this.onChanged});

  final SshAuth value;
  final ValueChanged<SshAuth> onChanged;

  @override
  Widget build(BuildContext context) {
    final roomy = MediaQuery.sizeOf(context).width >= 360 &&
        MediaQuery.textScalerOf(context).scale(13.5) <= 15;
    return Segmented<SshAuth>(
      value: value,
      onChanged: onChanged,
      options: [
        SegmentOption(SshAuth.key, 'Private key', roomy ? LucideIcons.keyRound : null),
        SegmentOption(SshAuth.password, 'Password', roomy ? LucideIcons.lock : null),
        SegmentOption(SshAuth.none, 'Tailscale', roomy ? LucideIcons.globe : null),
      ],
    );
  }
}

class _TestResult extends StatelessWidget {
  const _TestResult({required this.vm});

  final MachineFormViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final approval = vm.testState == TestState.testing ? vm.approvalUrl : null;
    final (Color color, IconData icon, String title, String? detail)? view = approval != null
        ? (
            ds.blocked,
            LucideIcons.shieldCheck,
            'Approve this sign-in',
            'Tailscale needs you to confirm this connection in a browser. '
                'Open the page, approve it, then come back: the test continues by itself.',
          )
        : switch (vm.testState) {
            TestState.ok => (
                ds.done,
                LucideIcons.circleCheck,
                'Connected · herdr ${vm.version}',
                '${vm.workspaceCount} workspace${vm.workspaceCount == 1 ? '' : 's'}'
                    '${vm.fingerprint == null ? '' : '\nHost key ${vm.fingerprint}'}',
              ),
            TestState.failed => (ds.danger, LucideIcons.circleAlert, 'Could not connect', vm.message),
            _ => null,
          };
    return AnimatedSize(
      duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: view == null
          ? const SizedBox(width: double.infinity)
          : ConstrainedBox(
              // A long failure message must not push the buttons off screen.
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: StatusPanel(
                    color: view.$1,
                    icon: view.$2,
                    title: view.$3,
                    message: view.$4,
                    mono: vm.testState == TestState.ok && approval == null,
                    footer: approval == null
                        ? null
                        : Align(alignment: Alignment.centerLeft, child: ApprovalButton(url: approval)),
                  ),
                ),
              ),
            ),
    );
  }
}
