import 'dart:async';
import 'dart:convert';
import 'dart:io' show ZLibEncoder, zlib;
import 'dart:math' as math;
import 'dart:typed_data';

// hostwire/1, the protocol on the one SSH exec channel between this app and
// `herdr-host serve` (rust/crates/wire is the reference; the golden vectors in
// rust/crates/wire/tests/vectors.json are decoded by both, see
// test/host_wire_vectors_test.dart).
//
// Frame: `len:u32le` (bytes after this field = 1 + 4 + payload) · `kind:u8` ·
// `stream:u32le` · payload. The high bits of `kind` are flags: 0x80 the
// payload is one complete zlib stream, 0x40 it is the next sync-flushed piece
// of the stream's one continuous zlib stream for that direction (only on a
// stream opened with `zctx`; each direction has its own zlib stream).
//
// The decoder is a synchronous push parser, not an `async*` generator: the same
// kind of parser written with `await for` paused the SSH channel's stream around
// every chunk and a request/response loop over loopback then took 40 ms per round
// trip instead of 2 (see `muxMessages` in mux_client.dart). Never pause the
// channel's stream per frame.

/// What the host writes first, before any frame.
final hostMagic = Uint8List.fromList([0xFF, ...ascii.encode('HERDR-HOST/1\n')]);

/// How far into the stream the magic may start: a login shell's noise comes
/// first on some hosts, but not a megabyte of it.
const hostMagicSearchLimit = 64 * 1024;

/// Largest wire payload of any frame but DATA.
const maxPayload = 1 << 20;

/// Largest wire payload of a DATA frame.
const maxData = 32 * 1024;

/// Nothing inflates to more than this.
const maxInflated = 64 << 20;

enum FrameKind {
  hello(1),
  open(2),
  msg(3),
  data(4),
  credit(5),
  end(6),
  reset(7);

  const FrameKind(this.code);

  final int code;

  bool get mayDeflate => this == msg || this == data || this == end;

  static FrameKind? of(int code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

enum FrameFlags {
  none(0),

  /// The payload is one complete zlib stream.
  deflate(0x80),

  /// The payload is the next piece of the stream's continuous zlib stream.
  deflateCtx(0x40);

  const FrameFlags(this.bits);

  final int bits;
}

/// One frame. [payload] is the bytes on the wire: compressed when [flags] says
/// so (inflating needs the stream's state, see [Inflater]).
class Frame {
  const Frame(this.kind, this.stream, this.payload, {this.flags = FrameFlags.none});

  /// A frame carrying [value] as JSON.
  factory Frame.json(FrameKind kind, int stream, Object? value) =>
      Frame(kind, stream, Uint8List.fromList(utf8.encode(jsonEncode(value))));

  /// A `CREDIT` frame granting [bytes].
  factory Frame.credit(int stream, int bytes) {
    final p = Uint8List(4)..buffer.asByteData().setUint32(0, bytes, Endian.little);
    return Frame(FrameKind.credit, stream, p);
  }

  final FrameKind kind;
  final FrameFlags flags;
  final int stream;
  final Uint8List payload;

  /// The bytes a `CREDIT` frame grants, or null for anything else.
  int? get creditBytes => kind == FrameKind.credit && payload.length == 4
      ? payload.buffer.asByteData(payload.offsetInBytes, 4).getUint32(0, Endian.little)
      : null;

  @override
  String toString() =>
      'Frame(${kind.name}, stream $stream, ${payload.length} bytes${flags == FrameFlags.none ? '' : ', ${flags.name}'})';
}

/// Bytes that are not valid hostwire/1. [name] is the vectors' name for the
/// reason (`too_large`, `bad_length`, `unknown_kind`, `bad_flags`, `truncated`,
/// `inflate`, `noise`).
class WireFormatException implements FormatException {
  const WireFormatException(this.name, this.message);

  final String name;

  @override
  final String message;

  @override
  int? get offset => null;

  @override
  dynamic get source => null;

  @override
  String toString() => 'hostwire: $message';
}

/// [frame]'s bytes.
///
/// Throws [ArgumentError] when the payload is over its kind's limit: the sender
/// splits first.
Uint8List encodeFrame(Frame frame) {
  final limit = frame.kind == FrameKind.data ? maxData : maxPayload;
  if (frame.payload.length > limit) {
    throw ArgumentError('a ${frame.kind.name} payload of ${frame.payload.length} bytes is over $limit');
  }
  final out = Uint8List(4 + 5 + frame.payload.length);
  final view = out.buffer.asByteData();
  view.setUint32(0, 5 + frame.payload.length, Endian.little);
  out[4] = frame.kind.code | frame.flags.bits;
  view.setUint32(5, frame.stream, Endian.little);
  out.setRange(9, out.length, frame.payload);
  return out;
}

/// A push parser: [add] bytes as they arrive, get whole frames through the
/// callback; [close] at the end of input. With [expectMagic] the bytes before
/// [hostMagic] are skipped (up to [hostMagicSearchLimit]), then it is dropped.
class FrameDecoder {
  FrameDecoder({this.expectMagic = true});

  final bool expectMagic;

  var _buf = Uint8List(16 * 1024);
  var _start = 0, _end = 0;
  late var _awaitMagic = expectMagic;
  var _scanned = 0;

  /// Bytes buffered and not yet part of a whole frame.
  int get pending => _end - _start;

  /// Feeds [chunk]; calls [onFrame] for each whole frame in it.
  ///
  /// Throws [WireFormatException]; the decoder is unusable afterwards.
  void add(List<int> chunk, void Function(Frame) onFrame) {
    _reserve(chunk.length);
    _buf.setRange(_end, _end + chunk.length, chunk);
    _end += chunk.length;
    if (_awaitMagic && !_skipToMagic()) return;
    while (true) {
      if (_end - _start < 4) break;
      final view = _buf.buffer.asByteData(_buf.offsetInBytes + _start);
      final len = view.getUint32(0, Endian.little);
      if (len < 5) throw WireFormatException('bad_length', 'frame length $len is smaller than its header');
      final payloadLen = len - 5;
      if (payloadLen > maxPayload) {
        throw WireFormatException('too_large', 'frame payload of $payloadLen bytes is over the limit');
      }
      if (_end - _start < 4 + len) break;
      final raw = _buf[_start + 4];
      final flags = switch (raw & 0xC0) {
        0 => FrameFlags.none,
        0x80 => FrameFlags.deflate,
        0x40 => FrameFlags.deflateCtx,
        _ => throw WireFormatException('bad_flags', 'both compression flags on frame kind ${raw & 0x3F}'),
      };
      final kind = FrameKind.of(raw & 0x3F);
      if (kind == null) throw WireFormatException('unknown_kind', 'unknown frame kind ${raw & 0x3F}');
      if (flags != FrameFlags.none && !kind.mayDeflate) {
        throw WireFormatException('bad_flags', 'flags not allowed on frame kind ${kind.name}');
      }
      if (kind == FrameKind.data && payloadLen > maxData) {
        throw WireFormatException('too_large', 'DATA payload of $payloadLen bytes is over the limit');
      }
      final stream = view.getUint32(5, Endian.little);
      final payload = Uint8List.fromList(Uint8List.sublistView(_buf, _start + 9, _start + 9 + payloadLen));
      _start += 4 + len;
      onFrame(Frame(kind, stream, payload, flags: flags));
    }
    if (_start == _end) _start = _end = 0;
  }

  /// The end of input.
  ///
  /// Throws [WireFormatException] (`truncated`) when it came inside a frame.
  void close() {
    if (_end > _start) throw const WireFormatException('truncated', 'the stream ended inside a frame');
  }

  bool _skipToMagic() {
    final m = hostMagic;
    final from = math.max(_start, _start + _scanned - m.length + 1);
    for (var i = from; i + m.length <= _end; i++) {
      var hit = true;
      for (var j = 0; j < m.length; j++) {
        if (_buf[i + j] != m[j]) {
          hit = false;
          break;
        }
      }
      if (hit) {
        _start = i + m.length;
        _awaitMagic = false;
        return true;
      }
    }
    _scanned = _end - _start;
    if (_scanned > hostMagicSearchLimit) {
      final shown = utf8.decode(_buf.sublist(_start, math.min(_end, _start + 200)), allowMalformed: true);
      throw WireFormatException('noise', 'unexpected output from the machine: $shown');
    }
    return false;
  }

  void _reserve(int more) {
    if (_end + more <= _buf.length) return;
    final live = _end - _start;
    if (live + more <= _buf.length) {
      _buf.setRange(0, live, _buf, _start);
    } else {
      final bigger = Uint8List(math.max(live + more, _buf.length * 2));
      bigger.setRange(0, live, _buf, _start);
      _buf = bigger;
    }
    _start = 0;
    _end = live;
  }
}

/// [FrameDecoder] as a stream transformer (synchronous, see the note at the top
/// of this file).
Stream<Frame> decodeFrames(Stream<List<int>> bytes, {bool expectMagic = true}) {
  final decoder = FrameDecoder(expectMagic: expectMagic);
  return StreamTransformer<List<int>, Frame>.fromHandlers(
    handleData: (chunk, sink) {
      try {
        decoder.add(chunk, sink.add);
      } on WireFormatException catch (e) {
        sink.addError(e);
        sink.close();
      }
    },
    handleDone: (sink) {
      try {
        decoder.close();
      } on WireFormatException catch (e) {
        sink.addError(e);
      }
      sink.close();
    },
  ).bind(bytes);
}

/// [data] as one complete zlib stream (level 6), the payload of a `deflate`
/// frame.
Uint8List deflate(List<int> data) => Uint8List.fromList(ZLibEncoder(level: 6).convert(data));

/// [data] deflated when it is at least [min] bytes and that is smaller, else
/// null (the sender then sends it plain).
Uint8List? deflateIfSmaller(List<int> data, {int min = 512}) {
  if (data.length < min) return null;
  final packed = deflate(data);
  return packed.length < data.length ? packed : null;
}

/// Inflates payloads of one stream in order: for the pieces of a continuous
/// stream, or one fresh per complete `deflate` payload ([Inflater.once]).
class Inflater {
  Inflater() {
    _sink = zlib.decoder.startChunkedConversion(_Collect((d) => _out.add(d)));
  }

  late final ByteConversionSink _sink;
  final _out = BytesBuilder(copy: false);

  /// What [piece] inflates to.
  ///
  /// Throws [WireFormatException] (`inflate`) for data that is not zlib, or that
  /// inflates to more than [maxInflated] bytes.
  Uint8List inflate(Uint8List piece) {
    try {
      _sink.add(piece);
    } on Object catch (e) {
      throw WireFormatException('inflate', 'a compressed payload does not inflate: $e');
    }
    final out = _out.takeBytes();
    if (out.length > maxInflated) {
      throw const WireFormatException('inflate', 'a compressed payload inflates to too much');
    }
    return out;
  }

  /// Inflates one complete zlib stream.
  static Uint8List once(Uint8List data) {
    try {
      final out = Uint8List.fromList(zlib.decode(data));
      if (out.length > maxInflated) {
        throw const WireFormatException('inflate', 'a compressed payload inflates to too much');
      }
      return out;
    } on WireFormatException {
      rethrow;
    } on Object catch (e) {
      throw WireFormatException('inflate', 'a compressed payload does not inflate: $e');
    }
  }
}

class _Collect implements Sink<List<int>> {
  _Collect(this._onData);

  final void Function(List<int>) _onData;

  @override
  void add(List<int> data) => _onData(data);

  @override
  void close() {}
}
