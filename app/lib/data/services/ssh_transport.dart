import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../models/machine_profile.dart';
import 'bridge_command.dart';
import 'herdr_transport.dart';

/// Thrown (wrapped in [HerdrTransportException]) when a pinned host key no
/// longer matches.
const hostKeyChangedMessage =
    'Host key changed since it was first trusted. Re-add the machine if the '
    'change is expected.';

/// [HerdrTransport] over SSH: one authenticated [SSHClient] per machine, a
/// fresh exec channel per request, running the remote bridge command.
class SshTransport implements HerdrTransport {
  SshTransport({
    required this.profile,
    required this.secrets,
    required this.onPinHostKey,
    this.connectTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 20),
  }) : _command = buildBridgeCommand(
          session: profile.session,
          socketPath: profile.socketPath,
        );

  final MachineProfile profile;
  final MachineSecrets secrets;

  /// Called the first time a host key is seen (trust on first use) so the
  /// caller can persist it.
  final void Function(String fingerprint) onPinHostKey;
  final Duration connectTimeout;
  final Duration requestTimeout;

  final String _command;
  late String? _pinned = profile.hostKeyFingerprint;
  Future<SSHClient>? _client;
  var _nextId = 0;
  var _closed = false;

  Future<SSHClient> _connected() => _client ??= _connect().catchError((Object e) {
        _client = null;
        throw e;
      });

  Future<SSHClient> _connect() async {
    var hostKeyMismatch = false;
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(
        profile.host,
        profile.port,
        timeout: connectTimeout,
      );
      final List<SSHKeyPair>? identities;
      if (profile.auth == SshAuth.key) {
        final pem = secrets.privateKeyPem;
        if (pem == null || pem.isEmpty) {
          throw const HerdrTransportException('No private key saved for this machine.',
              fatal: true);
        }
        try {
          identities = SSHKeyPair.fromPem(pem, secrets.passphrase);
        } on Object {
          throw const HerdrTransportException(
              'Private key could not be read (wrong passphrase or unsupported format).',
              fatal: true);
        }
      } else {
        identities = null;
      }
      client = SSHClient(
        socket,
        username: profile.username,
        identities: identities,
        onPasswordRequest:
            profile.auth == SshAuth.password ? () => secrets.password : null,
        onVerifyHostKey: (type, fingerprint) {
          final seen = utf8.decode(fingerprint);
          final pinned = _pinned;
          if (pinned == null) {
            _pinned = seen;
            onPinHostKey(seen);
            return true;
          }
          hostKeyMismatch = pinned != seen;
          return !hostKeyMismatch;
        },
      );
      await client.authenticated.timeout(connectTimeout);
      client.done.then((_) => _drop(client!), onError: (_) => _drop(client!));
      return client;
    } on HerdrTransportException {
      client?.close();
      rethrow;
    } on SSHAuthFailError {
      client?.close();
      throw const HerdrTransportException(
          'SSH authentication failed (check username and key/password).',
          fatal: true);
    } on Object catch (e) {
      client?.close();
      if (hostKeyMismatch) {
        throw const HerdrTransportException(hostKeyChangedMessage, fatal: true);
      }
      throw HerdrTransportException('Cannot connect: $e');
    }
  }

  void _drop(SSHClient client) {
    // Only forget the client if it is still the current one.
    _client?.then((c) {
      if (identical(c, client)) _client = null;
    });
  }

  Future<SSHSession> _open() async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final client = await _connected();
    try {
      return await client.execute(_command);
    } on Object catch (e) {
      _client = null;
      client.close();
      throw HerdrTransportException('Cannot open channel: $e');
    }
  }

  String _frame(String method, Map<String, dynamic> params) =>
      '${jsonEncode({'id': 'm${_nextId++}', 'method': method, 'params': params})}\n';

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) async {
    final session = await _open();
    final stderr = utf8.decodeStream(session.stderr).catchError((Object _) => '');
    try {
      session.stdin.add(utf8.encode(_frame(method, params)));
      final String line;
      try {
        line = await jsonLines(session.stdout).first.timeout(requestTimeout);
      } on StateError {
        throw await _bridgeFailure(session, stderr);
      } on TimeoutException {
        throw HerdrTransportException('herdr did not answer $method in time');
      }
      return unwrapResponse(line);
    } finally {
      session.close();
    }
  }

  Future<HerdrTransportException> _bridgeFailure(
    SSHSession session,
    Future<String> stderr,
  ) async {
    final text = (await stderr.timeout(const Duration(seconds: 2), onTimeout: () => '')).trim();
    final code = session.exitCode;
    return HerdrTransportException(
      text.isNotEmpty ? text : 'herdr bridge closed the channel (exit $code)',
      fatal: code == 78,
    );
  }

  @override
  Stream<Map<String, dynamic>> events(List<Map<String, dynamic>> subscriptions) {
    SSHSession? session;
    StreamSubscription<String>? sub;
    late final StreamController<Map<String, dynamic>> out;
    out = StreamController<Map<String, dynamic>>(
      onListen: () async {
        try {
          final s = session = await _open();
          final stderr = utf8.decodeStream(s.stderr).catchError((Object _) => '');
          s.stdin.add(utf8.encode(
              _frame('events.subscribe', {'subscriptions': subscriptions})));
          var acked = false;
          sub = jsonLines(s.stdout).listen(
            (line) {
              try {
                if (!acked) {
                  unwrapResponse(line); // throws on API error
                  acked = true;
                  return;
                }
                final decoded = jsonDecode(line);
                if (decoded is Map<String, dynamic>) out.add(decoded);
              } on Object catch (e) {
                out.addError(e);
              }
            },
            onError: out.addError,
            onDone: () async {
              if (out.isClosed) return;
              out.addError(await _bridgeFailure(s, stderr));
              await out.close();
            },
          );
        } on Object catch (e) {
          out.addError(e);
          await out.close();
        }
      },
      onCancel: () async {
        await sub?.cancel();
        session?.close();
      },
    );
    return out.stream;
  }

  @override
  Future<void> close() async {
    _closed = true;
    final pending = _client;
    _client = null;
    if (pending == null) return;
    try {
      (await pending).close();
    } on Object {
      // connect already failed; nothing to close
    }
  }
}
