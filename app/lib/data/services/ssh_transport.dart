import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../acp/json_rpc.dart' show splitLines;
import '../models/machine_profile.dart';
import '../models/remote_file.dart';
import 'auth_notice.dart';
import 'bridge_command.dart';
import 'herdr_transport.dart';
import 'zipped_exec_channel.dart';
import 'link_liveness.dart';
import 'mux_client.dart';
import 'sftp_files.dart';

/// Thrown (wrapped in [HerdrTransportException]) when a pinned host key no
/// longer matches.
const hostKeyChangedMessage =
    'Host key changed since it was first trusted. Re-add the machine if the '
    'change is expected.';

/// What to do with the host key a machine presented.
enum HostKeyVerdict {
  /// Nothing is pinned yet: trust this key and remember it (the one moment a
  /// key is taken on trust).
  trustFirstUse,

  /// The pinned key. Go on.
  matches,

  /// Not the pinned key: a hard stop, never a re-pin. Only the person
  /// re-adding the machine accepts a new key.
  changed,
}

/// Judges the host key [seen] against the [pinned] one (null: none yet).
HostKeyVerdict judgeHostKey({required String? pinned, required String seen}) {
  if (pinned == null) return HostKeyVerdict.trustFirstUse;
  return pinned == seen ? HostKeyVerdict.matches : HostKeyVerdict.changed;
}

/// The server hung up after showing a sign-in link, so the link was refused,
/// expired, or the connection dropped while waiting. Fatal: each retry would
/// issue a new link and another prompt.
const signInEndedMessage =
    'The sign-in ended before it was approved. Retry to get a new link.';

/// The server closed the connection during login without saying why.
const closedBeforeSignInMessage =
    'The machine closed the connection before sign-in finished. Check the '
    'username and that SSH is allowed for it.';

/// Whether [profile] asks for Tailscale SSH (no credentials) but the machine
/// answered as another SSH server. [server] is its identification string
/// (`SSH-2.0-Tailscale` for Tailscale SSH, `SSH-2.0-OpenSSH_10.3` for a Mac's
/// Remote Login). No credentials can sign in there, so the cause is the
/// choice of sign-in, not a policy.
bool answeredByAnotherServer(MachineProfile profile, String? server) =>
    profile.auth == SshAuth.none &&
    server != null &&
    !server.toLowerCase().contains('tailscale');

/// A refused sign-in. [reason] is what the machine said (see
/// `refusalReasonFrom`): Tailscale SSH names its cause that way (a tailnet
/// policy that does not allow the user, a user the machine does not have), and
/// the person can act on it. Fatal: asking again gets the same answer.
HerdrTransportException signInRefused(
  MachineProfile profile,
  String? reason, {
  String? server,
}) {
  if (answeredByAnotherServer(profile, server)) {
    // The Tailscale apps for macOS cannot run Tailscale SSH, so a Mac reached
    // over Tailscale answers as plain OpenSSH. Its name is the machine's text.
    final name = refusalReasonFrom(server!.replaceFirst(RegExp(r'^SSH-\d\.\d+-'), ''));
    return HerdrTransportException(
      'This machine runs a regular SSH server${name == null ? '' : ' ($name)'}, '
      'not Tailscale SSH. Choose Private key or Password for it.',
      fatal: true,
    );
  }
  final tailscale = profile.auth == SshAuth.none;
  final message = switch ((tailscale, reason)) {
    (true, null) => 'Tailscale SSH did not accept this sign-in. Check that '
        'Tailscale is connected on this phone and that your tailnet policy '
        'lets you SSH to this machine as "${profile.username}".',
    (false, null) => 'SSH authentication failed (check username and key/password).',
    (true, final r?) => 'Tailscale refused the sign-in: $r. Check the username '
        'and your tailnet\'s SSH policy.',
    (false, final r?) => 'The machine refused the sign-in: $r. Check the '
        'username and key/password.',
  };
  return HerdrTransportException(message, fatal: true);
}

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
    Future<SSHClient> Function(void Function() onInbound)? connectClient,
    Future<MuxChannel> Function(String command)? openMuxChannel,
    Duration Function()? livenessClock,
  })  : _connectClient = connectClient, // ignore: prefer_initializing_formals
        _openMuxChannel = openMuxChannel, // ignore: prefer_initializing_formals
        _livenessClock = livenessClock, // ignore: prefer_initializing_formals
        _command = buildBridgeCommand(
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

  /// Replace the real connection, the mux channel and the clock of the link
  /// watch; for tests. The connection is told to call `onInbound` for every
  /// chunk it receives, as the real socket does (proof of life, see
  /// [LinkLiveness]).
  final Future<SSHClient> Function(void Function() onInbound)? _connectClient;
  final Future<MuxChannel> Function(String command)? _openMuxChannel;
  final Duration Function()? _livenessClock;
  final String _command;
  final String _muxCommand;
  final String _eventsCommand;
  late String? _pinned = profile.hostKeyFingerprint;
  Future<SSHClient>? _client;
  // The client [_client] resolved to, so [_drop] can forget it at once: a
  // call that follows a failed channel open must reconnect, not find the
  // client that was just given up on.
  SSHClient? _ready;
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

  Future<SSHClient> _connected() {
    final existing = _client;
    if (existing != null) return existing;
    final t = _timing;
    final liveness = LinkLiveness(
      interval: t.linkInterval,
      timeout: t.linkTimeout,
      clock: _livenessClock,
    );
    return _client = (_connectClient?.call(liveness.inbound) ?? _connect(liveness)).then((c) {
      _ready = c;
      _watchLink(c, liveness);
      return c;
    }).catchError((Object e) {
      _client = null;
      throw e;
    });
  }

  Future<SSHClient> _connect(LinkLiveness liveness) async {
    var hostKeyMismatch = false;
    // What the machine said when it refused, and whether it offered a sign-in
    // link: a failed login says nothing itself, so these name the cause.
    String? refusal;
    var approvalOffered = false;
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
      final socket = _ActivitySocket(
        await SSHSocket.connect(
          profile.host,
          profile.port,
          timeout: connectTimeout,
        ),
        liveness.inbound,
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
              'Private key could not be read (wrong passphrase, incomplete paste or unsupported format).',
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
        // dartssh2's own keep-alive ignores a ping that is never answered, so
        // it cannot notice a half-dead link; [_watch] does.
        keepAliveInterval: null,
        // With neither a key nor a password only the `none` method is tried,
        // which is what Tailscale SSH expects: it already knows who we are.
        onPasswordRequest:
            profile.auth == SshAuth.password ? () => secrets.password : null,
        onUserauthBanner: (banner) {
          onNotice?.call(banner);
          if (approvalUrlFrom(banner) != null) {
            approvalOffered = true;
            expectAuthWithin(
              approvalTimeout,
              const HerdrTransportException(
                'Sign-in was not approved in time. Retry to get a new link.',
                fatal: true,
              ),
            );
          } else {
            refusal = refusalReasonFrom(banner) ?? refusal;
          }
        },
        onVerifyHostKey: (type, fingerprint) {
          final seen = utf8.decode(fingerprint);
          switch (judgeHostKey(pinned: _pinned, seen: seen)) {
            case HostKeyVerdict.trustFirstUse:
              _pinned = seen;
              onPinHostKey(seen);
              return true;
            case HostKeyVerdict.matches:
              return true;
            case HostKeyVerdict.changed:
              hostKeyMismatch = true;
              return false;
          }
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
      return client;
    } on HerdrTransportException {
      client?.close();
      rethrow;
    } on SSHAuthFailError {
      final server = client?.remoteVersion;
      client?.close();
      throw signInRefused(profile, refusal, server: server);
    } on Object catch (e) {
      final server = client?.remoteVersion;
      client?.close();
      if (hostKeyMismatch) {
        throw const HerdrTransportException(hostKeyChangedMessage, fatal: true);
      }
      // The machine hung up before the login ended and the socket did not fail:
      // it said no (a Tailscale policy, a link that was never approved).
      if (e is SSHAuthAbortError && e.reason == null) {
        if (approvalOffered) throw const HerdrTransportException(signInEndedMessage, fatal: true);
        if (refusal != null || answeredByAnotherServer(profile, server)) {
          throw signInRefused(profile, refusal, server: server);
        }
        throw const HerdrTransportException(closedBeforeSignInMessage);
      }
      throw HerdrTransportException('Cannot connect: $e');
    } finally {
      deadline?.cancel();
    }
  }

  /// Whether the app is in the background (see [setBackground]); kept across
  /// reconnects, so a new connection starts with the right intervals.
  var _background = false;
  LinkWatch? _linkWatch;

  LivenessTiming get _timing => LivenessTiming.of(background: _background);

  @override
  void setBackground(bool background) {
    if (background == _background) return;
    _background = background;
    final t = _timing;
    // Back in the foreground: test the link now (a link that died while the
    // app was away must show in seconds), both the connection and the mux.
    _linkWatch?.configure(t.linkInterval, t.linkTimeout, checkNow: !background);
    _mux?.setHeartbeat(t.muxInterval, t.muxTimeout, beatNow: !background);
  }

  /// Watches [client]: only an idle link is pinged (any inbound byte counts,
  /// see [LinkLiveness]), and one that stays silent after a ping is dead, so
  /// the whole connection is reset and every channel on it ends instead of
  /// waiting for TCP to give up (minutes). In the foreground that costs one
  /// small packet each way per 25 s on an idle link; 25 s is also under the
  /// 30-60 s a mobile NAT keeps an idle mapping, so the ping doubles as its
  /// keep-alive. The timings are [LivenessTiming]'s.
  void _watchLink(SSHClient client, LinkLiveness liveness) {
    final watch = LinkWatch(
      liveness: liveness,
      ping: client.ping,
      onDead: () => _declareDead(client),
      isClosed: () => client.isClosed,
    )..start();
    _linkWatch = watch;
    void ended() {
      watch.stop();
      if (identical(_linkWatch, watch)) _linkWatch = null;
      _drop(client);
    }

    client.done.then((_) => ended(), onError: (Object _) => ended());
  }

  void _declareDead(SSHClient client) {
    final current = _client;
    if (current == null) {
      client.close();
      return;
    }
    current.then(
      (c) => identical(c, client) ? reset() : client.close(),
      onError: (Object _) => client.close(),
    );
  }

  void _drop(SSHClient client) {
    // Only forget the client if it is still the current one.
    if (!identical(_ready, client)) return;
    _client = null;
    _ready = null;
  }

  Future<SSHSession> _open(String command) async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final client = await _connected();
    try {
      return await client.execute(command);
    } on Object catch (e) {
      // A host that refuses one more channel is full, not broken: the
      // connection and every channel on it stay.
      final refused = channelRefusal(e);
      if (refused != null) throw refused;
      _drop(client);
      client.close();
      throw HerdrTransportException('Cannot open channel: $e');
    }
  }

  @override
  Future<ExecChannel> openExec(String command, {bool zipped = false}) async {
    final channel = SshExecChannel(_SshSessionAdapter(await _open(command)));
    return zipped ? ZippedExecChannel(channel) : channel;
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

  @override
  Future<void> makeDirs(String path) => _files.makeDirs(path);

  @override
  Future<void> removeFile(String path) => _files.remove(path);

  @override
  UploadJob uploadFile({
    required String localPath,
    required String remotePath,
    void Function(int sent, int total)? onProgress,
  }) => _files.upload(localPath, remotePath, onProgress: onProgress);

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
    // A mux that is up is used whatever the timer says: the timer is set by a
    // failed start, and also by an event script that found no socket.
    final live = _mux;
    if (live != null && live.isAlive) return live;
    final retryAt = _muxRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return null;
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
    final started = _timing;
    final open = _openMuxChannel;
    final MuxChannel channel =
        open != null ? await open(_muxCommand) : _SshMuxChannel(await _open(_muxCommand));
    final mux = await MuxClient.connect(channel,
        requestTimeout: requestTimeout,
        heartbeatInterval: started.muxInterval,
        heartbeatTimeout: started.muxTimeout,
        clock: _livenessClock);
    if (epoch != _epoch) {
      mux.close();
      throw const HerdrTransportException('Connection reset');
    }
    // The app may have changed sides while the mux was starting.
    final now = _timing;
    if (!identical(now, started)) mux.setHeartbeat(now.muxInterval, now.muxTimeout);
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
    // The consumer cancelled: no channel may be opened for it any more.
    var cancelled = false;
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
          if (out.isClosed || cancelled) {
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
              if (script && !acked && failure.fatal && !out.isClosed && !cancelled) {
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
        cancelled = true;
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
    _ready = null;
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

/// A host that refuses one more channel is full, not broken. sshd's
/// `MaxSessions` (default 10) counts every exec and subsystem channel on a
/// connection (the mux, the events, SFTP and each agent attach), and answers
/// the next open with "administratively prohibited" or "resource shortage".
/// That fails the one channel, with words for a person; the connection and
/// everything else on it stay. Null for any other error.
HerdrTransportException? channelRefusal(Object error) {
  if (error is! SSHChannelOpenError) return null;
  // RFC 4254 reason codes: 1 administratively prohibited, 4 resource shortage.
  if (error.code == 1 || error.code == 4) {
    return const HerdrTransportException(
      'Too many sessions are open on this host (sshd MaxSessions). Close a '
      'session and try again.',
    );
  }
  return HerdrTransportException('The host would not open a channel: ${error.description}');
}

/// [SSHSocket] that tells `onData` about every inbound chunk: proof of life
/// for [LinkLiveness]. It adds no pause/resume handling of its own.
class _ActivitySocket implements SSHSocket {
  _ActivitySocket(this._inner, void Function() onData)
      : stream = _inner.stream.map((chunk) {
          onData();
          return chunk;
        });

  final SSHSocket _inner;

  @override
  final Stream<Uint8List> stream;

  @override
  StreamSink<List<int>> get sink => _inner.sink;

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();

  @override
  void destroy() => _inner.destroy();

  @override
  Future<void> flush() => _inner.flush();
}

/// What [SshExecChannel] needs of an SSH session; [SSHSession] cannot be
/// faked, so the channel works against this.
abstract interface class ExecSession {
  Stream<Uint8List> get stdout;
  Stream<Uint8List> get stderr;
  StreamSink<Uint8List> get stdin;

  /// Completes when the channel is closed (errors if the connection died).
  Future<void> get done;

  /// The remote status; null when killed by a signal, or not known.
  int? get exitCode;
  void close();
}

class _SshSessionAdapter implements ExecSession {
  _SshSessionAdapter(this._session);

  final SSHSession _session;

  @override
  Stream<Uint8List> get stdout => _session.stdout;

  @override
  Stream<Uint8List> get stderr => _session.stderr;

  @override
  StreamSink<Uint8List> get stdin => _session.stdin;

  @override
  Future<void> get done => _session.done;

  @override
  int? get exitCode => _session.exitCode;

  @override
  void close() => _session.close();
}

/// [ExecChannel] over one SSH exec channel ([ExecSession]).
class SshExecChannel implements ExecChannel {
  SshExecChannel(this._session) {
    // Unread stderr would stall the channel's flow control; keep its tail.
    _session.stderr.listen(
      _onStderr,
      onError: (Object _) {},
      onDone: _stderrDone.complete,
    );
    _exitCode = Future.wait<Object?>([
      _session.done.then<Object?>((_) => null, onError: (Object _) => null),
      _stderrDone.future,
    ]).then((_) {
      _ended = true;
      return _session.exitCode;
    });
  }

  /// How much of stderr [stderrTail] keeps.
  static const tailBytes = 2048;

  final ExecSession _session;
  final _stderrDone = Completer<void>();
  final _stderr = BytesBuilder(copy: false);
  late final Future<int?> _exitCode;
  Future<void>? _closing;
  var _closed = false;
  var _ended = false;

  void _onStderr(Uint8List chunk) {
    _stderr.add(chunk);
    // Trimmed in steps so a chatty command does not copy per chunk.
    if (_stderr.length > tailBytes * 2) {
      final all = _stderr.takeBytes();
      _stderr.add(Uint8List.sublistView(all, all.length - tailBytes));
    }
  }

  // Set once the command's input has been (or is being) closed.
  Future<void>? _inputClosing;

  // Synchronous splitting, never `await for`: see [splitLines].
  @override
  late final Stream<String> lines = splitLines(_session.stdout);

  @override
  void send(String line) {
    if (_closed || _inputClosing != null) throw StateError('exec channel closed');
    if (_ended) return;
    _session.stdin.add(utf8.encode('$line\n'));
  }

  @override
  Future<void> closeInput() => _inputClosing ??= _endInput(const Duration(seconds: 10));

  Future<void> _endInput(Duration limit) async {
    if (_ended) return;
    // Everything sent so far is flushed, then the command sees end of input.
    try {
      await _session.stdin.close().timeout(limit);
    } on Object {
      // the channel is already gone or stuck; closing it ends both
    }
  }

  @override
  Future<int?> get exitCode => _exitCode;

  @override
  String get stderrTail {
    final all = _stderr.toBytes();
    final tail = all.length > tailBytes ? Uint8List.sublistView(all, all.length - tailBytes) : all;
    return utf8.decode(tail, allowMalformed: true).trim();
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    await (_inputClosing ??= _endInput(const Duration(seconds: 2)));
    _session.close();
  }
}

/// [MuxChannel] over one SSH exec channel.
class _SshMuxChannel implements MuxChannel {
  _SshMuxChannel(this._session) {
    // Unread stderr would stall the channel's flow control.
    _session.stderr.listen((_) {}, onError: (Object _) {});
  }

  final SSHSession _session;
  final _requests = MuxRequestEncoder();

  @override
  late final Stream<String> lines = muxMessages(_session.stdout);

  @override
  void send(String line) => _session.stdin.add(Uint8List.fromList(_requests.frame(line)));

  @override
  Future<void> close() async => _session.close();

  @override
  late final Future<int?> exitCode =
      _session.done.then((_) => _session.exitCode, onError: (Object _) => null);
}
