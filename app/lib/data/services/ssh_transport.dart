import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../models/machine_profile.dart';
import 'bridge_command.dart';
import 'herdr_transport.dart';
import 'mux_client.dart';

/// Thrown (wrapped in [HerdrTransportException]) when a pinned host key no
/// longer matches.
const hostKeyChangedMessage =
    'Host key changed since it was first trusted. Re-add the machine if the '
    'change is expected.';

/// [HerdrTransport] over SSH: one authenticated [SSHClient] per machine.
/// Requests share one persistent multiplexed channel ([MuxClient]); hosts
/// that cannot run it get a fresh exec channel per request through the
/// bridge command instead. Each event subscription has its own channel.
class SshTransport implements HerdrTransport {
  SshTransport({
    required this.profile,
    required this.secrets,
    required this.onPinHostKey,
    this.connectTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 20),
  })  : _command = buildBridgeCommand(
          session: profile.session,
          socketPath: profile.socketPath,
        ),
        _muxCommand = buildMuxCommand(
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
  final String _muxCommand;
  late String? _pinned = profile.hostKeyFingerprint;
  Future<SSHClient>? _client;
  MuxClient? _mux;
  Future<MuxClient>? _muxStart;
  // After a failed mux start (no python3, or herdr's socket is not there right
  // now, e.g. herdr is restarting) requests use the slower bridge channel until
  // this instant, then the mux is tried again. Not permanent: a missing socket
  // is a transient condition, not a property of the host.
  DateTime? _muxRetryAt;
  static const _muxRetryDelay = Duration(seconds: 30);
  // Bumped by every teardown so a mux that finished starting afterwards is
  // discarded instead of installed.
  var _epoch = 0;
  final _liveEvents = <void Function(HerdrTransportException)>{};
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

  Future<SSHSession> _open(String command) async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final client = await _connected();
    try {
      return await client.execute(command);
    } on Object catch (e) {
      _drop(client);
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
    final mux = await _muxClient();
    if (mux != null) return mux.request(method, params);
    return _bridgeRequest(method, params);
  }

  /// The shared mux, started on first use, or null while it is unavailable
  /// (requests then use one bridge channel each, see [_muxRetryAt]).
  Future<MuxClient?> _muxClient() async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final retryAt = _muxRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return null;
    final live = _mux;
    if (live != null && live.isAlive) return live;
    try {
      return await (_muxStart ??= _startMux().whenComplete(() => _muxStart = null));
    } on MuxUnavailable catch (e) {
      if (e.linkLost) throw HerdrTransportException('Connection lost: $e');
      _muxRetryAt = DateTime.now().add(_muxRetryDelay);
      return null;
    }
  }

  Future<MuxClient> _startMux() async {
    final epoch = _epoch;
    final session = await _open(_muxCommand);
    final mux = await MuxClient.connect(_SshMuxChannel(session),
        requestTimeout: requestTimeout);
    if (epoch != _epoch) {
      mux.close();
      throw const HerdrTransportException('Connection reset');
    }
    _mux = mux;
    _muxRetryAt = null;
    mux.onDead.then((cause) {
      if (!identical(_mux, mux)) return;
      _mux = null;
      // A silent mux means the TCP link is half-open; everything on it is
      // dead, including the event channels.
      if (cause == MuxDeath.unresponsive) reset();
    });
    return mux;
  }

  Future<Map<String, dynamic>> _bridgeRequest(
    String method,
    Map<String, dynamic> params,
  ) async {
    final session = await _open(_command);
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
    // Ends the stream with a retryable error; idempotent.
    void fail(HerdrTransportException error) {
      if (out.isClosed) return;
      _liveEvents.remove(fail);
      out.addError(error);
      out.close();
      sub?.cancel();
      session?.close();
    }

    out = StreamController<Map<String, dynamic>>(
      onListen: () async {
        _liveEvents.add(fail);
        try {
          final s = session = await _open(_command);
          if (out.isClosed) {
            s.close();
            return;
          }
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
            onDone: () async => fail(await _bridgeFailure(s, stderr)),
          );
        } on Object catch (e) {
          if (out.isClosed) return;
          _liveEvents.remove(fail);
          out.addError(e);
          await out.close();
        }
      },
      onCancel: () async {
        _liveEvents.remove(fail);
        await sub?.cancel();
        session?.close();
      },
    );
    return out.stream;
  }

  @override
  void reset() => unawaited(_teardown());

  @override
  Future<void> close() {
    _closed = true;
    return _teardown();
  }

  /// Synchronously invalidates the mux, event streams and SSH client (so
  /// in-flight work fails right away), then closes the client.
  Future<void> _teardown() async {
    _epoch++;
    final mux = _mux;
    _mux = null;
    final pending = _client;
    _client = null;
    for (final fail in [..._liveEvents]) {
      fail(const HerdrTransportException('Connection reset'));
    }
    mux?.close();
    try {
      (await pending)?.close();
    } on Object {
      // connect already failed; nothing to close
    }
  }
}

/// [MuxChannel] over one SSH exec channel.
class _SshMuxChannel implements MuxChannel {
  _SshMuxChannel(this._session) {
    // Unread stderr would stall the channel's flow control.
    _session.stderr.listen((_) {}, onError: (Object _) {});
  }

  final SSHSession _session;

  @override
  late final Stream<String> lines = jsonLines(_session.stdout);

  @override
  void send(String line) => _session.stdin.add(utf8.encode('$line\n'));

  @override
  Future<void> close() async => _session.close();

  @override
  late final Future<int?> exitCode =
      _session.done.then((_) => _session.exitCode, onError: (Object _) => null);
}
