import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../core/approval_button.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'machine_form_view_model.dart';

final _sessionName = RegExp(r'^[A-Za-z0-9._-]+$');

class MachineFormScreen extends StatelessWidget {
  const MachineFormScreen({super.key, this.existing});

  final MachineProfile? existing;

  @override
  Widget build(BuildContext context) => ChangeNotifierProvider(
        create: (ctx) => MachineFormViewModel(
          repo: ctx.read<MachineRepository>(),
          existing: existing,
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
  late final _port =
      TextEditingController(text: '${widget.existing?.port ?? 22}');
  late final _user = TextEditingController(text: widget.existing?.username);
  late final _key = TextEditingController();
  late final _passphrase = TextEditingController();
  late final _password = TextEditingController();
  late final _session =
      TextEditingController(text: widget.existing?.session ?? 'default');
  late final _socket = TextEditingController(text: widget.existing?.socketPath);
  late SshAuth _auth = widget.existing?.auth ?? SshAuth.key;
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

  Future<void> _test() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    await context.read<MachineFormViewModel>().test(_values());
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final vm = context.read<MachineFormViewModel>();
    final nav = Navigator.of(context);
    await vm.save(_values());
    if (mounted) nav.pop();
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<MachineFormViewModel>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Edit machine' : 'Add machine')),
      body: Form(
        key: _formKey,
        onChanged: vm.invalidateTest,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              Gap.lg, Gap.sm, Gap.lg, Gap.xxl + MediaQuery.paddingOf(context).bottom),
          children: [
            Text(
              'herdr is reached over SSH. Nothing is exposed publicly and no '
              'relay is involved.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
            ),
            const _Label('Machine'),
            TextFormField(
              controller: _label,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'Build server',
              ),
            ),
            const SizedBox(height: Gap.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextFormField(
                    controller: _host,
                    validator: _required,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Host',
                      hintText: 'workbox.local or 100.64.0.5',
                    ),
                  ),
                ),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: TextFormField(
                    controller: _port,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    validator: (v) {
                      final p = int.tryParse(v?.trim() ?? '');
                      return (p == null || p < 1 || p > 65535) ? 'Invalid' : null;
                    },
                    decoration: const InputDecoration(labelText: 'Port'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.md),
            TextFormField(
              controller: _user,
              validator: _required,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            const _Label('Authentication'),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<SshAuth>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: SshAuth.key,
                    icon: Icon(Icons.key_rounded),
                    label: Text('Private key'),
                  ),
                  ButtonSegment(
                    value: SshAuth.password,
                    icon: Icon(Icons.password_rounded),
                    label: Text('Password'),
                  ),
                  ButtonSegment(
                    value: SshAuth.none,
                    icon: Icon(Icons.vpn_lock_rounded),
                    label: Text('Tailscale'),
                  ),
                ],
                selected: {_auth},
                onSelectionChanged: (s) {
                  setState(() => _auth = s.first);
                  vm.invalidateTest();
                },
              ),
            ),
            const SizedBox(height: Gap.md),
            if (_auth == SshAuth.none) ...[
              Text(
                'Nothing is stored. Tailscale already knows this phone, so no key '
                'or password is needed. If your tailnet asks for an extra check, '
                'the app shows a link to approve the sign-in.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (_auth == SshAuth.key) ...[
              TextFormField(
                controller: _key,
                minLines: 4,
                maxLines: 6,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: monoFamily, fontSize: 12),
                validator: (v) => !_editing && (v == null || v.trim().isEmpty)
                    ? 'Paste your private key'
                    : null,
                decoration: InputDecoration(
                  labelText: 'Private key (PEM / OpenSSH)',
                  hintText: _editing
                      ? 'Leave blank to keep the saved key'
                      : '-----BEGIN OPENSSH PRIVATE KEY-----',
                  alignLabelWithHint: true,
                  suffixIcon: Padding(
                    padding: const EdgeInsets.only(top: Gap.xs),
                    child: Align(
                      widthFactor: 1,
                      heightFactor: 1,
                      alignment: Alignment.topCenter,
                      child: IconButton(
                        tooltip: 'Paste from clipboard',
                        onPressed: _paste,
                        icon: const Icon(Icons.content_paste_rounded),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                controller: _passphrase,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: 'Key passphrase (if any)',
                  suffixIcon: _VisibilityToggle(
                    obscured: _obscure,
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ] else if (_auth == SshAuth.password)
              TextFormField(
                controller: _password,
                obscureText: _obscure,
                autocorrect: false,
                enableSuggestions: false,
                validator: (v) => !_editing && (v == null || v.isEmpty)
                    ? 'Required'
                    : null,
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: _editing ? 'Leave blank to keep the saved password' : null,
                  suffixIcon: _VisibilityToggle(
                    obscured: _obscure,
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            const SizedBox(height: Gap.md),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                expansionAnimationStyle: Motion.expansion,
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: Gap.md),
                initiallyExpanded: _session.text != 'default' || _socket.text.isNotEmpty,
                title: Text('Advanced', style: theme.textTheme.titleSmall),
                children: [
                  TextFormField(
                    controller: _session,
                    autocorrect: false,
                    enableSuggestions: false,
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      return t.isNotEmpty && !_sessionName.hasMatch(t)
                          ? 'Letters, digits, . _ - only'
                          : null;
                    },
                    decoration: const InputDecoration(
                      labelText: 'herdr session',
                      helperText: 'Named sessions need herdr 0.9+ on the machine',
                    ),
                  ),
                  const SizedBox(height: Gap.md),
                  TextFormField(
                    controller: _socket,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'API socket path (optional)',
                      hintText: '~/.config/herdr/herdr.sock',
                      helperText: 'Only used when herdr lacks remote-api-bridge',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Gap.sm),
            _TestResult(vm: vm),
            const SizedBox(height: Gap.lg),
            OutlinedButton.icon(
              onPressed: vm.testState == TestState.testing ? null : _test,
              icon: vm.testState == TestState.testing
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt_rounded),
              label: Text(vm.testState == TestState.testing
                  ? 'Connecting…'
                  : 'Test connection'),
            ),
            const SizedBox(height: Gap.md),
            FilledButton(
              onPressed: vm.saving ? null : _save,
              child: Text(_editing ? 'Save changes' : 'Add machine'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: Gap.xl, bottom: Gap.md),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
        ),
      );
}

class _VisibilityToggle extends StatelessWidget {
  const _VisibilityToggle({required this.obscured, required this.onPressed});

  final bool obscured;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onPressed,
        icon: Icon(obscured
            ? Icons.visibility_rounded
            : Icons.visibility_off_rounded),
      );
}

class _TestResult extends StatelessWidget {
  const _TestResult({required this.vm});

  final MachineFormViewModel vm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final approval = vm.testState == TestState.testing ? vm.approvalUrl : null;
    final (Color color, IconData icon, String title, String? detail)? view =
        approval != null
            ? (
                const Color(0xFFF59E0B),
                Icons.verified_user_rounded,
                'Approve this sign-in',
                'Tailscale needs you to confirm this connection in a browser. '
                    'Open the page, approve it, then come back: the test continues by itself.',
              )
            : switch (vm.testState) {
                TestState.ok => (
                    const Color(0xFF22C55E),
                    Icons.check_circle_rounded,
                    'Connected · herdr ${vm.version}',
                    '${vm.workspaceCount} workspace${vm.workspaceCount == 1 ? '' : 's'}'
                        '${vm.fingerprint == null ? '' : '\nHost key ${vm.fingerprint}'}',
                  ),
                TestState.failed => (
                    const Color(0xFFEF4444),
                    Icons.error_rounded,
                    'Could not connect',
                    vm.message,
                  ),
                _ => null,
              };
    return AnimatedSize(
      duration: Motion.expand,
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: view == null
          ? const SizedBox(width: double.infinity)
          : Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Gap.md),
              decoration: BoxDecoration(
                color: view.$1.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(Radii.field),
                border: Border.all(color: view.$1.withValues(alpha: 0.35)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(view.$2, color: view.$1),
                  const SizedBox(width: Gap.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(view.$3, style: theme.textTheme.titleSmall),
                        if (view.$4 != null)
                          Padding(
                            padding: const EdgeInsets.only(top: Gap.xs),
                            child: Text(
                              view.$4!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontFamily: vm.testState == TestState.ok
                                    ? monoFamily
                                    : null,
                              ),
                            ),
                          ),
                        if (approval != null)
                          Padding(
                            padding: const EdgeInsets.only(top: Gap.md),
                            child: ApprovalButton(url: approval),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
