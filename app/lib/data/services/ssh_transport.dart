import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../app_info.dart';
import '../host/host_channels.dart';
import '../host/host_install.dart';
import '../host/host_files.dart';
import '../host/host_link.dart';
import '../host/host_transfer.dart';
import '../models/machine_profile.dart';
import '../models/remote_file.dart';
import '../models/remote_search.dart';
import '../models/web_bridge.dart';
import 'auth_notice.dart';
import 'bridge_command.dart';
import 'herdr_transport.dart';
import 'keeper_command.dart' show hostServeCommand, keeperInstallCommand;
import 'link_liveness.dart';
import 'mux_client.dart';
import 'remote_file_backend.dart';
import 'sftp_files.dart';
import 'web_bridge.dart';

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
const signInEndedMessage = 'The sign-in ended before it was approved. Retry to get a new link.';

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
    profile.auth == SshAuth.none && server != null && !server.toLowerCase().contains('tailscale');

/// A refused sign-in. [reason] is what the machine said (see
/// `refusalReasonFrom`): Tailscale SSH names its cause that way (a tailnet
/// policy that does not allow the user, a user the machine does not have), and
/// the person can act on it. Fatal: asking again gets the same answer.
HerdrTransportException signInRefused(MachineProfile profile, String? reason, {String? server}) {
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
    (true, null) =>
      'Tailscale SSH didn’t accept this sign-in. Check that '
          'Tailscale is connected on this phone and that your tailnet policy '
          'lets you SSH to this machine as "${profile.username}".',
    (false, null) => 'SSH authentication failed (check username and key/password).',
    (true, final r?) =>
      'Tailscale refused the sign-in: $r. Check the username '
          'and your tailnet’s SSH policy.',
    (false, final r?) =>
      'The machine refused the sign-in: $r. Check the '
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

/// [HerdrTransport] over SSH: one authenticated [SSHClient] per machine. The
/// machine's agent helper (`herdr-host serve`, see [hostLink]) carries the herdr
/// requests, the event subscriptions and the agent sessions on one channel;
/// requests share one multiplexed stream ([MuxClient]). A host without the
/// helper gets one bridge channel per request instead
/// ([buildBridgeCommand]), and each event subscription opens its own.
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
    Future<MuxChannel> Function()? openMuxChannel,
    Future<HostProcess> Function(String command)? openHostProcess,
    Duration Function()? livenessClock,
    Future<SftpApi> Function()? openSftp,
  }) : _connectClient = connectClient, // ignore: prefer_initializing_formals
       _openMuxChannel = openMuxChannel, // ignore: prefer_initializing_formals
       _openHostProcess = openHostProcess, // ignore: prefer_initializing_formals
       _livenessClock = livenessClock, // ignore: prefer_initializing_formals
       _openSftpApi = openSftp, // ignore: prefer_initializing_formals
       _command = buildBridgeCommand(session: profile.session, socketPath: profile.socketPath);

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

  /// Replace the real connection, the mux channel, the process that runs
  /// `herdr-host serve`, the SFTP session and the clock of the link watch; for
  /// tests. The
  /// connection is told to call `onInbound` for every chunk it receives, as the
  /// real socket does (proof of life, see [LinkLiveness]).
  final Future<SSHClient> Function(void Function() onInbound)? _connectClient;
  final Future<MuxChannel> Function()? _openMuxChannel;
  final Future<HostProcess> Function(String command)? _openHostProcess;
  final Duration Function()? _livenessClock;
  final Future<SftpApi> Function()? _openSftpApi;
  final String _command;
  late String? _pinned = profile.hostKeyFingerprint;
  Future<SSHClient>? _client;
  // The client [_client] resolved to, so [_drop] can forget it at once: a
  // call that follows a failed channel open must reconnect, not find the
  // client that was just given up on.
  SSHClient? _ready;
  MuxClient? _mux;
  Future<MuxClient>? _muxStart;
  HostLink? _host;
  Future<HostLink>? _hostStart;
  // After the helper could not be started (it is not installed and the install
  // failed, or the machine is of a kind it has no build for) the verdict stands
  // for this long, so no request runs the installer again; the board uses the
  // bridge meanwhile. A dropped connection is not a verdict.
  DateTime? _hostRetryAt;
  static const _hostRetryDelay = Duration(seconds: 30);
  // After a failed mux start (no helper on the host, or herdr's socket is not
  // there right now, e.g. herdr is restarting) requests use the slower bridge
  // channel until this instant, then the mux is tried again. Not permanent: a
  // missing socket is a transient condition, not a property of the host. An
  // event subscription the host refuses as unavailable sets it too, and takes
  // the bridge.
  DateTime? _muxRetryAt;
  static const _muxRetryDelay = Duration(seconds: 30);

  /// The window in which the host holds back repeats of a pane's update on an
  /// event stream (`coalesce_ms` of `herdr.events`).
  static const eventCoalesceMs = 250;

  // The helper is installed at most once per failure: every consumer that
  // started on a link which then exited 65 asks [_recoverHelper] with the
  // generation it started in, so concurrent ones (the mux, the events, a call)
  // share one install, and one that started after it is not run again.
  // [_installTried] holds from an install until a HELLO proves the helper is
  // there; a second 65 inside that window is the verdict (see [_stillMissing]).
  var _helperGen = 0;
  var _installTried = false;
  Future<void>? _recovery;
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
    final liveness = LinkLiveness(interval: t.linkInterval, timeout: t.linkTimeout, clock: _livenessClock);
    return _client = (_connectClient?.call(liveness.inbound) ?? _connect(liveness))
        .then((c) {
          _ready = c;
          _watchLink(c, liveness);
          return c;
        })
        .catchError((Object e) {
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
        await SSHSocket.connect(profile.host, profile.port, timeout: connectTimeout),
        liveness.inbound,
      );
      final List<SSHKeyPair>? identities;
      if (profile.auth == SshAuth.key) {
        final pem = secrets.privateKeyPem;
        if (pem == null || pem.isEmpty) {
          throw const HerdrTransportException('No private key saved for this machine.', fatal: true);
        }
        try {
          identities = SSHKeyPair.fromPem(pem, secrets.passphrase);
        } on Object {
          throw const HerdrTransportException(
            'Private key couldn’t be read (wrong passphrase, incomplete paste or unsupported format).',
            fatal: true,
          );
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
        onPasswordRequest: profile.auth == SshAuth.password ? () => secrets.password : null,
        onUserauthBanner: (banner) {
          onNotice?.call(banner);
          if (approvalUrlFrom(banner) != null) {
            approvalOffered = true;
            expectAuthWithin(
              approvalTimeout,
              const HerdrTransportException('Sign-in wasn’t approved in time. Retry to get a new link.', fatal: true),
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
      throw HerdrTransportException('Can’t connect: $e');
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
    current.then((c) => identical(c, client) ? reset() : client.close(), onError: (Object _) => client.close());
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
      throw HerdrTransportException('Can’t open channel: $e');
    }
  }

  @override
  Future<Object?> hostCall(
    String service,
    String method, [
    Map<String, Object?> args = const {},
    Duration? timeout,
  ]) async {
    final link = await hostLink();
    return link.call(service, method, args, timeout ?? requestTimeout);
  }

  @override
  Future<ExecChannel> openHostStream(String service, String method, [Map<String, Object?> args = const {}]) async {
    final link = await hostLink();
    // zctx: the host compresses the lines as one continuous stream.
    return HostLineChannel(link.open(service, method, args, true));
  }

  @override
  Stream<Object?> openHostMessages(String service, String method, [Map<String, Object?> args = const {}]) {
    HostStream? stream;
    StreamSubscription<Object?>? sub;
    var cancelled = false;
    late final StreamController<Object?> out;
    out = StreamController<Object?>(
      onListen: () async {
        try {
          final link = await hostLink();
          if (cancelled) return;
          // zctx: a watch repeats the shape of its last message.
          final s = stream = link.open(service, method, args, true);
          sub = s.messages.listen(out.add, onError: out.addError, onDone: () => unawaited(out.close()));
        } on Object catch (e) {
          if (cancelled || out.isClosed) return;
          out.addError(e);
          await out.close();
        }
      },
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
        stream?.reset();
      },
    );
    return out.stream;
  }

  /// Files: the agent helper's `fs` ([HostFiles], see [_backend]) or, on a machine
  /// without the helper, SFTP on the same authenticated connection: one cached
  /// session, reopened by [SftpFiles] when its channel dies.
  late final SftpFiles _sftp = SftpFiles(open: _openSftp);
  HostFiles? _hostFiles;

  /// How long a host may take to answer the sftp subsystem request before it
  /// is reported as not offering SFTP. Some sshd configs never answer.
  static const _sftpHandshakeTimeout = Duration(seconds: 5);

  /// After a host answered "no SFTP" the verdict stands for this long, so the
  /// next screen does not wait out the handshake timeout again.
  static const _noSftpMemory = Duration(minutes: 2);
  DateTime? _noSftpUntil;

  Future<SftpApi> _openSftp() async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final replaced = _openSftpApi;
    if (replaced != null) return replaced();
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
      throw HerdrTransportException('Can’t open channel: $e');
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
    'This host doesn’t allow SFTP, so its files can’t be shown. Enable the '
    '"sftp" subsystem in its sshd_config to use Files.',
  );

  @override
  bool get supportsFiles => true;

  /// Files come from the agent helper's `fs` service when the machine has it
  /// (one request and one answer, offset reads that check the file's identity,
  /// real change events) and over SFTP, read-only, when it has not. Decided at
  /// each call from the machine's one link, which is remembered (a machine
  /// without the helper is not asked again for a while): a reset or a lost link
  /// decides again.
  Future<RemoteFileBackend> _backend() async {
    final HostLink link;
    try {
      link = await hostLink();
    } on HostException catch (e) {
      if (_helperCannotBeHad(e)) return _sftp;
      throw HerdrTransportException(e.message);
    }
    if (!link.hello.has('fs')) return _sftp;
    final cached = _hostFiles;
    if (cached != null && identical(cached.link, link)) return cached;
    return _hostFiles = HostFiles(link);
  }

  /// The machine has no agent helper and cannot get one (unsupported kind of
  /// machine, offline, download blocked: the install failed, or that verdict
  /// is remembered), as opposed to a connection that is down or slow.
  static bool _helperCannotBeHad(HostException e) =>
      e is! HostLinkLost && (e.code == 'unavailable' || e.code == 'install_failed');

  /// The link to the helper for a write (an upload): without the helper there
  /// is nothing to write with, and the machine says so.
  Future<HostLink> _helperLink() async {
    try {
      return await hostLink();
    } on HostException catch (e) {
      if (_helperCannotBeHad(e)) {
        throw RemoteFileException(RemoteFileErrorKind.unsupported, needsHostHelper);
      }
      throw HerdrTransportException(e.message);
    }
  }

  @override
  Future<RemoteStat> statFile(String path) async => (await _backend()).stat(path);

  @override
  Future<List<RemoteEntry>> listDirectory(String path) async => (await _backend()).list(path);

  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap, RemoteStat? ifMatch}) async =>
      (await _backend()).read(path, offset, length.clamp(0, remoteReadCap), ifMatch: ifMatch);

  @override
  Future<String> realPath(String path) async => (await _backend()).realPath(path);

  @override
  Stream<RemoteStat?> watchFile(String path) async* {
    yield* (await _backend()).watch(path);
  }

  @override
  Future<Uint8List?> thumbnailFile(String path, {int maxPx = 256, RemoteStat? expect, Future<void>? cancelled}) async {
    try {
      return await (await _backend()).thumbnail(path, maxPx: maxPx, expect: expect, cancelled: cancelled);
    } on Object {
      // A thumbnail is a convenience: the caller has its own way without one.
      return null;
    }
  }

  @override
  Stream<FileSearchEvent> searchFiles(FileSearchSpec spec) async* {
    yield* (await _backend()).search(spec);
  }

  @override
  Future<String> reserveInboxFile({required String key, required String name}) async {
    final link = await _helperLink();
    if (!link.hello.has('transfer')) throw RemoteFileException(RemoteFileErrorKind.unsupported, needsHostHelper);
    return HostTransfer(link).reserve(key: key, name: name);
  }

  @override
  Future<int> sweepInbox() async {
    final link = await _helperLink();
    if (!link.hello.has('transfer')) throw RemoteFileException(RemoteFileErrorKind.unsupported, needsHostHelper);
    return HostTransfer(link).sweep();
  }

  @override
  UploadJob uploadFile({
    required String localPath,
    required String inboxPath,
    void Function(int sent, int total)? onProgress,
  }) => HostUpload(link: _helperLink(), localPath: localPath, inboxPath: inboxPath, onProgress: onProgress);

  String _frame(String method, Map<String, dynamic> params) =>
      '${jsonEncode({'id': 'm${_nextId++}', 'method': method, 'params': params})}\n';

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    while (true) {
      final gen = _helperGen;
      final mux = await _muxClient();
      if (mux == null) return _bridgeRequest(method, params);
      try {
        return await mux.request(method, params);
      } on MuxUnavailable catch (e) {
        // The mux never became ready: this request goes by the bridge, as the
        // ones after it do until [_muxRetryAt].
        if (e.linkLost) throw HerdrTransportException('Connection lost: $e');
        if (e.helperMissing) {
          // The request went out before the helper said it was missing: install
          // it once and send the request again on a new mux.
          try {
            await _recoverHelper(gen);
            continue;
          } on HostLinkLost catch (l) {
            throw HerdrTransportException('Connection lost: ${l.message}');
          } on HostException {
            // not installable: remembered in [_hostRetryAt]
          }
        }
        _muxRetryAt = DateTime.now().add(_muxRetryDelay);
        return _bridgeRequest(method, params);
      }
    }
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
    final MuxChannel channel;
    if (open != null) {
      channel = await open();
    } else {
      final HostLink link;
      try {
        // Started, not greeted: the OPEN and the first request leave behind our
        // HELLO without waiting for the host's.
        link = await startedLink();
      } on HostLinkLost catch (e) {
        throw MuxUnavailable(e.message, linkLost: true);
      } on HostException catch (e) {
        throw MuxUnavailable(e.message);
      }
      // zctx: requests repeat the same keys and answers repeat the same rows, so
      // a stream that remembers the last ones costs far less than frames that do
      // not (the python mux did this for requests, ~16 bytes each instead of ~150).
      channel = HostMuxChannel(
        link.open('herdr', 'mux', {
          'projections': muxProjections,
          'delta': {
            'min_chars': muxDeltaMin,
            'max_rows': muxDeltaRows,
            'keep': muxDeltaKeep,
            'keep_chars': muxDeltaChars,
          },
        }, true),
      );
    }
    final mux = await MuxClient.connect(
      channel,
      // Over the helper the client is returned before ready and requests go out
      // at once (see [MuxClient.connect]); the window covers the host's HELLO
      // and herdr's socket, as the old connect plus ready did.
      startupTimeout: open == null ? const Duration(seconds: 15) : const Duration(seconds: 5),
      waitForReady: open != null,
      requestTimeout: requestTimeout,
      heartbeatInterval: started.muxInterval,
      heartbeatTimeout: started.muxTimeout,
      clock: _livenessClock,
    );
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

  /// The machine's one hostwire link (`herdr-host serve` on one exec channel),
  /// started on first use and shared by every feature, with the host's HELLO
  /// in ([HostLink.hello]). When the helper is not on the host it is installed
  /// once and `serve` started again.
  ///
  /// Throws [HostException] when the helper cannot be had on this machine (the
  /// verdict is remembered for a while), [HostLinkLost] when the connection
  /// drops meanwhile, and [HerdrTransportException] when no channel can be
  /// opened.
  Future<HostLink> hostLink() async {
    while (true) {
      final gen = _helperGen;
      final link = await startedLink();
      try {
        await link.helloFuture;
        return link;
      } on HostMissing {
        await _recoverHelper(gen);
      }
    }
  }

  /// The machine's link as soon as its channel is open, before the host's HELLO
  /// (see [HostLink.start]): for consumers that open their stream at once and
  /// take its failure ([HostMissing] among them, see [_recoverHelper]) from the
  /// stream. Throws as [hostLink] does for a verdict already in force.
  Future<HostLink> startedLink() async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final live = _host;
    if (live != null && live.isOpen) return live;
    final retryAt = _hostRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) {
      throw const HostException('unavailable', 'The agent helper is not available on this machine.');
    }
    return _hostStart ??= _startHost().whenComplete(() => _hostStart = null);
  }

  Future<HostProcess> _processFor(String command) async {
    final open = _openHostProcess;
    if (open != null) return open(command);
    return _SshSessionAdapter(await _open(command));
  }

  Future<HostLink> _startHost() async {
    final epoch = _epoch;
    final process = await _processFor(hostServeCommand());
    if (epoch != _epoch) {
      process.close();
      throw const HerdrTransportException('Connection reset');
    }
    final link = HostLink.start(
      process,
      version: appVersion,
      herdrSession: profile.session,
      herdrSocket: profile.socketPath,
    );
    _host = link;
    unawaited(
      link.closed.then((_) {
        if (identical(_host, link)) _host = null;
      }),
    );
    unawaited(
      link.helloFuture.then<void>(
        (_) {
          if (epoch != _epoch) return;
          _hostRetryAt = null;
          _installTried = false;
        },
        onError: (Object e) {
          // A refusal or a failed start is a verdict for a while; a dropped
          // connection, silence and a missing helper (installed by
          // [_recoverHelper]) are not.
          if (epoch != _epoch || e is! HostException) return;
          if (e is HostLinkLost || e is HostMissing || e.code == 'timeout' || e.code == 'cancelled') return;
          _hostRetryAt = DateTime.now().add(_hostRetryDelay);
        },
      ),
    );
    return link;
  }

  /// Installs the helper after a link exited 65. [gen] is the generation the
  /// failed consumer started in: a newer one means an install already ran since,
  /// and the consumer only starts again. Throws [HostException]: the install's
  /// failure, or the verdict ([_stillMissing]) when a second 65 follows an
  /// install.
  Future<void> _recoverHelper(int gen) async {
    if (_helperGen != gen) return;
    final running = _recovery;
    if (running != null) return running;
    if (_installTried) throw _stillMissing();
    return _recovery = _installHelper().whenComplete(() => _recovery = null);
  }

  Future<void> _installHelper() async {
    try {
      await installHostHelper(await _processFor(keeperInstallCommand()));
    } on HostLinkLost {
      rethrow;
    } on HostException catch (e) {
      if (e.code != 'timeout') _hostRetryAt = DateTime.now().add(_hostRetryDelay);
      rethrow;
    }
    _installTried = true;
    _helperGen++;
  }

  /// The helper is missing again right after it was installed: the machine
  /// cannot have it. Remembered for [_hostRetryDelay]; the next try after that
  /// installs again.
  HostException _stillMissing() {
    _installTried = false;
    _hostRetryAt = DateTime.now().add(_hostRetryDelay);
    return const HostException('unavailable', 'The agent helper is still missing on this machine after installing it.');
  }

  Future<Map<String, dynamic>> _bridgeRequest(String method, Map<String, dynamic> params) async {
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
        throw HerdrTransportException('herdr didn’t answer $method in time');
      }
      return unwrapResponse(line);
    } finally {
      session.close();
    }
  }

  Future<HerdrTransportException> _bridgeFailure(SSHSession session, Future<String> stderr) async {
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
    HostStream? hostStream;
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
      hostStream?.reset();
    }

    Future<void> endWith(Object error) async {
      if (out.isClosed) return;
      _liveEvents.remove(fail);
      out.addError(error);
      await out.close();
    }

    // The events of one subscription: herdr's acknowledgement first, then each
    // event. Returns false for a line that is not one.
    var acked = false;
    void onLine(String line) {
      try {
        if (!acked) {
          unwrapResponse(line); // throws on API error
          acked = true;
          out.add(const {'event': subscriptionStartedEvent});
          return;
        }
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) out.add(decoded);
      } on Object catch (e) {
        out.addError(e);
      }
    }

    // One channel per subscription through the bridge command, for a host
    // without the helper (or while herdr's socket is not there for it).
    Future<void> subscribeBridge() async {
      final s = session = await _open(_command);
      if (out.isClosed || cancelled) {
        s.close();
        return;
      }
      final stderr = utf8.decodeStream(s.stderr).catchError((Object _) => '');
      s.stdin.add(utf8.encode(_frame('events.subscribe', {'subscriptions': subscriptions})));
      sub = jsonLines(s.stdout)
          .listen(onLine, onError: out.addError, onDone: () async => fail(await _bridgeFailure(s, stderr)));
    }

    // The subscription on the machine's hostwire link, opened before the host's
    // HELLO (see [HostLink.start]). [gen] is the install generation a retry
    // after a missing helper starts from.
    Future<void> subscribeHost() async {
      final gen = _helperGen;
      final HostLink link;
      try {
        link = await startedLink();
      } on HostLinkLost catch (e) {
        throw HerdrTransportException('Connection lost: ${e.message}');
      } on HostException {
        // No helper here: the bridge can still carry it.
        _muxRetryAt = DateTime.now().add(_muxRetryDelay);
        await subscribeBridge();
        return;
      }
      if (out.isClosed || cancelled) return;
      final s = hostStream = link.open('herdr', 'events', {
        'subscriptions': subscriptions,
        'projection': eventProjection,
        // The host holds back repeats of a pane's update inside this window
        // (0 = every event as it comes).
        'coalesce_ms': eventCoalesceMs,
      }, true);
      sub = s.texts.listen(
        onLine,
        onError: (Object e) async {
          final usable = !acked && !out.isClosed && !cancelled;
          if (e is HostMissing && usable) {
            // The subscription went out before the helper said it was missing:
            // install it once and subscribe again; no helper after that, the
            // bridge asks herdr itself.
            hostStream = null;
            try {
              await _recoverHelper(gen);
              if (out.isClosed || cancelled) return;
              await subscribeHost();
            } on HostLinkLost catch (l) {
              await endWith(HerdrTransportException('Connection lost: ${l.message}'));
            } on HostException {
              _muxRetryAt = DateTime.now().add(_muxRetryDelay);
              try {
                await subscribeBridge();
              } on Object catch (e) {
                await endWith(e);
              }
            } on Object catch (e) {
              await endWith(e);
            }
            return;
          }
          if (e is HostException && e.code == 'unavailable' && usable) {
            // herdr's socket is not there for the helper (herdr restarting):
            // the bridge asks herdr itself.
            hostStream = null;
            _muxRetryAt = DateTime.now().add(_muxRetryDelay);
            try {
              await subscribeBridge();
            } on Object catch (e) {
              await endWith(e);
            }
            return;
          }
          fail(HerdrTransportException(e is HostException ? e.message : '$e'));
        },
        onDone: () {
          if (!out.isClosed && !cancelled && hostStream == s) {
            fail(const HerdrTransportException('The event stream closed'));
          }
        },
      );
    }

    out = StreamController<Map<String, dynamic>>(
      onListen: () async {
        _liveEvents.add(fail);
        try {
          final retryAt = _muxRetryAt;
          final helperDown = retryAt != null && DateTime.now().isBefore(retryAt);
          await (helperDown ? subscribeBridge() : subscribeHost());
        } on Object catch (e) {
          await endWith(e);
        }
      },
      onCancel: () async {
        cancelled = true;
        _liveEvents.remove(fail);
        await sub?.cancel();
        session?.close();
        hostStream?.reset();
      },
    );
    return out.stream;
  }

  @override
  void reset() => unawaited(_teardown());

  /// The loopback listeners for pages (see [WebBridgeHost]). Files come from
  /// the same backend as the file viewer ([_backend]); a forward is a new channel
  /// on the one authenticated connection, never a connection of its own.
  late final WebBridgeHost _web = WebBridgeHost(
    stat: statFile,
    read: (path, offset, length) => readFile(path, offset: offset, length: length),
    dial: _dialForward,
  );

  Future<SSHSocket> _dialForward(String host, int port) async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final client = await _connected();
    try {
      return await client.forwardLocal(host, port);
    } on SSHChannelOpenError catch (e) {
      throw forwardRefusal(e);
    } on Object catch (e) {
      _drop(client);
      client.close();
      throw HerdrTransportException('Can’t open channel: $e');
    }
  }

  @override
  Future<WebBridgeInfo> openWebBridge(WebBridgeSpec spec) => _web.open(spec);

  @override
  Future<void> close() {
    _closed = true;
    return Future.wait([_teardown(), _web.close()]);
  }

  /// Synchronously invalidates the mux, event streams and SSH client (so
  /// in-flight work fails right away), then closes the client.
  Future<void> _teardown() async {
    _sftp.discard();
    _hostFiles = null;
    _noSftpUntil = null;
    _epoch++;
    final mux = _mux;
    _mux = null;
    final host = _host;
    _host = null;
    _hostRetryAt = null;
    _installTried = false;
    final pending = _client;
    _client = null;
    _ready = null;
    for (final fail in [..._liveEvents]) {
      fail(const HerdrTransportException('Connection reset'));
    }
    mux?.close();
    unawaited(host?.close());
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
      'Too many sessions are open on this machine (sshd MaxSessions). Close a '
      'session and retry.',
    );
  }
  return HerdrTransportException('The machine would not open a channel: ${error.description}');
}

/// Why `direct-tcpip` (a port forward) was refused. Code 1 is the host's
/// policy (`AllowTcpForwarding no`, a Tailscale SSH policy): fatal, because
/// retrying cannot help and the person has to be told. Code 2 is the target
/// itself refusing (nothing listens on that port): not fatal, the page the
/// browser gets says so and a server that starts later works.
HerdrTransportException forwardRefusal(SSHChannelOpenError error) {
  if (error.code == 1) {
    return const HerdrTransportException('the machine doesn’t allow port forwarding', fatal: true);
  }
  return HerdrTransportException('The machine couldn’t reach that port: ${error.description}');
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

/// The SSH exec channel as the [HostProcess] of `herdr-host serve`.
class _SshSessionAdapter implements HostProcess {
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
