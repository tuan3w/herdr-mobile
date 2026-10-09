import 'dart:async';
import 'dart:convert';
import 'dart:io' show zlib;

/// A `Z` line that is not base64 of a zlib stream, or a stream that stopped
/// being one: nothing after it can be read.
class CorruptZippedLines extends FormatException {
  const CorruptZippedLines() : super('the keeper sent a replay that does not inflate');
}

/// Reads what `keeper attach --z` writes (`keeperAttachCommand(zipped: true)`):
/// plain lines pass as they are, and a line `Z<base64>` is the next piece of
/// ONE zlib stream (each piece ends with a sync flush) that inflates to whole
/// lines, which are delivered in its place, in order.
///
/// The keeper script sends a batch zipped only when it is big enough to gain
/// (`ATTACH_ZIP_MIN`): the replay of a long thread is plain JSON text and goes
/// over the phone's link ~10x smaller, a streamed word stays as it is. A
/// JSON-RPC message starts with `{`, so `Z` is unambiguous.
///
/// Synchronous (a `fromHandlers` transformer), like `muxMessages`: never pause
/// the channel's stream per message. A piece that does not inflate is a bug of
/// the script (the link is authenticated): the stream ends with an error, so
/// the connection is rebuilt, and nothing after it is read, since the state of
/// the inflater is gone.
Stream<String> zippedLines(Stream<String> lines) {
  ByteConversionSink? inflater;
  // A multi-byte character can straddle two inflated chunks (the inflater
  // hands over 64 KiB at a time): decoding each chunk alone turned the cut
  // character into U+FFFD, so the decoder keeps its state across chunks.
  ByteConversionSink? decoder;
  EventSink<String>? current;
  var partial = '';
  var broken = false;

  void onText(String chunk) {
    final text = partial + chunk;
    var from = 0;
    while (true) {
      final nl = text.indexOf('\n', from);
      if (nl < 0) break;
      if (nl > from) current!.add(text.substring(from, nl));
      from = nl + 1;
    }
    partial = text.substring(from);
  }

  void onInflated(List<int> data) => decoder!.add(data);

  return lines.transform(
    StreamTransformer<String, String>.fromHandlers(
      handleData: (line, sink) {
        if (broken) return;
        if (!line.startsWith('Z')) {
          sink.add(line);
          return;
        }
        current = sink;
        try {
          if (inflater == null) {
            decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_CollectText(onText));
            inflater = zlib.decoder.startChunkedConversion(_Collect(onInflated));
          }
          inflater!.add(base64.decode(line.substring(1)));
        } on Object {
          broken = true;
          sink.addError(const CorruptZippedLines());
          sink.close();
        }
      },
      handleDone: (sink) {
        if (!broken) {
          current = sink;
          decoder?.close();
          if (partial.isNotEmpty) sink.add(partial);
        }
        inflater = null;
        decoder = null;
        sink.close();
      },
    ),
  );
}

class _Collect implements Sink<List<int>> {
  const _Collect(this._onData);

  final void Function(List<int>) _onData;

  @override
  void add(List<int> data) => _onData(data);

  @override
  void close() {}
}

class _CollectText implements Sink<String> {
  const _CollectText(this._onData);

  final void Function(String) _onData;

  @override
  void add(String data) => _onData(data);

  @override
  void close() {}
}
