/// How to prove who we are to the machine.
///
/// [none] stores no credentials: Tailscale SSH already knows the phone's
/// identity from the tailnet and, in check mode, asks for a browser approval.
enum SshAuth { key, password, none }

/// A saved remote herdr machine. Secrets (private key, passphrase, password)
/// are never stored here; see `SecretStore`.
class MachineProfile {
  const MachineProfile({
    required this.id,
    required this.label,
    required this.host,
    required this.username,
    this.port = 22,
    this.auth = SshAuth.key,
    this.session = 'default',
    this.socketPath,
    this.hostKeyFingerprint,
    this.enabled = true,
  });

  factory MachineProfile.fromJson(Map<String, dynamic> j) => MachineProfile(
        id: j['id'] as String,
        label: j['label'] as String,
        host: j['host'] as String,
        username: j['username'] as String,
        port: (j['port'] as num?)?.toInt() ?? 22,
        auth: SshAuth.values.asNameMap()[j['auth']] ?? SshAuth.key,
        session: (j['session'] as String?) ?? 'default',
        socketPath: j['socketPath'] as String?,
        hostKeyFingerprint: j['hostKeyFingerprint'] as String?,
        enabled: j['enabled'] != false,
      );

  /// [fromJson] for a stored row that may be anything: null when [row] is not
  /// a machine this app can read (not an object, a field of another type, an
  /// id or host missing).
  static MachineProfile? tryParse(Object? row) {
    if (row is! Map) return null;
    try {
      return MachineProfile.fromJson(Map<String, dynamic>.from(row));
    } on Object {
      return null;
    }
  }

  final String id;
  final String label;
  final String host;
  final int port;
  final String username;
  final SshAuth auth;

  /// herdr session name on the remote host.
  final String session;

  /// Optional absolute path of the herdr API socket, used only when the
  /// remote herdr lacks `remote-api-bridge` and the session is not `default`.
  final String? socketPath;

  /// Pinned `SHA256:<base64>` host key (trust on first use).
  final String? hostKeyFingerprint;
  final bool enabled;

  MachineProfile copyWith({
    String? label,
    String? host,
    int? port,
    String? username,
    SshAuth? auth,
    String? session,
    String? socketPath,
    bool clearSocketPath = false,
    String? hostKeyFingerprint,
    bool clearHostKey = false,
    bool? enabled,
  }) =>
      MachineProfile(
        id: id,
        label: label ?? this.label,
        host: host ?? this.host,
        port: port ?? this.port,
        username: username ?? this.username,
        auth: auth ?? this.auth,
        session: session ?? this.session,
        socketPath: clearSocketPath ? null : socketPath ?? this.socketPath,
        hostKeyFingerprint:
            clearHostKey ? null : hostKeyFingerprint ?? this.hostKeyFingerprint,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'username': username,
        'auth': auth.name,
        'session': session,
        if (socketPath != null) 'socketPath': socketPath,
        if (hostKeyFingerprint != null) 'hostKeyFingerprint': hostKeyFingerprint,
        'enabled': enabled,
      };
}

/// Secrets for one machine.
class MachineSecrets {
  const MachineSecrets({this.privateKeyPem, this.passphrase, this.password});

  final String? privateKeyPem;
  final String? passphrase;
  final String? password;
}
