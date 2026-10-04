import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/machine_profile.dart';
import '../models/remote_file.dart';
import 'auth_notice.dart';
import 'bridge_command.dart';
import 'herdr_transport.dart';
import 'mux_client.dart';
import 'sftp_files.dart';

/// Thrown (wrapped in [HerdrTransportException]) when a pinned host key no
/// longer matches.
const hostKeyChangedMessage =
    'Host key changed since it was first trusted. Re-add the machine if the '
    'change is expected.';

/// Cipher and MAC preference for the SSH connection.
///
/// dartssh2 encrypts in pure Dart on the isolate it runs on, and its default
/// order picks AES-GCM first. Measured through the library (8 MB over
/// loopback): AES-GCM 1.0 MB/s, AES-128-CTR + HMAC-SHA256-ETM 29 MB/s,
/// ChaCha20-Poly1305 40 MB/s. On a phone the GCM default meant ~4.5 ms per KB,
/// freezing the UI for ~600 ms per pane refresh. GCM stays as a last resort
/// for servers that offer nothing else.
const sshAlgorithms = SSHAlgorithms(
  cipher: [
    SSHCipherType.chacha20poly1305,
    SSHCipherType.aes128ctr,
    SSHCipherType.aes256ctr,
    SSHCipherType.aes128gcm,
    SSHCipherType.aes256gcm,
  ],
  mac: [
    SSHMacType.hmacSha256Etm,
    SSHMacType.hmacSha512Etm,
    SSHMacType.hmacSha256,
    SSHMacType.hmacSha512,
    SSHMacType.hmacSha1,
  ],
);

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
    this.approvalTimeout = const Duration(minutes: 5),
    this.onNotice,
  })  : _command = buildBridgeCommand(
          session: profile.session,
          socketPath: profile.socketPath,
        ),
        _muxCommand = buildMuxCommand(
          session: profile.session,
          socketPath: profile.socketPath,
        ),
        _eventsCommand = buildEventsCommand(
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

  /// How long to wait for a person to approve a sign-in link the server shows.
  final Duration approvalTimeout;

  /// Called with every login banner the server sends before authentication.
  final void Function(String banner)? onNotice;

  final String _command;
  final String _muxCommand;
  final String _eventsCommand;
  late String? _pinned = profile.hostKeyFingerprint;
  Future<SSHClient>? _client;
  MuxClient? _mux;
  Future<MuxClient>? _muxStart;
  // After a failed mux start (no python3, or herdr's socket is not there right
  // now, e.g. herdr is restarting) requests use the slower bridge channel until
  // this instant, then the mux is tried again. Not permanent: a missing socket
  // is a transient condition, not a property of the host. An event
  // subscription whose script exits 78 sets it too, and takes the bridge.
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
    final authenticated = Completer<void>();
    Timer? deadline;
    // Authentication normally takes a moment. When the server shows a login
    // link instead (Tailscale check mode) it is waiting for a person, so the
    // deadline moves out while the link is pending.
    void expectAuthWithin(Duration limit, Object error) {
      deadline?.cancel();
      deadline = Timer(limit, () {
        if (!authenticated.isCompleted) authenticated.completeError(error);
      });
    }

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
      expectAuthWithin(connectTimeout, TimeoutException('SSH login timed out'));
      client = SSHClient(
        socket,
        username: profile.username,
        identities: identities,
        algorithms: sshAlgorithms,
        // With neither a key nor a password only the `none` method is tried,
        // which is what Tailscale SSH expects: it already knows who we are.
        onPasswordRequest:
            profile.auth == SshAuth.password ? () => secrets.password : null,
        onUserauthBanner: (banner) {
          onNotice?.call(banner);
          if (approvalUrlFrom(banner) != null) {
            expectAuthWithin(
              approvalTimeout,
              const HerdrTransportException(
                'Sign-in was not approved in time. Retry to get a new link.',
                fatal: true,
              ),
            );
          }
        },
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
      client.authenticated.then(
        (_) {
          if (!authenticated.isCompleted) authenticated.complete();
        },
        onError: (Object e, StackTrace s) {
          if (!authenticated.isCompleted) authenticated.completeError(e, s);
        },
      );
      await authenticated.future;
      client.done.then((_) => _drop(client!), onError: (_) => _drop(client!));
      return client;
    } on HerdrTransportException {
      client?.close();
      rethrow;
    } on SSHAuthFailError {
      client?.close();
      throw HerdrTransportException(
        switch (profile.auth) {
          SshAuth.none => 'Tailscale SSH did not accept this sign-in. Check that '
              'Tailscale is connected on this phone and that your tailnet policy '
              'lets you SSH to this machine as "${profile.username}".',
          _ => 'SSH authentication failed (check username and key/password).',
        },
        fatal: true,
      );
    } on Object catch (e) {
      client?.close();
      if (hostKeyMismatch) {
        throw const HerdrTransportException(hostKeyChangedMessage, fatal: true);
      }
      throw HerdrTransportException('Cannot connect: $e');
    } finally {
      deadline?.cancel();
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

  /// Files go over SFTP on the same authenticated connection: one cached
  /// session, reopened by [SftpFiles] when its channel dies.
  late final SftpFiles _files = SftpFiles(open: _openSftp);

  /// How long a host may take to answer the sftp subsystem request before it
  /// is reported as not offering SFTP. Some sshd configs never answer.
  static const _sftpHandshakeTimeout = Duration(seconds: 5);

  /// After a host answered "no SFTP" the verdict stands for this long, so the
  /// next screen does not wait out the handshake timeout again.
  static const _noSftpMemory = Duration(minutes: 2);
  DateTime? _noSftpUntil;

  Future<SftpApi> _openSftp() async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final remembered = _noSftpUntil;
    if (remembered != null && DateTime.now().isBefore(remembered)) throw _noSftp();
    final client = await _connected();
    final SftpClient sftp;
    try {
      sftp = await client.sftp();
    } on SSHChannelOpenError {
      throw _noSftp();
    } on Object catch (e) {
      _drop(client);
      client.close();
      throw HerdrTransportException('Cannot open channel: $e');
    }
    try {
      await sftp.handshake.timeout(_sftpHandshakeTimeout);
    } on Object {
      unawaited(sftp.close().then((_) {}, onError: (Object _) {}));
      // The SSH connection itself may be what died, which is not the host's
      // lack of SFTP.
      if (client.isClosed) throw const HerdrTransportException('Connection lost');
      _noSftpUntil = DateTime.now().add(_noSftpMemory);
      throw _noSftp();
    }
    return DartSftp(sftp);
  }

  static RemoteFileException _noSftp() => RemoteFileException(
        RemoteFileErrorKind.unsupported,
        'This host does not allow SFTP, so its files cannot be shown. Enable the '
        '"sftp" subsystem in its sshd_config to use Files.',
      );

  @override
  bool get supportsFiles => true;

  @override
  Future<RemoteStat> statFile(String path) => _files.stat(path);

  @override
  Future<List<RemoteEntry>> listDirectory(String path) => _files.list(path);

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) =>
      _files.read(path, offset, length);

  @override
  Future<String> realPath(String path) => _files.realPath(path);

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
        // Opens the subscription through [command] (the events script, or
        // the bridge it falls back to).
        Future<void> subscribe(String command, {required bool script}) async {
          final s = session = await _open(command);
          if (out.isClosed) {
            s.close();
            return;
          }
          final stderr = utf8.decodeStream(s.stderr).catchError((Object _) => '');
          s.stdin.add(utf8.encode(
              _frame('events.subscribe', {'subscriptions': subscriptions})));
          var acked = false;
          sub = muxMessages(s.stdout).listen(
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
              final failure = await _bridgeFailure(s, stderr);
              if (script && !acked && failure.fatal && !out.isClosed) {
                // Exit 78: this host cannot run the script (no python3, or no
                // socket where it looked). The bridge can; mux and script
                // share the verdict.
                _muxRetryAt = DateTime.now().add(_muxRetryDelay);
                try {
                  await subscribe(_command, script: false);
                } on Object catch (e) {
                  if (out.isClosed) return;
                  _liveEvents.remove(fail);
                  out.addError(e);
                  await out.close();
                }
                return;
              }
              fail(failure);
            },
          );
        }

        try {
          final retryAt = _muxRetryAt;
          final scriptsDown = retryAt != null && DateTime.now().isBefore(retryAt);
          await (scriptsDown
              ? subscribe(_command, script: false)
              : subscribe(_eventsCommand, script: true));
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
    _files.discard();
    _noSftpUntil = null;
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
  late final Stream<String> lines = muxMessages(_session.stdout);

  @override
  void send(String line) => _session.stdin.add(utf8.encode('$line\n'));

  @override
  Future<void> close() async => _session.close();

  @override
  late final Future<int?> exitCode =
      _session.done.then((_) => _session.exitCode, onError: (Object _) => null);
}
