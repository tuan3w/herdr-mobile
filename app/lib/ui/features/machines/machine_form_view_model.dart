import 'package:flutter/foundation.dart';

import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/services/auth_notice.dart';
import '../../../data/services/herdr_transport.dart';
import '../../../data/services/transport_factory.dart';

/// Raw, trimmed-or-empty field values from the form.
class MachineFormValues {
  const MachineFormValues({
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.auth,
    this.privateKey = '',
    this.passphrase = '',
    this.password = '',
    this.session = 'default',
    this.socketPath = '',
  });

  final String label;
  final String host;
  final int port;
  final String username;
  final SshAuth auth;
  final String privateKey;
  final String passphrase;
  final String password;
  final String session;
  final String socketPath;
}

enum TestState { idle, testing, ok, failed }

typedef TransportFactory = HerdrTransport Function(
  MachineProfile profile,
  MachineSecrets secrets,
  void Function(String fingerprint) onPinHostKey,
  void Function(String banner) onNotice,
);

class MachineFormViewModel extends ChangeNotifier {
  MachineFormViewModel({
    required this._repo,
    this.existing,
    this._transportFactory = createSshTransport,
  });

  final MachineRepository _repo;
  final MachineProfile? existing;
  final TransportFactory _transportFactory;

  TestState _testState = TestState.idle;
  String? _message;
  String? _fingerprint;
  String? _version;
  int _workspaces = 0;
  bool _saving = false;
  String? _approvalUrl;

  TestState get testState => _testState;

  /// Failure reason when [testState] is failed.
  String? get message => _message;

  /// Host key seen during the last successful test.
  String? get fingerprint => _fingerprint;
  String? get version => _version;
  int get workspaceCount => _workspaces;
  bool get saving => _saving;

  /// While a test waits for the person to approve a sign-in (Tailscale SSH
  /// check mode): the `https` link to approve it at.
  String? get approvalUrl => _approvalUrl;
  bool get isEdit => existing != null;

  /// Any edit invalidates a previous test result.
  void invalidateTest() {
    if (_testState == TestState.idle) return;
    _testState = TestState.idle;
    _message = null;
    notifyListeners();
  }

  /// A pinned host key only applies while host and port are unchanged.
  String? _pinFor(MachineFormValues v) {
    final e = existing;
    if (e == null || e.host != v.host || e.port != v.port) return null;
    return e.hostKeyFingerprint;
  }

  MachineProfile _profile(MachineFormValues v, {String? fingerprint}) =>
      MachineProfile(
        id: existing?.id ?? _repo.newId(),
        label: v.label.isEmpty ? v.host : v.label,
        host: v.host,
        port: v.port,
        username: v.username,
        auth: v.auth,
        session: v.session.isEmpty ? 'default' : v.session,
        socketPath: v.socketPath.isEmpty ? null : v.socketPath,
        hostKeyFingerprint: fingerprint,
        enabled: existing?.enabled ?? true,
      );

  /// Blank secret fields keep the stored value when editing; secrets that do
  /// not apply to the chosen auth method are dropped.
  Future<MachineSecrets> _secrets(MachineFormValues v) async {
    final old = existing == null
        ? const MachineSecrets()
        : await _repo.secretsFor(existing!.id);
    String? pick(String fresh, String? stored) =>
        fresh.isNotEmpty ? fresh : stored;
    return switch (v.auth) {
      SshAuth.key => MachineSecrets(
          privateKeyPem: pick(v.privateKey, old.privateKeyPem),
          passphrase: pick(v.passphrase, old.passphrase),
        ),
      SshAuth.password => MachineSecrets(password: pick(v.password, old.password)),
      SshAuth.none => const MachineSecrets(),
    };
  }

  Future<void> test(MachineFormValues v) async {
    _testState = TestState.testing;
    _message = null;
    _approvalUrl = null;
    notifyListeners();
    String? seen;
    final profile = _profile(v, fingerprint: _pinFor(v));
    final transport = _transportFactory(
      profile,
      await _secrets(v),
      (f) => seen = f,
      (banner) {
        final url = approvalUrlFrom(banner);
        if (url == null || url == _approvalUrl) return;
        _approvalUrl = url;
        notifyListeners();
      },
    );
    try {
      final api = HerdrApi(transport);
      _version = await api.ping();
      _workspaces = (await api.snapshot()).workspaces.length;
      _fingerprint = seen ?? profile.hostKeyFingerprint;
      _testState = TestState.ok;
    } on HerdrTransportException catch (e) {
      _message = e.message;
      _testState = TestState.failed;
    } on HerdrApiException catch (e) {
      _message = e.toString();
      _testState = TestState.failed;
    } finally {
      await transport.close();
      notifyListeners();
    }
  }

  Future<void> save(MachineFormValues v) async {
    _saving = true;
    notifyListeners();
    try {
      final pin = _fingerprint != null && _testState == TestState.ok
          ? _fingerprint
          : _pinFor(v);
      await _repo.save(_profile(v, fingerprint: pin), secrets: await _secrets(v));
    } finally {
      _saving = false;
      notifyListeners();
    }
  }
}
