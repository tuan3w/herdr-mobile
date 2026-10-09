import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../../../data/models/machine_profile.dart';
import '../../../data/repositories/machine_repository.dart';
import '../../../data/services/herdr_api.dart';
import '../../../data/services/auth_notice.dart';
import '../../../data/services/herdr_transport.dart';
import '../../../data/services/key_generator.dart';

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
    required this._transportFactory,
  });

  final MachineRepository _repo;
  final MachineProfile? existing;
  final TransportFactory _transportFactory;

  TestState _testState = TestState.idle;

  /// Bumped by every test and every [invalidateTest]; a test whose number is
  /// no longer current was overtaken by an edit and reports nothing.
  int _testGeneration = 0;

  /// What the last passing test connected with.
  MachineFormValues? _tested;
  String? _message;
  String? _fingerprint;
  String? _version;
  int _workspaces = 0;
  bool _saving = false;
  String? _saveError;
  String? _approvalUrl;
  String? _newId;

  bool _hasSavedKey = false;
  String? _publicKey;
  bool _publicKeyGenerated = false;
  String? _publicKeyError;
  bool _readingKey = false;
  bool _draftHeld = false;
  bool _disposed = false;

  TestState get testState => _testState;

  /// Failure reason when [testState] is failed.
  String? get message => _message;

  /// Host key seen during the last successful test.
  String? get fingerprint => _fingerprint;
  String? get version => _version;
  int get workspaceCount => _workspaces;
  bool get saving => _saving;

  /// Why the last Save stored nothing, and what to do. Cleared by the next
  /// attempt or any edit; the form keeps everything that was entered.
  String? get saveError => _saveError;

  /// While a test waits for the person to approve a sign-in (Tailscale SSH
  /// check mode): the `https` link to approve it at.
  String? get approvalUrl => _approvalUrl;
  bool get isEdit => existing != null;

  /// A private key is already saved for this machine (edit only). Its secret
  /// never reaches the form; only its public half can be shown.
  bool get hasSavedKey => _hasSavedKey;

  /// The public key to show under the key field: the one just generated, or
  /// the one derived from the saved key. Null when there is none to show.
  String? get publicKey => _publicKey;

  /// The shown public key belongs to a key just generated here (not to the
  /// saved one): the person has to install it before it can be used.
  bool get publicKeyGenerated => _publicKeyGenerated;

  /// Why the saved key's public half could not be shown.
  String? get publicKeyError => _publicKeyError;

  /// The saved key is being unlocked (a protected key takes about a second).
  bool get readingKey => _readingKey;

  /// Learns whether a key is already saved for the machine being edited.
  Future<void> loadSavedKey() async {
    final e = existing;
    if (e == null) return;
    final saved = await _repo.secretsFor(e.id);
    if (_disposed) return;
    _hasSavedKey = (saved.privateKeyPem ?? '').isNotEmpty;
    notifyListeners();
  }

  /// Makes a new key pair. The caller puts the returned private key in the
  /// form; only the public line is kept here for display. The private half is
  /// also held as a draft in secure storage until Save or the form closes, so
  /// it survives Android reclaiming the process while the person installs the
  /// public half on the host ([restoreKeyDraft]).
  GeneratedKey generateKey({required String label}) {
    final key = KeyGenerator.generate(label: label);
    _publicKey = key.publicKeyLine;
    _publicKeyGenerated = true;
    _publicKeyError = null;
    _draftHeld = true;
    // A keystore that refuses only costs the restore after a reclaimed
    // process; the key itself is in the field.
    unawaited(_repo.holdKeyDraft(key.privateKeyPem).catchError((Object _) {}));
    notifyListeners();
    return key;
  }

  /// The form came back after Android reclaimed the process while it held a
  /// generated key: returns that key for the field and shows its public half
  /// again. Null when there is none.
  Future<String?> restoreKeyDraft() async {
    try {
      final pem = await _repo.keyDraft();
      if (pem == null || pem.isEmpty || _disposed) return null;
      final result = await KeyGenerator.readPublicKeyOffThread(pem);
      if (_disposed) return null;
      _draftHeld = true;
      _publicKey = result.line;
      _publicKeyGenerated = result.line != null;
      _publicKeyError = null;
      notifyListeners();
      return pem;
    } on Object {
      return null;
    }
  }

  /// A form opened afresh: forgets a key left behind by a process that died
  /// and was not brought back.
  void clearStaleKeyDraft() {
    _draftHeld = false;
    unawaited(_repo.dropKeyDraft().catchError((Object _) {}));
  }

  /// The held key is no longer wanted: the form closed without saving it, it
  /// was saved, or the field no longer holds it. Not on [dispose]: a process
  /// Android reclaims never runs it, and a tree torn down without the person
  /// leaving the form must not lose the key either.
  void dropKeyDraft() {
    if (_draftHeld) clearStaleKeyDraft();
  }

  /// Derives the public key from the saved private key. [passphrase] is what
  /// the person typed; blank falls back to the saved one. The private key is
  /// read here and dropped: nothing but the public line is exposed.
  Future<void> showSavedPublicKey(String passphrase) async {
    final e = existing;
    if (e == null || _readingKey) return;
    _readingKey = true;
    _publicKey = null;
    _publicKeyGenerated = false;
    _publicKeyError = null;
    notifyListeners();
    try {
      final saved = await _repo.secretsFor(e.id);
      final pem = saved.privateKeyPem;
      if (pem == null || pem.isEmpty) {
        _hasSavedKey = false;
        _publicKeyError = 'No private key is saved for this machine.';
        return;
      }
      final result = await KeyGenerator.readPublicKeyOffThread(
        pem,
        passphrase: passphrase.isNotEmpty ? passphrase : saved.passphrase,
      );
      _publicKey = result.line;
      _publicKeyError = switch (result.failure) {
        null => null,
        KeyReadFailure.needsPassphrase =>
          'This key has a passphrase. Enter it in the field below, then try again.',
        KeyReadFailure.wrongPassphrase => 'That passphrase does not open the saved key.',
        KeyReadFailure.unreadable => 'The saved key could not be read.',
      };
    } finally {
      _readingKey = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// The key field changed by hand: a shown public key no longer describes it,
  /// and a held draft is no longer the key in the field.
  void dropPublicKey() {
    dropKeyDraft();
    if (_publicKey == null && _publicKeyError == null) return;
    _publicKey = null;
    _publicKeyGenerated = false;
    _publicKeyError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Any edit invalidates a previous test result and a failed save's reason,
  /// and a test still out: its result is dropped when it arrives.
  void invalidateTest() {
    if (_testState == TestState.idle && _saveError == null) return;
    _testGeneration++;
    _testState = TestState.idle;
    _message = null;
    _approvalUrl = null;
    _saveError = null;
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
        // One id per form, so a save retried after a failure rewrites the
        // same slot instead of leaving the first attempt's secrets behind.
        id: existing?.id ?? (_newId ??= _repo.newId()),
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
    // A key copied on a phone arrives with its line breaks gone or indented.
    final key = KeyGenerator.cleanPastedPem(v.privateKey);
    return switch (v.auth) {
      SshAuth.key => MachineSecrets(
          privateKeyPem: pick(key, old.privateKeyPem),
          // A passphrase protects one particular key. Replacing the key must
          // not carry the old passphrase over: dartssh2 refuses a passphrase
          // for a key that has none, which would lock the machine out.
          passphrase: key.isNotEmpty
              ? (v.passphrase.isEmpty ? null : v.passphrase)
              : pick(v.passphrase, old.passphrase),
        ),
      SshAuth.password => MachineSecrets(password: pick(v.password, old.password)),
      SshAuth.none => const MachineSecrets(),
    };
  }

  /// Connects with what the form holds. Every failure ends the test with a
  /// reason in [message]; the transport bounds each stage (connect, request,
  /// sign-in approval), so the busy state always ends.
  Future<void> test(MachineFormValues v) async {
    final generation = ++_testGeneration;
    // An edit while the test is out ([invalidateTest]) or a newer test
    // supersedes it: what it finds describes values that are gone.
    bool stale() => generation != _testGeneration;
    _testState = TestState.testing;
    _message = null;
    _approvalUrl = null;
    _saveError = null;
    _tested = null;
    notifyListeners();
    String? seen;
    final profile = _profile(v, fingerprint: _pinFor(v));
    MachineSecrets? secrets;
    HerdrTransport? transport;
    try {
      secrets = await _secrets(v);
      transport = _transportFactory(
        profile,
        secrets,
        (f) => seen = f,
        (banner) {
          final url = approvalUrlFrom(banner);
          if (stale() || url == null || url == _approvalUrl) return;
          _approvalUrl = url;
          if (!_disposed) notifyListeners();
        },
      );
      final api = HerdrApi(transport);
      final version = await api.ping();
      final workspaces = (await api.snapshot()).workspaces.length;
      if (!stale()) {
        _version = version;
        _workspaces = workspaces;
        _fingerprint = seen ?? profile.hostKeyFingerprint;
        _tested = v;
        _testState = TestState.ok;
      }
    } on Object catch (e) {
      if (!stale()) {
        _testState = TestState.failed;
        _message = switch (e) {
          HerdrTransportException(:final message) => message,
          HerdrApiException() => e.toString(),
          _ when secrets == null =>
            'The saved secrets could not be read from this phone\'s keystore (${_describe(e)}). '
                'Test again; if it keeps failing, restart the app.',
          TimeoutException() => 'The machine did not answer in time. Check that it is on and '
              'reachable from this phone, then test again.',
          _ => 'The test stopped: ${_describe(e)}. Check the host and port, then test again.',
        };
      }
    } finally {
      try {
        await transport?.close();
      } on Object {
        // Already gone: nothing is left to close.
      }
      if (!_disposed) notifyListeners();
    }
  }

  /// The last test passed for exactly these values: nothing that reaches the
  /// host differs from what was tested. Only then does its host key belong to
  /// what Save would store, and only then does it vouch for a replaced key.
  bool testedFor(MachineFormValues v) {
    final t = _tested;
    return _testState == TestState.ok &&
        t != null &&
        t.host == v.host &&
        t.port == v.port &&
        t.username == v.username &&
        t.auth == v.auth &&
        t.privateKey == v.privateKey &&
        t.passphrase == v.passphrase &&
        t.password == v.password &&
        t.session == v.session &&
        t.socketPath == v.socketPath;
  }

  /// Stores the machine. False when nothing could be stored: [saveError]
  /// says why and the form keeps everything that was entered.
  Future<bool> save(MachineFormValues v) async {
    _saving = true;
    _saveError = null;
    notifyListeners();
    try {
      final pin = _fingerprint != null && testedFor(v) ? _fingerprint : _pinFor(v);
      await _repo.save(_profile(v, fingerprint: pin), secrets: await _secrets(v));
      dropKeyDraft();
      return true;
    } on Object catch (e) {
      _saveError = 'This phone\'s storage refused it (${_describe(e)}). Everything you entered '
          'is still here: save again. If it keeps failing, restart the app.';
      return false;
    } finally {
      _saving = false;
      if (!_disposed) notifyListeners();
    }
  }
}

/// A failure in words: a platform error's own message rather than its dump.
String _describe(Object e) => switch (e) {
      PlatformException(:final message?) => message,
      PlatformException(:final code) => code,
      _ => '$e',
    };
