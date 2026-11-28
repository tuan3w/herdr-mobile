import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:herdr_mobile/data/host/host_channels.dart';
import 'package:herdr_mobile/data/host/host_link.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

/// A local child process as the [HostProcess] of a [HostLink]: what an SSH exec
/// channel is to the app, a `Process` is to a test. The real `herdr-host serve`
/// (or the app's `hostServeCommand()` under `sh -c`, which is what an SSH
/// server would run) sits at the other end.
class ProcessHostProcess implements HostProcess {
  ProcessHostProcess(this.process) {
    done = process.exitCode.then((code) => _exit = code);
  }

  /// Starts [executable] with [arguments]; [environment] is all it gets.
  static Future<ProcessHostProcess> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    String? workingDirectory,
  }) async => ProcessHostProcess(
    await Process.start(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: false,
      workingDirectory: workingDirectory,
    ),
  );

  final Process process;
  int? _exit;

  @override
  late final Stream<Uint8List> stdout = process.stdout.map(_bytes);

  @override
  late final Stream<Uint8List> stderr = process.stderr.map(_bytes);

  @override
  late final StreamSink<Uint8List> stdin = _Stdin(process.stdin);

  @override
  late final Future<void> done;

  @override
  int? get exitCode => _exit;

  /// Ends the channel: the process sees end of input and exits, and is killed
  /// when it does not within a few seconds.
  @override
  void close() {
    unawaited(stdin.close().catchError((Object _) {}));
    unawaited(
      process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process.kill();
          return -1;
        },
      ),
    );
  }

  /// The connection dies without a word (the process is killed outright).
  void kill() => process.kill(ProcessSignal.sigkill);

  static Uint8List _bytes(List<int> chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
}

class _Stdin implements StreamSink<Uint8List> {
  _Stdin(this._sink);

  final IOSink _sink;

  @override
  void add(Uint8List data) => _sink.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _sink.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<Uint8List> stream) => _sink.addStream(stream);

  @override
  Future<void> close() => _sink.close();

  @override
  Future<void> get done => _sink.done;
}

/// A [HerdrTransport] whose only abilities are [hostCall] and [openHostStream],
/// over the [HostLink] [link] hands out: what `SshAgentHost` and the log source
/// need of a machine, with the real binary behind it. [link] is asked for again
/// whenever the previous one is closed (the way the app's transport reconnects).
/// Everything else throws [UnsupportedError].
class LinkTransport implements HerdrTransport {
  LinkTransport(this.link);

  final Future<HostLink> Function() link;

  @override
  Future<Object?> hostCall(
    String service,
    String method, [
    Map<String, Object?> args = const {},
    Duration? timeout,
  ]) async => (await link()).call(service, method, args, timeout ?? const Duration(seconds: 20));

  @override
  Future<ExecChannel> openHostStream(String service, String method, [Map<String, Object?> args = const {}]) async =>
      HostLineChannel((await link()).open(service, method, args, true));

  @override
  Stream<Object?> openHostMessages(String service, String method, [Map<String, Object?> args = const {}]) {
    HostStream? stream;
    StreamSubscription<Object?>? sub;
    late final StreamController<Object?> out;
    out = StreamController<Object?>(
      onListen: () async {
        try {
          final s = stream = (await link()).open(service, method, args, true);
          sub = s.messages.listen(out.add, onError: out.addError, onDone: () => unawaited(out.close()));
        } on Object catch (e) {
          out.addError(e);
          await out.close();
        }
      },
      onCancel: () async {
        await sub?.cancel();
        stream?.reset();
      },
    );
    return out.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('LinkTransport: ${invocation.memberName}');
}
