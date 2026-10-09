import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../../data/services/key_generator.dart';
import '../../core/approval_button.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/form_sections.dart';
import '../../core/draw_check.dart';
import '../../core/status_panel.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'machine_form_view_model.dart';

final _sessionName = RegExp(r'^[A-Za-z0-9._-]+$');

String? _sessionError(String? v) {
  final t = v?.trim() ?? '';
  return t.isNotEmpty && !_sessionName.hasMatch(t) ? 'Letters, digits, . _ - only' : null;
}

/// Opens the add form, or the edit form for [existing].
///
/// Pushed restorably: if Android reclaims the process while the person is off
/// copying a key from another app, the form comes back with its plain fields,
/// and a key generated here comes back from the keychain (see `_keyDraftR`).
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
  // Whether a generated key is held as a draft in secure storage. Only the
  // flag is restorable; the key itself never enters restoration state.
  late final _keyDraftR = RestorableBool(false);

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
  void initState() {
    super.initState();
    context.read<MachineFormViewModel>().loadSavedKey();
  }

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
    registerForRestoration(_keyDraftR, 'key_draft');
    if (initialRestore) {
      final vm = context.read<MachineFormViewModel>();
      if (_keyDraftR.value) {
        _restoreKeyDraft(vm);
      } else {
        vm.clearStaleKeyDraft();
      }
    }
  }

  /// Android reclaimed the process while the form held a generated key (the
  /// person was on the host installing its public half): put it back.
  Future<void> _restoreKeyDraft(MachineFormViewModel vm) async {
    final pem = await vm.restoreKeyDraft();
    if (!mounted) return;
    if (pem == null) {
      _keyDraftR.value = false;
    } else if (_key.text.trim().isNotEmpty) {
      // Typed over before the keychain answered: the typing wins.
      _keyDraftR.value = false;
      vm.dropPublicKey();
    } else {
      _key.text = pem;
      setState(() {});
    }
  }

  @override
  void dispose() {
    for (final r in [_labelR, _hostR, _portR, _userR, _sessionR, _socketR]) {
      r.dispose();
    }
    _authR.dispose();
    _advancedR.dispose();
    _keyDraftR.dispose();
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
      _keyEdited();
    }
  }

  /// The key field changed (typed, pasted or generated): a public key shown
  /// under it described the previous contents, and which buttons apply depends
  /// on whether the field is empty.
  void _keyEdited() {
    context.read<MachineFormViewModel>().dropPublicKey();
    _keyDraftR.value = false;
    setState(() {});
  }

  /// Makes a key on the phone and puts its private half in the field, to be
  /// saved like a pasted one. Replacing a key asks first: the old private key
  /// is gone for good if it was kept nowhere else.
  Future<void> _generate() async {
    final vm = context.read<MachineFormViewModel>();
    final typed = _key.text.trim().isNotEmpty;
    if (typed || vm.hasSavedKey) {
      final ok = await showConfirmSheet(
        context,
        title: 'Replace the current key?',
        message: typed
            ? 'The private key in this form is replaced. If you have not kept a copy '
                'elsewhere, it is gone for good.'
            : 'The key saved for this machine is replaced when you save. If you have not '
                'kept a copy elsewhere, it is gone for good.',
        confirmLabel: 'Generate new key',
      );
      if (!ok || !mounted) return;
    }
    final name = _label.text.trim().isEmpty ? _host.text.trim() : _label.text.trim();
    final key = vm.generateKey(label: name);
    _keyDraftR.value = true;
    // The new key has no passphrase; one left in the field would not fit it.
    _passphrase.clear();
    _key.text = key.privateKeyPem;
    vm.invalidateTest();
    setState(() {});
  }

  Future<void> _copy(String text, String done) async {
    final toaster = Toaster.of(context);
    await Clipboard.setData(ClipboardData(text: text));
    toaster.show(done);
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
    final vm = context.read<MachineFormViewModel>();
    await vm.test(_values());
    if (!mounted) return;
    switch (vm.testState) {
      case TestState.ok:
        Haptics.sent();
      case TestState.failed:
        Haptics.failed();
      default:
    }
  }

  /// A key typed, pasted or generated into the form replaces the one this
  /// machine logs in with. The old key stays in secure storage until Save, so
  /// a replaced key is the one change that can lock the phone out.
  bool get _replacesSavedKey =>
      _editing &&
      _auth == SshAuth.key &&
      _key.text.trim().isNotEmpty &&
      context.read<MachineFormViewModel>().hasSavedKey;

  Future<void> _save() async {
    if (!_validate()) return;
    final vm = context.read<MachineFormViewModel>();
    final nav = Navigator.of(context);
    if (_replacesSavedKey) {
      if (vm.testState == TestState.testing) return;
      if (!vm.testedFor(_values())) {
        FocusScope.of(context).unfocus();
        await vm.test(_values());
        if (!mounted) return;
        // An edit overtook the test: it says nothing about what is in the
        // fields now. Save again once they are as wanted.
        if (vm.testState == TestState.idle) return;
      }
      if (!vm.testedFor(_values())) {
        final choice = await _askAfterFailedTest(vm.message);
        if (!mounted) return;
        if (choice == null) return;
        if (!choice) {
          // The saved key was never touched: an empty field keeps it.
          _key.clear();
          vm.dropPublicKey();
          _keyDraftR.value = false;
          vm.invalidateTest();
          setState(() {});
          showToast(context, 'Kept the saved key');
          return;
        }
      }
    }
    // A failed save keeps the form and says why in the status panel.
    if (await vm.save(_values())) {
      if (mounted) nav.pop();
    } else if (mounted) {
      Haptics.failed();
    }
  }

  /// Anything entered that Save would store. Opening Advanced is not an edit.
  bool get _dirty {
    final e = widget.existing;
    return _label.text != (e?.label ?? '') ||
        _host.text != (e?.host ?? '') ||
        _port.text != '${e?.port ?? 22}' ||
        _user.text != (e?.username ?? '') ||
        _session.text != (e?.session ?? 'default') ||
        _socket.text != (e?.socketPath ?? '') ||
        _auth != (e?.auth ?? SshAuth.key) ||
        _key.text.trim().isNotEmpty ||
        _passphrase.text.isNotEmpty ||
        _password.text.isNotEmpty;
  }

  /// Back (the bar's, the system's, the predictive gesture) leaves at once
  /// while nothing is entered and asks first otherwise: a key generated here
  /// is kept nowhere else, and once its public half is on the host, losing it
  /// leaves a key on the machine that nothing can use.
  Widget _discardGuard(Widget form) => ListenableBuilder(
        listenable: Listenable.merge(
          [_label, _host, _port, _user, _session, _socket, _authR, _key, _passphrase, _password],
        ),
        builder: (context, child) => PopScope(
          canPop: !_dirty,
          onPopInvokedWithResult: (didPop, _) {
            // Leaving (after Discard or Save) ends the generated key's draft.
            if (didPop) {
              context.read<MachineFormViewModel>().dropKeyDraft();
            } else {
              _confirmDiscard();
            }
          },
          child: child!,
        ),
        child: form,
      );

  Future<void> _confirmDiscard() async {
    final nav = Navigator.of(context);
    final hasKey = _auth == SshAuth.key && _key.text.trim().isNotEmpty;
    final generated = context.read<MachineFormViewModel>().publicKeyGenerated;
    final discard = await showConfirmSheet(
      context,
      title: hasKey ? 'Discard the new key?' : 'Discard your changes?',
      message: switch ((hasKey, generated)) {
        (true, true) => 'This key was made on this phone and is saved nowhere else. If its '
            'public key is already on the machine, this phone cannot log in with it.',
        (true, false) => 'The key in this form and everything else entered here are not saved.',
        _ => 'What you entered here is not saved.',
      },
      confirmLabel: 'Discard',
    );
    if (discard && mounted) nav.pop();
  }

  /// The new key did not get in. True = save it anyway, false = keep the old
  /// key, null = close the sheet and carry on editing.
  Future<bool?> _askAfterFailedTest(String? why) => showAppSheet<bool>(
        context,
        builder: (ctx) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xl, Gap.gutter, Gap.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text('The new key could not connect', style: Type.title.copyWith(color: ctx.ds.text)),
              ),
              if (why != null && why.isNotEmpty) ...[
                const SizedBox(height: Gap.sm),
                Text(why, style: Type.secondary.copyWith(color: ctx.ds.textSecondary)),
              ],
              const SizedBox(height: Gap.sm),
              Text(
                'If its public key is not on the machine yet, saving now locks this phone out '
                'of it, and the old key is gone.',
                style: Type.compact.copyWith(color: ctx.ds.textSecondary),
              ),
              const SizedBox(height: Gap.xl),
              AppButton(
                label: 'Keep the old key',
                expand: true,
                onPressed: () => Navigator.of(ctx).pop(false),
              ),
              const SizedBox(height: Gap.sm),
              AppButton(
                label: 'Save anyway',
                kind: AppButtonKind.danger,
                expand: true,
                onPressed: () => Navigator.of(ctx).pop(true),
              ),
            ],
          ),
        ),
      );

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

    return _discardGuard(Scaffold(
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
                            style: Type.compact.copyWith(color: ds.textSecondary),
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
                              _KeyActions(
                                onGenerate: _generate,
                                showPublic: vm.hasSavedKey && _key.text.trim().isEmpty,
                                reading: vm.readingKey,
                                onShowPublic: () => vm.showSavedPublicKey(_passphrase.text),
                              ),
                              LabeledField(
                                label: 'Private key (PEM / OpenSSH)',
                                controller: _key,
                                mono: true,
                                minLines: 4,
                                maxLines: 6,
                                onChanged: (_) => _keyEdited(),
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
                              if (vm.publicKey != null || vm.publicKeyError != null)
                                _PublicKeyPanel(
                                  replacesSaved: vm.publicKeyGenerated && vm.hasSavedKey,
                                  publicKey: vm.publicKey,
                                  error: vm.publicKeyError,
                                  onCopyKey: () => _copy(vm.publicKey!, 'Public key copied'),
                                  onCopyCommand: () => _copy(
                                    KeyGenerator.authorizedKeysCommand(vm.publicKey!),
                                    'Command copied',
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
    ));
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

/// The form's one status panel: a sign-in to approve, the test's result, or
/// why Save stored nothing.
class _TestResult extends StatelessWidget {
  const _TestResult({required this.vm});

  final MachineFormViewModel vm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final approval = vm.testState == TestState.testing ? vm.approvalUrl : null;
    final saveError = vm.saveError;
    final (Color color, IconData icon, String title, String? detail)? view = saveError != null
        ? (ds.danger, LucideIcons.circleAlert, 'Could not save', saveError)
        : approval != null
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
                  child: vm.testState == TestState.ok && approval == null && saveError == null
                      ? _ConnectedPanel(color: view.$1, title: view.$3, detail: view.$4 ?? '')
                      : StatusPanel(
                          color: view.$1,
                          icon: view.$2,
                          title: view.$3,
                          message: view.$4,
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

/// The passed test: [StatusPanel]'s layout with the check drawn in once where
/// its icon would be. A rare, good moment; failure keeps the plain panel.
class _ConnectedPanel extends StatelessWidget {
  const _ConnectedPanel({required this.title, required this.detail, required this.color});

  final String title;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(StatusTint.pad),
        decoration: StatusTint.decoration(color),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: Gap.md, top: 1),
              child: DrawCheck(color: color),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Type.label.copyWith(color: ds.text, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                  if (detail.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        detail,
                        style: const TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.45)
                            .copyWith(color: ds.textSecondary),
                      ),
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

/// Generate (always) and, for a machine whose key is already saved, Show
/// public key. They wrap rather than shrink: large system text puts them on
/// two lines.
class _KeyActions extends StatelessWidget {
  const _KeyActions({
    required this.onGenerate,
    required this.showPublic,
    required this.reading,
    required this.onShowPublic,
  });

  final VoidCallback onGenerate;
  final bool showPublic;
  final bool reading;
  final VoidCallback onShowPublic;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: Gap.sm,
        runSpacing: Gap.xs,
        children: [
          AppButton(
            label: 'Generate key',
            icon: LucideIcons.keyRound,
            kind: AppButtonKind.secondary,
            compact: true,
            onPressed: onGenerate,
          ),
          if (showPublic)
            AppButton(
              label: 'Show public key',
              icon: LucideIcons.eye,
              kind: AppButtonKind.ghost,
              compact: true,
              loading: reading,
              onPressed: onShowPublic,
            ),
        ],
      );
}

/// The public half of the key in the form: the line itself in mono (wrapping,
/// never clipped), the two ways to put it on the machine, and one sentence on
/// what to do with them. Or, when the saved key could not be read, why.
class _PublicKeyPanel extends StatelessWidget {
  const _PublicKeyPanel({
    required this.replacesSaved,
    required this.publicKey,
    required this.error,
    required this.onCopyKey,
    required this.onCopyCommand,
  });

  final bool replacesSaved;
  final String? publicKey;
  final String? error;
  final VoidCallback onCopyKey;
  final VoidCallback onCopyCommand;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final key = publicKey;
    if (key == null) {
      return StatusPanel(color: ds.danger, icon: LucideIcons.circleAlert, message: error);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.fill,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Public key', style: Type.label.copyWith(color: ds.textSecondary)),
            const SizedBox(height: Gap.xs),
            Text(
              key,
              style: TextStyle(fontFamily: monoFamily, fontSize: 12, height: 1.45, color: ds.text),
            ),
            const SizedBox(height: Gap.sm),
            _CopyRow(icon: LucideIcons.copy, label: 'Copy public key', onTap: onCopyKey),
            const Hairline(),
            _CopyRow(icon: LucideIcons.terminal, label: 'Copy authorized_keys command', onTap: onCopyCommand),
            const SizedBox(height: Gap.xs),
            if (replacesSaved) ...[
              Text(
                'This replaces the key this machine uses now. Run the command on the host first, '
                'then Test connection, then Save.',
                style: Type.secondary.copyWith(color: ds.text),
              ),
              const SizedBox(height: Gap.xs),
            ],
            Text(
              'Run the command once on the machine, then test the connection. If you keep keys '
              'elsewhere (Tailscale, GitHub), paste the public key there instead.',
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
            const SizedBox(height: Gap.xs),
          ],
        ),
      ),
    );
  }
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      minTapSize: kMinTap,
      builder: (context, pressed) => Container(
        constraints: const BoxConstraints(minHeight: kMinTap),
        padding: const EdgeInsets.symmetric(vertical: Gap.sm),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            ExcludeSemantics(child: Icon(icon, size: 18, color: pressed ? ds.textSecondary : ds.accentText)),
            const SizedBox(width: Gap.md),
            Expanded(child: Text(label, style: Type.row.copyWith(color: pressed ? ds.textSecondary : ds.text))),
          ],
        ),
      ),
    );
  }
}
