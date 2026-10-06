import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:herdr_mobile/data/services/sftp_files.dart';

/// A file the fake server holds.
class FakeRemote {
  FakeRemote(this.mode);

  int mode;
  Uint8List bytes = Uint8List(0);
  int length = 0;
  bool closed = false;

  void writeAt(int offset, Uint8List data, {required bool keep}) {
    final end = offset + data.length;
    if (end > length) length = end;
    if (!keep) return;
    if (bytes.length < end) {
      final grown = Uint8List(math.max(end, bytes.length * 2));
      grown.setRange(0, bytes.length, bytes);
      bytes = grown;
    }
    bytes.setRange(offset, end, data);
  }

  Uint8List get content => Uint8List.sublistView(bytes, 0, math.min(length, bytes.length));
}

/// An SFTP server in memory for upload tests. Writes are answered like a real
/// link: serialised on one wire of [bytesPerSecond] (when set) and [rtt] late;
/// a request sent while the wire is busy (a `stat` behind a full window of
/// writes) waits for it. The bytes of a write are copied when it is
/// ANSWERED, so a client that refills a buffer too early corrupts the file and
/// the test sees it.
class FakeSftpServer implements SftpApi {
  FakeSftpServer({this.rtt = Duration.zero, this.bytesPerSecond, this.keepBytes = true}) {
    dirs['/'] = 0x41ED;
    dirs['/home'] = 0x41ED;
    dirs['/home/dev'] = 0x41ED;
  }

  final Duration rtt;
  final int? bytesPerSecond;
  final bool keepBytes;

  final files = <String, FakeRemote>{};
  final dirs = <String, int>{};
  final calls = <String>[];

  /// Writes sent and not yet answered, now and at most.
  int outstanding = 0;
  int maxOutstanding = 0;
  int writeCount = 0;
  int bytesReceived = 0;

  /// While set, write answers wait for it.
  Completer<void>? ackGate;

  /// While set, `stat` waits for it (a browse request in flight).
  Completer<void>? statGate;

  /// After this many writes every write fails like a dead link.
  int? dieAfterWrites;

  /// Writes after this many are never answered.
  int? hangAfterWrites;

  /// Answers `openForWrite` with this.
  Object? openError;

  final _clock = Stopwatch()..start();
  int _wireFreeUs = 0;

  /// Microseconds until a request of [bytes] is answered, queued behind what
  /// the wire already carries.
  int _answerInUs(int bytes) {
    final now = _clock.elapsedMicroseconds;
    final start = math.max(now, _wireFreeUs);
    final sendUs = bytesPerSecond == null ? 0 : bytes * 1000000 ~/ bytesPerSecond!;
    _wireFreeUs = start + sendUs;
    return _wireFreeUs + rtt.inMicroseconds - now;
  }

  Future<void> _wait(int us) => us <= 0 ? Future.value() : Future<void>.delayed(Duration(microseconds: us));

  @override
  Future<SftpUploadFile> openForWrite(String path) async {
    calls.add('open $path');
    await _wait(_answerInUs(64));
    if (openError != null) throw openError!;
    final parent = path.substring(0, math.max(1, path.lastIndexOf('/')));
    if (!dirs.containsKey(parent)) throw SftpStatusError(2, 'No such file');
    final file = files[path] = FakeRemote(0x81A4); // umask mode until narrowed
    // dartssh2's DartSftp narrows it right after the open.
    file.mode = 0x8180;
    return _Handle(this, path, file);
  }

  @override
  Future<void> mkdir(String path) async {
    calls.add('mkdir $path');
    await _wait(_answerInUs(64));
    final parent = path.substring(0, math.max(1, path.lastIndexOf('/')));
    if (!dirs.containsKey(parent)) throw SftpStatusError(2, 'No such file');
    if (dirs.containsKey(path) || files.containsKey(path)) throw SftpStatusError(4, 'Failure');
    dirs[path] = 0x41C0;
  }

  @override
  Future<void> remove(String path) async {
    calls.add('remove $path');
    await _wait(_answerInUs(64));
    if (files.remove(path) == null) throw SftpStatusError(2, 'No such file');
  }

  @override
  Future<SftpFileAttrs> stat(String path, {bool followLink = true}) async {
    calls.add('stat $path');
    await statGate?.future;
    await _wait(_answerInUs(64));
    final dir = dirs[path];
    if (dir != null) return SftpFileAttrs(mode: SftpFileMode.value(dir));
    final file = files[path];
    if (file != null) {
      return SftpFileAttrs(size: file.length, mode: SftpFileMode.value(file.mode));
    }
    throw SftpStatusError(2, 'No such file');
  }

  @override
  Future<String> absolute(String path) async => path == '.' ? '/home/dev' : path;

  @override
  Future<List<SftpName>> listdir(String path) => throw UnimplementedError();

  @override
  Future<String> readlink(String path) => throw UnimplementedError();

  @override
  Future<Uint8List> readBytes(String path, int offset, int length) => throw UnimplementedError();

  var closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
  }
}

class _Handle implements SftpUploadFile {
  _Handle(this._server, this._path, this._file);

  final FakeSftpServer _server;
  final String _path;
  final FakeRemote _file;

  @override
  Future<void> write(int offset, Uint8List data) async {
    final s = _server;
    s.writeCount++;
    s.outstanding++;
    s.maxOutstanding = math.max(s.maxOutstanding, s.outstanding);
    try {
      if (s.dieAfterWrites != null && s.writeCount > s.dieAfterWrites!) {
        await Future<void>.delayed(Duration.zero);
        throw SftpAbortError('SFTP client closed');
      }
      if (s.hangAfterWrites != null && s.writeCount > s.hangAfterWrites!) {
        await Completer<void>().future;
      }
      await s._wait(s._answerInUs(data.length + 32));
      await s.ackGate?.future;
      if (!identical(s.files[_path], _file)) throw SftpStatusError(2, 'No such file');
      _file.writeAt(offset, data, keep: s.keepBytes);
      s.bytesReceived += data.length;
    } finally {
      s.outstanding--;
    }
  }

  @override
  Future<void> close() async {
    _file.closed = true;
    await _server._wait(_server._answerInUs(32));
  }
}
