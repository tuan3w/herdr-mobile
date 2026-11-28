import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'fake_transport.dart' show snapshotJson;

/// A herdr API socket played by the test: one request per connection, like
/// herdr's own, answered from [handler] or by the defaults below. It is what the
/// real `herdr-host serve` talks to in host_serve_herdr_test.dart.
///
/// The answers carry fields the app never reads (`session_path` on a pane,
/// `source` on a read, `debug` on an event), so a test can tell that the host cut
/// them out as the app's projections say.
class FakeHerdrSocket {
  FakeHerdrSocket._(this.path, this._server, this.handler);

  /// Listens on the unix socket [path] (its folder is created).
  static Future<FakeHerdrSocket> bind(
    String path, {
    Future<Map<String, Object?>?> Function(Map<String, dynamic> request)? handler,
  }) async {
    Directory(File(path).parent.path).createSync(recursive: true);
    final server = await ServerSocket.bind(InternetAddress(path, type: InternetAddressType.unix), 0);
    final fake = FakeHerdrSocket._(path, server, handler);
    server.listen(fake._onClient);
    return fake;
  }

  final String path;
  final ServerSocket _server;
  final Future<Map<String, Object?>?> Function(Map<String, dynamic> request)? handler;

  /// Every request line received, decoded.
  final requests = <Map<String, dynamic>>[];

  final _subscribers = <Socket>[];

  /// How many rows the pane's screen has scrolled: row N reads the same on every
  /// read, so a screen that scrolled by k rows is a delta of k rows.
  var scrolled = 0;

  /// The screen `pane.read` answers with now.
  String screen({int lines = 300}) => [
    for (var i = 0; i < lines; i++)
      'row ${scrolled + i}: ${List.generate(10, (j) => 'w${(scrolled + i) * 31 + j * 7}').join(' ')}',
  ].join('\n');

  void _onClient(Socket client) {
    // Keeps listening after the request line: a subscriber that the host hangs
    // up on is only noticed by reading the socket to its end.
    var asked = false;
    utf8.decoder
        .bind(client)
        .transform(const LineSplitter())
        .listen(
          (line) async {
            if (asked) return;
            asked = true;
            final request = jsonDecode(line) as Map<String, dynamic>;
            requests.add(request);
            final id = request['id'];
            final custom = await handler?.call(request);
            final answer = custom ?? _default(request);
            client.write('${jsonEncode({'id': id, ...answer})}\n');
            if (request['method'] == 'events.subscribe' && (answer['error'] == null)) {
              _subscribers.add(client);
              return;
            }
            await client.close();
          },
          onDone: () => _subscribers.remove(client),
          onError: (Object _) => _subscribers.remove(client),
        );
  }

  Map<String, Object?> _default(Map<String, dynamic> request) => switch (request['method']) {
    'ping' => {
      'result': {'type': 'pong'},
    },
    'session.snapshot' => {
      'result': {
        'snapshot': () {
          final snapshot = snapshotJson(panes: [(id: 'w1:p1', ws: 'w1', agent: 'omp', status: 'working')]);
          for (final pane in snapshot['panes'] as List) {
            (pane as Map<String, dynamic>)['session_path'] = '/home/u/.omp/sessions/secret.jsonl';
          }
          return snapshot;
        }(),
      },
    },
    'pane.read' => {
      'result': {
        'read': {'text': screen(), 'truncated': false, 'source': 'visible'},
      },
    },
    'events.subscribe' => {
      'result': {'type': 'subscription_started'},
    },
    _ => {
      'error': {'code': 'unknown_method', 'message': 'no method ${request['method']}'},
    },
  };

  /// Sends [event] to every subscription.
  void pushEvent(Map<String, Object?> event) {
    for (final s in _subscribers) {
      s.write('${jsonEncode(event)}\n');
    }
  }

  /// How many subscriptions are open.
  int get subscriptions => _subscribers.length;

  Future<void> close() async {
    for (final s in [..._subscribers]) {
      s.destroy();
    }
    _subscribers.clear();
    await _server.close();
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }
}
