import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One answer read off a raw socket.
class RawReply {
  RawReply(this.status, this.headers, this.body, {this.closedEarly = false, this.timedOut = false});

  final int status;
  final Map<String, String> headers;
  final Uint8List body;

  /// The connection ended before the Content-Length it announced arrived.
  final bool closedEarly;

  /// The listener never closed the connection: the read gave up waiting.
  final bool timedOut;

  String get text => utf8.decode(body, allowMalformed: true);
}

/// Sends one HTTP/1.1 request on a fresh loopback connection and reads until
/// the connection closes. A raw socket, not `HttpClient`: the tests send the
/// requests a browser would never (odd paths, a foreign Host, no cookie) and
/// need the headers exactly as the listener wrote them.
Future<RawReply> rawRequest(
  int port, {
  String method = 'GET',
  String target = '/',
  String? host,
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 5),
}) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  final h = {'Host': host ?? 'localhost:$port', 'Connection': 'close', ...headers};
  socket.add(latin1.encode(
    '$method $target HTTP/1.1\r\n${[for (final e in h.entries) '${e.key}: ${e.value}\r\n'].join()}\r\n',
  ));
  final bytes = BytesBuilder(copy: false);
  final done = Completer<void>();
  // An error (a reset after the answer) is followed by done: complete once.
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  socket.listen(bytes.add, onDone: finish, onError: (Object _) => finish());
  var timedOut = false;
  await done.future.timeout(timeout, onTimeout: () {
    timedOut = true;
    socket.destroy();
  });
  socket.destroy();
  final all = bytes.takeBytes();
  var split = -1;
  for (var i = 0; i + 3 < all.length; i++) {
    if (all[i] == 13 && all[i + 1] == 10 && all[i + 2] == 13 && all[i + 3] == 10) {
      split = i;
      break;
    }
  }
  if (split < 0) return RawReply(0, const {}, all, timedOut: timedOut);
  final lines = latin1.decode(all.sublist(0, split)).split('\r\n');
  final parsed = <String, String>{};
  for (final line in lines.skip(1)) {
    final i = line.indexOf(':');
    if (i > 0) parsed[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
  }
  final body = Uint8List.sublistView(all, split + 4);
  final announced = int.tryParse(parsed['content-length'] ?? '');
  return RawReply(
    int.parse(lines.first.split(' ')[1]),
    parsed,
    body,
    closedEarly: announced != null && body.length < announced,
    timedOut: timedOut,
  );
}

/// The cookie a listener's entry URL answers with, as the browser would send it.
String cookieFrom(RawReply entry) => entry.headers['set-cookie']!.split(';').first;

/// Where a listener's entry URL sends the browser on: the URL of its
/// `Refresh` header (`0; url=<where>`), or null when it sends it nowhere.
String? sendsTo(RawReply entry) {
  final refresh = entry.headers['refresh'];
  if (refresh == null) return null;
  final at = refresh.indexOf('url=');
  return at < 0 ? null : refresh.substring(at + 4);
}
