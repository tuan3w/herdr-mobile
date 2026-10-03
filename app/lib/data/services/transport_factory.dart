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
) =>
    IsolateTransport(
      builder: _buildSsh,
      config: {
        'profile': profile.toJson(),
        'privateKeyPem': secrets.privateKeyPem,
        'passphrase': secrets.passphrase,
        'password': secrets.password,
      },
      onPin: onPinHostKey,
      onNotice: onNotice,
    );

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
