import '../models/machine_profile.dart';
import 'herdr_transport.dart';
import 'isolate_transport.dart';
import 'ssh_transport.dart';

/// The one way the app opens a connection to a machine: SSH, hosted in a
/// background isolate so network work never runs on the UI thread.
///
/// [onNotice] receives login banners the server sends before authentication
/// (for Tailscale SSH in check mode: a link to approve the sign-in).
HerdrTransport createSshTransport(
  MachineProfile profile,
  MachineSecrets secrets,
  void Function(String fingerprint) onPinHostKey,
  void Function(String banner) onNotice,
) => createSshTransportLater(() => profile, () async => secrets, onPinHostKey, onNotice);

/// [createSshTransport] for secrets that are not at hand yet. [secrets] is
/// asked for when the worker starts, on the first request, so a connection can
/// exist (and show what it cached) while the keychain is still answering. A
/// keychain that fails is a failed attempt, retried like any other.
///
/// [profile] is asked for each time a worker starts, not once: a worker that
/// is replaced must get the host key pinned since the connection was built.
/// Built from the profile of that moment it would trust the next key it sees
/// again (trust on first use), and its answer would replace the pin.
HerdrTransport createSshTransportLater(
  MachineProfile Function() profile,
  Future<MachineSecrets> Function() secrets,
  void Function(String fingerprint) onPinHostKey,
  void Function(String banner) onNotice,
) =>
    IsolateTransport(
      builder: _buildSsh,
      config: () => sshWorkerConfig(profile(), secrets),
      onPin: onPinHostKey,
      onNotice: onNotice,
    );

/// What a worker is built from: [profile] (with its pinned host key) and the
/// credentials [secrets] answers with.
Future<Map<String, Object?>> sshWorkerConfig(
  MachineProfile profile,
  Future<MachineSecrets> Function() secrets,
) async {
  final MachineSecrets s;
  try {
    s = await secrets();
  } on Object {
    throw const HerdrTransportException(
      "Couldn't read the saved credentials from the keychain.",
    );
  }
  return {
    'profile': profile.toJson(),
    'privateKeyPem': s.privateKeyPem,
    'passphrase': s.passphrase,
    'password': s.password,
  };
}

/// Runs inside the worker isolate.
HerdrTransport _buildSsh(
  Object? config,
  void Function(String) onPin,
  void Function(String) onNotice,
) {
  final c = config! as Map<Object?, Object?>;
  return SshTransport(
    profile: MachineProfile.fromJson(
      Map<String, dynamic>.from(c['profile']! as Map),
    ),
    secrets: MachineSecrets(
      privateKeyPem: c['privateKeyPem'] as String?,
      passphrase: c['passphrase'] as String?,
      password: c['password'] as String?,
    ),
    onPinHostKey: onPin,
    onNotice: onNotice,
  );
}
