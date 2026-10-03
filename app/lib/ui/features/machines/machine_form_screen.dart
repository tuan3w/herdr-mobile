import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../../data/services/transport_factory.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';
import 'machine_form_view_model.dart';
import 'status_panel.dart';

final _sessionName = RegExp(r'^[A-Za-z0-9._-]+$');

String? _sessionError(String? v) {
  final t = v?.trim() ?? '';
  return t.isNotEmpty && !_sessionName.hasMatch(t) ? 'Letters, digits, . _ - only' : null;
}

class MachineFormScreen extends StatelessWidget {
  const MachineFormScreen({super.key, this.existing, @visibleForTesting this.transportFactory});

  final MachineProfile? existing;

  /// Replaces the SSH transport used by "Test connection" (widget tests only).
  final TransportFactory? transportFactory;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => MachineFormViewModel(
          repo: ctx.read<MachineRepository>(),
          existing: existing,
          transportFactory: transportFactory ?? createSshTransport,
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

class _FormState extends State<_Form> {
  final _formKey = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.existing?.label);
  late final _host = TextEditingController(text: widget.existing?.host);
  late final _port = TextEditingController(text: '${widget.existing?.port ?? 22}');
  late final _user = TextEditingController(text: widget.existing?.username);
  late final _key = TextEditingController();
  late final _passphrase = TextEditingController();
  late final _password = TextEditingController();
  late final _session = TextEditingController(text: widget.existing?.session ?? 'default');
  late final _socket = TextEditingController(text: widget.existing?.socketPath);
  late SshAuth _auth = widget.existing?.auth ?? SshAuth.key;
  late bool _advanced = _session.text != 'default' || _socket.text.isNotEmpty;
  bool _obscure = true;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    for (final c in [_label, _host, _port, _user, _key, _passphrase, _password, _session, _socket]) {
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
      setState(() => _advanced = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _formKey.currentState?.validate());
    }
    final ok = _formKey.currentState!.validate();
    return ok && !hiddenProblem;
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
    final testing = vm.testState == TestState.testing;
    const gutter = EdgeInsets.symmetric(horizontal: Gap.gutter);
    // Fields sit a little below their section label.
    const section = EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, 0);

    return Scaffold(
      backgroundColor: ds.bg,
      body: Form(
        key: _formKey,
        onChanged: vm.invalidateTest,
        child: CustomScrollView(
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
                  const SectionLabel(label: 'Machine'),
                  Padding(
                    padding: section,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        LabeledField(
                          label: 'Name',
                          controller: _label,
                          hint: 'Build server',
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: Gap.lg),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              flex: 3,
                              child: LabeledField(
                                label: 'Host',
                                controller: _host,
                                hint: 'workbox.local or 100.64.0.5',
                                validator: _required,
                                keyboardType: TextInputType.url,
                                textInputAction: TextInputAction.next,
                              ),
                            ),
                            const SizedBox(width: Gap.md),
                            Expanded(
                              child: LabeledField(
                                label: 'Port',
                                controller: _port,
                                keyboardType: TextInputType.number,
                                textInputAction: TextInputAction.next,
                                validator: (v) {
                                  final p = int.tryParse(v?.trim() ?? '');
                                  return (p == null || p < 1 || p > 65535) ? 'Invalid' : null;
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: Gap.lg),
                        LabeledField(
                          label: 'Username',
                          controller: _user,
                          validator: _required,
                          textInputAction: TextInputAction.next,
                        ),
                      ],
                    ),
                  ),
                  const SectionLabel(label: 'Authentication'),
                  Padding(
                    padding: section,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _AuthPicker(
                          value: _auth,
                          onChanged: (a) {
                            setState(() => _auth = a);
                            vm.invalidateTest();
                          },
                        ),
                        const SizedBox(height: Gap.lg),
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
                          const SizedBox(height: Gap.lg),
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
                            validator: (v) =>
                                !_editing && (v == null || v.isEmpty) ? 'Required' : null,
                            suffix: _toggle(),
                          ),
                      ],
                    ),
                  ),
                  SectionLabel(
                    label: 'Advanced',
                    expanded: _advanced,
                    onTap: () => setState(() => _advanced = !_advanced),
                  ),
                  Collapse(
                    open: _advanced,
                    child: Padding(
                      padding: section,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LabeledField(
                            label: 'herdr session',
                            controller: _session,
                            helper: 'Named sessions need herdr 0.9+ on the machine',
                            validator: _sessionError,
                          ),
                          const SizedBox(height: Gap.lg),
                          LabeledField(
                            label: 'API socket path (optional)',
                            controller: _socket,
                            hint: '~/.config/herdr/herdr.sock',
                            helper: 'Only used when herdr lacks remote-api-bridge',
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xl, Gap.gutter, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _TestResult(vm: vm),
                        AppButton(
                          label: testing ? 'Connecting…' : 'Test connection',
                          icon: LucideIcons.zap,
                          kind: AppButtonKind.secondary,
                          expand: true,
                          loading: testing,
                          onPressed: _test,
                        ),
                        const SizedBox(height: Gap.md),
                        AppButton(
                          label: _editing ? 'Save' : 'Add machine',
                          expand: true,
                          loading: vm.saving,
                          onPressed: _save,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: Gap.xxl + MediaQuery.paddingOf(context).bottom),
                ],
              ),
            ),
          ],
        ),
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
          : Padding(
              padding: const EdgeInsets.only(bottom: Gap.lg),
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
    );
  }
}
