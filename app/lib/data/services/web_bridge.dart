import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart' show SSHSocket;

import '../models/remote_file.dart';
import '../models/web_bridge.dart';
import 'herdr_transport.dart';

/// What the host needs from the machine. Three small callbacks instead of a
/// transport so the host is tested with a fake machine and a fake socket.
typedef WebStat = Future<RemoteStat> Function(String path);
typedef WebRead = Future<Uint8List> Function(String path, int offset, int length);
typedef WebDial = Future<SSHSocket> Function(String host, int port);

/// Size of one SFTP read. Small enough that a 6 MB page never sits in memory
/// (measured: the listener stayed at 60 MB peak RSS), big enough that a normal
/// asset is one read.
const webBridgePiece = 256 * 1024;

/// Reads in flight per response. One SFTP read costs two round trips (open,
/// read), so one at a time left a 10 Mbit link idle: a 6 MB page took 11.3 s
/// against 5.9 s with three (modelled link, 120 ms RTT).
const webBridgeReadWindow = 3;

/// Connections one listener serves at once; more are dropped.
const webBridgeMaxConnections = 64;

/// The most one open-ended `Range: bytes=N-` request is answered with.
const webBridgeOpenRange = 2 * 1024 * 1024;

/// The loopback listeners that show what an agent made on a machine on the
/// phone: a folder read over SFTP ([StaticSite]) or a port reached over the
/// SSH connection ([PortForward]). Lives in the transport isolate. Their pages
/// are shown in herdr's own WebView (`WebPreviewScreen`) or, on request, in
/// the phone's browser (`openPreviewUrl`); both are browsers to a listener.
///
/// Why a listener and not the page's bytes handed to the view: the page's
/// own relative and root-absolute links, its scripts' `fetch` and its
/// sibling ports all need an origin that answers, as a dev server does.
///
/// Everything a listener answers needs its token, sent once in the entry URL
/// (`/__herdr/open?t=<token>&to=<path>`) and kept by the browser as a cookie
/// named for the port. A static folder answers its own entry URL; a forward's
/// is answered by a separate entry listener (see `_ensureEntry`), so the URL
/// never goes down a connection that belongs to the dev server. Why a cookie
/// and not a path prefix: a built site refers to its files as
/// `/assets/x.js`, which a prefix would break. Why the Host header is
/// checked: a page on the internet can make the browser resolve its own name
/// to 127.0.0.1 and call the listener (DNS rebinding).
class WebBridgeHost {
  WebBridgeHost({
    required this.stat,
    required this.read,
    required this.dial,
    this.idle = const Duration(minutes: 10),
    this.headTimeout = const Duration(seconds: 10),
    math.Random? random,
  }) : _random = random ?? math.Random.secure();

  final WebStat stat;
  final WebRead read;
  final WebDial dial;
  final math.Random _random;

  /// A listener with no request or connection for this long stops (one-shot
  /// timer, restarted by activity: nothing polls). Its port and token are
  /// remembered, so the next open of the same spec reuses them and a tab that
  /// was left open keeps working.
  final Duration idle;

  /// How long a connection may take to send the head of its first request.
  final Duration headTimeout;

  final _bridges = <String, _Bridge>{};
  final _starting = <String, Future<_Bridge>>{};
  final _remembered = <String, ({int port, String token})>{};
  HttpServer? _entry;
  Future<HttpServer>? _entryStarting;
  var _forwardStarts = 0;
  var _closed = false;

  /// Ports of the listeners that are up (for tests).
  Set<int> get livePorts => {for (final b in _bridges.values) b.port};

  Future<WebBridgeInfo> open(WebBridgeSpec spec) async {
    if (_closed) throw const HerdrTransportException('Transport closed');
    final live = _bridges[spec.key];
    if (live != null) {
      live.arm();
      return _infoOf(live);
    }
    // The callback must not return the removed future: whenComplete would then
    // wait for the very future it belongs to.
    final bridge = await (_starting[spec.key] ??= _start(spec).whenComplete(() {
      _starting.remove(spec.key);
    }));
    bridge.arm();
    return _infoOf(bridge);
  }

  Future<_Bridge> _start(WebBridgeSpec spec) async {
    if (spec is! PortForward) return _bind(spec);
    // The entry listener stays up from here to the end, even when the last
    // live forward stops meanwhile.
    _forwardStarts++;
    try {
      await _ensureEntry();
      return await _bind(spec);
    } finally {
      _forwardStarts--;
      _dropEntryIfUnused();
    }
  }

  Future<_Bridge> _bind(WebBridgeSpec spec) async {
    final remembered = _remembered[spec.key];
    if (spec is PortForward) await _checkForwardAllowed(spec);
    // A forward takes the port number of its target first: a page written for
    // localhost:3000 talks to localhost:3000 by name, and only the same number
    // reaches the phone's listener. A taken port falls back to a free one.
    final candidates = <int>{if (spec is PortForward) spec.port, if (remembered != null) remembered.port, 0};
    Object? lastError;
    for (final candidate in candidates) {
      // The remembered token belongs to the remembered port: a tab left open
      // holds `herdr_<port>=<token>` and reloads that port. When something
      // else took the port meanwhile and the listener came back elsewhere,
      // the old tab would reload into that other app and hand it the cookie,
      // so a listener on any other port starts over with a new token.
      final token = remembered != null && candidate == remembered.port ? remembered.token : _newToken();
      try {
        final bridge = switch (spec) {
          StaticSite() => await _StaticBridge.bind(this, spec, token, candidate),
          PortForward() => await _ForwardBridge.bind(this, spec, token, candidate),
        };
        if (_closed) {
          await bridge.stop();
          throw const HerdrTransportException('Transport closed');
        }
        _bridges[spec.key] = bridge;
        _remembered[spec.key] = (port: bridge.port, token: token);
        return bridge;
      } on SocketException catch (e) {
        lastError = e;
      }
    }
    throw HerdrTransportException('Can’t open a local port: $lastError');
  }

  /// A host that forbids port forwarding says so on the first channel; ask
  /// once, before the person is sent to a page that can only show an error.
  /// Any other failure (nothing listens on the target yet) is not a refusal:
  /// the page explains it, and a server that starts later then works.
  Future<void> _checkForwardAllowed(PortForward spec) async {
    final SSHSocket probe;
    try {
      probe = await dial(spec.host, spec.port);
    } on HerdrTransportException catch (e) {
      if (e.fatal) rethrow;
      return;
    } on Object {
      return;
    }
    probe.destroy();
  }

  Future<void> close() async {
    _closed = true;
    final all = _bridges.values.toList();
    _bridges.clear();
    final entry = _entry;
    _entry = null;
    _entryStarting = null;
    await Future.wait([for (final b in all) b.stop(), if (entry != null) entry.close(force: true)]);
  }

  // ----- the entry listener -----

  /// One loopback listener for the host that answers only the entry URL of
  /// forwards. Why not the forward's own port: the browser keeps connections
  /// to that port and sends later requests down them, and a forward only reads
  /// the first request of a connection, then passes bytes. An entry URL sent
  /// down a kept connection reached the dev server, with the token in its log
  /// (seen with a real Chrome). On its own port the entry URL cannot meet that
  /// connection. The cookie it sets is named for the forward's port and is
  /// sent by the browser to that port too (cookies ignore ports), which is
  /// where the forward checks it; the browser is then sent on to
  /// `http://localhost:<forward port>` (see [_enter]).
  ///
  /// Up while a forward is up or starting; a static folder answers its own
  /// entry URL (an `HttpServer` reads every request).
  Future<HttpServer> _ensureEntry() => _entryStarting ??= _bindEntry();

  Future<HttpServer> _bindEntry() async {
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      if (_closed) {
        await server.close(force: true);
        throw const HerdrTransportException('Transport closed');
      }
      server.idleTimeout = const Duration(seconds: 5);
      server.defaultResponseHeaders.clear();
      server.listen((request) => unawaited(_serveEntry(server.port, request)), onError: (Object _) {});
      _entry = server;
      return server;
    } on SocketException catch (e) {
      _entryStarting = null;
      throw HerdrTransportException('Can’t open a local port: $e');
    } on Object {
      _entryStarting = null;
      rethrow;
    }
  }

  void _dropEntryIfUnused() {
    if (_forwardStarts > 0 || _bridges.values.any((b) => b is _ForwardBridge)) {
      return;
    }
    final server = _entry;
    _entry = null;
    _entryStarting = null;
    if (server != null) unawaited(server.close(force: true));
  }

  Future<void> _serveEntry(int port, HttpRequest req) async {
    final res = req.response;
    try {
      if (!_hostAllowed(_one(req.headers, 'host'), port)) {
        return _errorPage(res, 403, 'Wrong address', '<p>This address is only for herdr-mobile.</p>');
      }
      final uri = req.uri;
      if (uri.hasAuthority || uri.hasScheme || uri.path != '/__herdr/open') {
        return _errorPage(res, 404, 'Not found', _openText);
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        return _send(res, 405, headers: {'allow': 'GET, HEAD'});
      }
      final query = _query(uri);
      // The token names the forward: 128 random bits cannot collide, and the
      // person's tap carries nothing else to say which one.
      _ForwardBridge? hit;
      for (final b in _bridges.values) {
        if (b is _ForwardBridge && _tokenOk(query['t'], b.token)) hit = b;
      }
      if (hit == null) {
        return _errorPage(res, 403, 'Not allowed', _openText);
      }
      hit.arm();
      _enter(res, hit.port, hit.token, 'http://localhost:${hit.port}${_safeTo(query['to'])}');
    } on Object {
      // This runs in the transport isolate: what nobody catches ends it.
      try {
        _errorPage(res, 500, 'Something went wrong', _openText);
      } on Object {
        // The response is already on its way.
      }
    }
  }

  WebBridgeInfo _infoOf(_Bridge bridge) =>
      WebBridgeInfo(port: bridge.port, token: bridge.token, entryPort: bridge is _ForwardBridge ? _entry!.port : null);

  String _newToken() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
  }

  // ----- shared by both listeners -----

  /// Only the phone's own names for the listener: anything else is a page that
  /// pointed its own name at 127.0.0.1.
  static bool _hostAllowed(String? host, int port) {
    if (host == null) return false;
    final h = host.toLowerCase();
    return h == 'localhost:$port' || h == '127.0.0.1:$port';
  }

  static bool _tokenOk(String? given, String token) {
    if (given == null || given.length != token.length) return false;
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= given.codeUnitAt(i) ^ token.codeUnitAt(i);
    }
    return diff == 0;
  }

  static String? _cookie(String? header, String name) {
    if (header == null) return null;
    for (final part in header.split(';')) {
      final i = part.indexOf('=');
      if (i > 0 && part.substring(0, i).trim() == name) {
        return part.substring(i + 1).trim();
      }
    }
    return null;
  }

  /// The value of a request header that must be said once: absent when it is
  /// missing or repeated. `HttpHeaders.value` throws on a repeated header, and
  /// a listener that throws answers 502 to what is only a malformed request.
  /// A repeated `Host`, `Range` or `If-Modified-Since` is ambiguous, so it
  /// counts as not there (and the allowlist refuses a missing `Host`).
  static String? _one(HttpHeaders headers, String name) {
    final values = headers[name];
    return values != null && values.length == 1 ? values.first : null;
  }

  /// Every value of a header that may be repeated, joined with [separator]
  /// (`Cookie` is one list however many lines carry it).
  static String? _joined(HttpHeaders headers, String name, String separator) => headers[name]?.join(separator);

  /// The query of [uri] as pairs, without ever throwing. `Uri.queryParameters`
  /// throws a `FormatException` on `%ff` (an invalid UTF-8 escape); one request
  /// of `/__herdr/open?t=%ff` to a forward listener needed no token, escaped
  /// every handler and killed the transport isolate, and with it every request
  /// and SSH stream of the machine. A pair that does not decode is left out,
  /// so a bad `t` is "no token" (403) and a bad `to` is "no destination" (`/`).
  static Map<String, String> _query(Uri uri) {
    final pairs = <String, String>{};
    if (!uri.hasQuery) return pairs;
    for (final part in uri.query.split('&')) {
      if (part.isEmpty) continue;
      final i = part.indexOf('=');
      try {
        final name = Uri.decodeQueryComponent(i < 0 ? part : part.substring(0, i));
        pairs[name] = i < 0 ? '' : Uri.decodeQueryComponent(part.substring(i + 1));
      } on FormatException {
        continue;
      }
    }
    return pairs;
  }

  /// Where the entry URL sends the browser: a path of this listener, never
  /// another site (`//host` and `/\host` mean another site to a browser, and a
  /// browser strips tabs and newlines before it reads a URL, so `/<tab>/host`
  /// does too). Only printable ASCII is let through; anything else is `/`.
  static String _safeTo(String? to) {
    if (to == null || !to.startsWith('/') || to.startsWith('//')) return '/';
    for (final c in to.codeUnits) {
      if (c <= 0x20 || c >= 0x7f || c == 0x5c) return '/';
    }
    return to;
  }

  static String _entryCookie(int port, String token) => 'herdr_$port=$token; Path=/; HttpOnly; SameSite=Strict';

  /// The answer to a good entry URL: the cookie, and a page that sends the
  /// browser on to [destination] with a `Refresh` header, not a 302.
  ///
  /// A Chrome Custom Tab navigates from an opaque origin, so that the app that
  /// opened it cannot hand a site its same-site cookies
  /// (`CustomTabActivityNavigationController.navigate`), and a redirect keeps
  /// that initiator: the `SameSite=Strict` cookie this very answer sets was
  /// not sent to [destination], which refused the browser ("Not allowed",
  /// seen on a phone; a desktop browser given the URL by hand never showed
  /// it). A refresh is a navigation the page starts itself, from `localhost`,
  /// which is same-site with every listener (a site has no port), so the
  /// cookie goes with it. At no delay it replaces this page in the tab's
  /// history, so Back never returns to the token.
  static void _enter(HttpResponse res, int port, String token, String destination) => _send(
    res,
    200,
    type: 'text/html; charset=utf-8',
    body: _page('Opening…', '<p><a href="${_esc(destination)}">Continue</a></p>'),
    headers: {'set-cookie': _entryCookie(port, token), 'refresh': '0; url=$destination'},
  );

  static String _esc(String s) => const HtmlEscape(HtmlEscapeMode.attribute).convert(s);

  static String _page(String title, String body) =>
      '<!doctype html><html><head>'
      '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
      '<meta name="color-scheme" content="light dark">'
      '<title>${_esc(title)}</title></head>'
      '<body style="font:16px system-ui;margin:24px;max-width:36em;color:CanvasText;background:Canvas">'
      '<h1 style="font-size:20px">${_esc(title)}</h1>$body</body></html>';

  static const _openText = '<p>Open this from herdr-mobile.</p>';

  /// A request with no cookie that comes from a page served by another of our
  /// listeners (a front end on 5173 calling its API on 8000). `fetch` leaves
  /// cookies out of cross-origin requests and a preflight never has them, so
  /// the cookie cannot be asked of these. Measured: without this allowance a
  /// page with a second port fails.
  ///
  /// Who can send such a request: a page served by another of this app's own
  /// loopback listeners (browsers set `Sec-Fetch-Site: same-site` and `Origin`
  /// themselves, which keeps out pages from the internet, `cross-site`), or an
  /// app on the phone that writes those headers by hand and finds the port of a
  /// live listener. What it reaches: only this listener, one the person already
  /// opened. Not an Origin equal to the listener's own port (a same-origin
  /// request carries the cookie anyway, so it has no reason to ask for this),
  /// and only the first request of a connection is looked at, never later ones.
  bool _siblingOrigin(Map<String, String> headers, int ownPort) {
    if (headers['sec-fetch-site'] != 'same-site') return false;
    final origin = headers['origin'];
    if (origin == null) return false;
    return livePorts.any((p) => p != ownPort && origin == 'http://localhost:$p');
  }
}

/// One answer from a listener that is an [HttpServer] (the static folder, the
/// entry listener). The body is written and the response closed here.
void _send(HttpResponse res, int code, {String? type, String body = '', Map<String, String> headers = const {}}) {
  res.statusCode = code;
  res.headers
    ..set('x-content-type-options', 'nosniff')
    ..set('referrer-policy', 'no-referrer')
    ..set('cache-control', 'no-store');
  for (final e in headers.entries) {
    res.headers.set(e.key, e.value);
  }
  if (type != null) res.headers.set('content-type', type);
  final bytes = utf8.encode(body);
  // A HEAD answer announces the length of the body it does not send.
  if (!headers.containsKey('content-length')) {
    res.headers.set('content-length', '${bytes.length}');
  }
  if (bytes.isNotEmpty) res.add(bytes);
  unawaited(res.close().catchError((Object _) {}));
}

void _errorPage(HttpResponse res, int code, String title, String body) =>
    _send(res, code, type: 'text/html; charset=utf-8', body: WebBridgeHost._page(title, body));

abstract class _Bridge {
  _Bridge(this.host, this.spec, this.token);

  final WebBridgeHost host;
  final WebBridgeSpec spec;
  final String token;
  int get port;

  /// Requests (static) or connections (forward) in flight. The idle timer
  /// only runs while there are none.
  int active = 0;
  Timer? _timer;
  var _stopped = false;

  void arm() {
    _timer?.cancel();
    if (_stopped || active > 0) return;
    _timer = Timer(host.idle, () {
      if (active > 0) {
        arm();
      } else {
        unawaited(stop());
      }
    });
  }

  void begin() {
    active++;
    _timer?.cancel();
  }

  void end() {
    active--;
    arm();
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _timer?.cancel();
    if (identical(host._bridges[spec.key], this)) {
      host._bridges.remove(spec.key);
    }
    host._dropEntryIfUnused();
    await closeListener();
  }

  Future<void> closeListener();
}

// ======================= static folder =======================

const _mime = {
  'html': 'text/html',
  'htm': 'text/html',
  'xhtml': 'application/xhtml+xml',
  'css': 'text/css',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'json': 'application/json',
  'map': 'application/json',
  'svg': 'image/svg+xml',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'avif': 'image/avif',
  'ico': 'image/x-icon',
  'woff': 'font/woff',
  'woff2': 'font/woff2',
  'ttf': 'font/ttf',
  'otf': 'font/otf',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'pdf': 'application/pdf',
  'txt': 'text/plain',
  'xml': 'application/xml',
  'wasm': 'application/wasm',
};
const _textual = {'html', 'htm', 'xhtml', 'css', 'js', 'mjs', 'json', 'map', 'svg', 'txt', 'xml'};

String _extensionOf(String path) {
  final name = path.substring(path.lastIndexOf('/') + 1);
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}

String _contentTypeOf(String name) {
  final ext = _extensionOf(name);
  final type = _mime[ext];
  if (type == null) return 'application/octet-stream';
  return _textual.contains(ext) ? '$type; charset=utf-8' : type;
}

final class _StaticBridge extends _Bridge {
  _StaticBridge._(super.host, StaticSite super.spec, super.token, this._server, this._root);

  final HttpServer _server;
  final String _root;

  StaticSite get site => spec as StaticSite;

  @override
  int get port => _server.port;

  static Future<_StaticBridge> bind(WebBridgeHost host, StaticSite spec, String token, int port) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    // Chrome keeps connections it has finished with; closing them here lets a
    // listener with nothing to do actually have no connection.
    server.idleTimeout = const Duration(seconds: 15);
    server.defaultResponseHeaders.clear();
    final root = spec.root.length > 1 ? spec.root.replaceFirst(RegExp(r'/+$'), '') : '';
    final bridge = _StaticBridge._(host, spec, token, server, root);
    server.listen(bridge._serve, onError: (Object _) {});
    return bridge;
  }

  @override
  Future<void> closeListener() => _server.close(force: true);

  /// The machine path for [rel], a path of the site without a trailing slash
  /// (empty for the site's own folder). The only place a request becomes a
  /// machine path, after `_handle` has refused everything that could leave
  /// the folder.
  String _pathOf(String rel) => rel.isEmpty ? (_root.isEmpty ? '/' : _root) : '$_root$rel';

  Future<void> _serve(HttpRequest request) async {
    begin();
    try {
      await _handle(request);
    } on Object catch (e) {
      final res = request.response;
      try {
        // Nothing sent yet: say what went wrong.
        _failure(res, e);
      } on Object {
        // The status line is out already: the connection can only be cut.
        await _abort(res);
      }
    } finally {
      end();
    }
  }

  /// Cuts the connection in the middle of a body, so the browser sees a
  /// failed download instead of a page that waits for bytes that never come.
  /// Closing a response that wrote less than its Content-Length makes dart:io
  /// destroy the socket (and throw, which is expected here).
  Future<void> _abort(HttpResponse response) async {
    try {
      await response.close();
    } on Object {
      // The announced length was not written: this is the cut.
    }
  }

  void _notFound(HttpResponse res, String shown) => _errorPage(
    res,
    404,
    'Not found',
    '<p>Not found: <code>${WebBridgeHost._esc(shown)}</code></p>'
        '<p>Served from <code>${WebBridgeHost._esc(site.root)}</code> on ${WebBridgeHost._esc(site.machineName)}</p>',
  );

  void _failure(HttpResponse res, Object e) {
    if (e is RemoteFileException) {
      switch (e.kind) {
        case RemoteFileErrorKind.notFound:
        case RemoteFileErrorKind.notAFile:
          return _notFound(res, '');
        case RemoteFileErrorKind.permission:
          return _errorPage(res, 403, 'Not allowed', '<p>${WebBridgeHost._esc(e.message)}</p>');
        case RemoteFileErrorKind.unsupported:
          return _errorPage(res, 502, 'Files are not available', '<p>${WebBridgeHost._esc(e.message)}</p>');
        case RemoteFileErrorKind.tooLarge:
        case RemoteFileErrorKind.notADirectory:
        case RemoteFileErrorKind.failed:
        case RemoteFileErrorKind.network:
          break;
      }
    }
    _errorPage(
      res,
      502,
      "Couldn’t reach ${site.machineName}",
      "<p>Couldn’t reach ${WebBridgeHost._esc(site.machineName)}. Reload to retry.</p>",
    );
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final hostHeader = WebBridgeHost._one(req.headers, 'host');
    if (!WebBridgeHost._hostAllowed(hostHeader, port)) {
      return _errorPage(res, 403, 'Wrong address', '<p>This address is only for herdr-mobile.</p>');
    }

    final uri = req.uri;
    final rawPath = uri.path.isEmpty ? '/' : uri.path;
    // `//name` parses as a host with no path: no browser sends that to us.
    if (uri.hasAuthority || uri.hasScheme) {
      return _errorPage(res, 400, 'Bad request', '<p>This address isn’t one herdr-mobile opens.</p>');
    }

    final query = WebBridgeHost._query(uri);
    if (rawPath == '/__herdr/open') {
      if (!WebBridgeHost._tokenOk(query['t'], token)) {
        return _errorPage(res, 403, 'Not allowed', WebBridgeHost._openText);
      }
      // Anchored to this listener's own origin, as the forward's is: a
      // relative target is only as safe as the browser's reading of it.
      return WebBridgeHost._enter(res, port, token, 'http://localhost:$port${WebBridgeHost._safeTo(query['to'])}');
    }
    if (!WebBridgeHost._tokenOk(
      WebBridgeHost._cookie(WebBridgeHost._joined(req.headers, 'cookie', '; '), 'herdr_$port'),
      token,
    )) {
      return _errorPage(res, 403, 'Not allowed', WebBridgeHost._openText);
    }
    final head = req.method == 'HEAD';
    if (req.method != 'GET' && !head) {
      return _send(res, 405, headers: {'allow': 'GET, HEAD'});
    }

    // Decode once, then refuse what could leave the folder. The backend is
    // only ever asked for a path built here from the root.
    final String decoded;
    try {
      decoded = Uri.decodeComponent(rawPath);
    } on FormatException {
      return _notFound(res, rawPath);
    }
    // A leading dot is refused in every segment (after decoding, so `%2e`
    // counts): a page in a home folder or a repository root could otherwise
    // read `~/.ssh/id_ed25519`, `.env`, `.git/config`, `.aws/credentials` or
    // `.bash_history`, and the page is written by an agent and runs on the
    // same origin as them. No segment is exempt (`..` starts with a dot too).
    // The served folder itself is never checked, only what a request names, so
    // a site whose own folder starts with a dot still opens.
    if (decoded.contains('\u0000') || decoded.contains(r'\') || decoded.split('/').any((s) => s.startsWith('.'))) {
      return _notFound(res, rawPath);
    }

    var rel = decoded;
    RemoteStat st;
    try {
      final wantsFolder = rel.endsWith('/');
      // A link inside the folder that points outside it is followed: the SFTP
      // stat resolves it, and telling it apart would take a realpath call for
      // every request. The folder is trusted to hold what the page may read.
      st = await host.stat(_pathOf(wantsFolder ? rel.substring(0, rel.length - 1) : rel));
      if (wantsFolder && !st.isDirectory) return _notFound(res, rawPath);
      if (st.isDirectory) {
        // A folder without its trailing slash would make the page's relative
        // links resolve one level up.
        if (!wantsFolder) {
          return _send(res, 301, headers: {'location': uri.hasQuery ? '$rawPath/?${uri.query}' : '$rawPath/'});
        }
        rel = '${rel}index.html';
        st = await host.stat(_pathOf(rel));
      }
    } on Object catch (e) {
      final missing = e is RemoteFileException && e.kind == RemoteFileErrorKind.notFound;
      if (!missing) return _failure(res, e);
      // A single-page app's own route (`/about`): only a page navigation
      // without a file extension falls back to the app's entry page.
      final navigation =
          _extensionOf(decoded).isEmpty &&
          (WebBridgeHost._joined(req.headers, 'accept', ', ') ?? '').contains('text/html');
      if (!navigation) return _notFound(res, rawPath);
      try {
        rel = '/index.html';
        st = await host.stat(_pathOf(rel));
      } on Object {
        return _notFound(res, rawPath);
      }
    }
    if (!st.isFile) return _notFound(res, rawPath);
    final size = st.size;
    if (size == null) {
      return _errorPage(
        res,
        502,
        'Can’t serve this file',
        "<p>${WebBridgeHost._esc(site.machineName)} didn’t say how big the file is.</p>",
      );
    }

    final headers = <String, String>{'content-type': _contentTypeOf(rel), 'accept-ranges': 'bytes'};
    final modified = st.modified;
    if (modified != null) {
      final stamp = DateTime.fromMillisecondsSinceEpoch((modified.millisecondsSinceEpoch ~/ 1000) * 1000, isUtc: true);
      headers['last-modified'] = HttpDate.format(stamp);
      final since = WebBridgeHost._one(req.headers, 'if-modified-since');
      if (since != null) {
        DateTime? asked;
        try {
          asked = HttpDate.parse(since);
        } on Object {
          asked = null;
        }
        if (asked != null && !asked.isBefore(stamp)) {
          return _send(res, 304, headers: headers);
        }
      }
    }

    var start = 0;
    var last = size - 1;
    var code = 200;
    final range = WebBridgeHost._one(req.headers, 'range');
    if (range != null) {
      final m = RegExp(r'^bytes=(\d{0,15})-(\d{0,15})$').firstMatch(range.trim());
      if (m != null && (m[1]!.isNotEmpty || m[2]!.isNotEmpty)) {
        if (m[1]!.isEmpty) {
          start = math.max(0, size - int.parse(m[2]!));
        } else {
          start = int.parse(m[1]!);
          // An open-ended request (`bytes=N-`, what a media element sends) is
          // answered with at most [webBridgeOpenRange] bytes: a player that
          // went away mid-file otherwise still had the whole rest read over
          // SFTP, nothing tells this listener the peer vanished. The player
          // asks for the next piece when it needs it. A plain 200 stays whole.
          last = math.min<int>(last, m[2]!.isNotEmpty ? int.parse(m[2]!) : start + webBridgeOpenRange - 1);
        }
        if (start > last || start >= size) {
          return _send(res, 416, headers: {'content-range': 'bytes */$size'});
        }
        code = 206;
        headers['content-range'] = 'bytes $start-$last/$size';
      }
    }
    final length = size == 0 ? 0 : last - start + 1;
    if (head || length == 0) {
      return _send(res, code, headers: {...headers, 'content-length': '$length'});
    }

    final path = _pathOf(rel);
    // The first piece is read before the status line is sent, so an unreadable
    // file is a 403 or 502 and not a 200 with nothing in it.
    final firstWant = math.min(webBridgePiece, length);
    final Uint8List first;
    try {
      first = await host.read(path, start, firstWant);
    } on Object catch (e) {
      return _failure(res, e);
    }
    if (first.length != firstWant) {
      return _errorPage(
        res,
        502,
        'Can’t serve this file',
        '<p>The file changed while it was being read. Reload to retry.</p>',
      );
    }

    res.statusCode = code;
    res.bufferOutput = false;
    res.headers
      ..set('x-content-type-options', 'nosniff')
      ..set('referrer-policy', 'no-referrer')
      ..set('cache-control', 'no-cache');
    for (final e in headers.entries) {
      res.headers.set(e.key, e.value);
    }
    res.headers.set('content-length', '$length');

    var gone = false;
    unawaited(res.done.then((_) => gone = true, onError: (Object _) => gone = true));
    final pending = Queue<Future<Uint8List>>()..add(Future.value(first));
    var next = start + first.length;
    void topUp() {
      while (pending.length < webBridgeReadWindow && next <= last) {
        final n = math.min(webBridgePiece, last - next + 1);
        final piece = host.read(path, next, n);
        // Kept for later; a failure is handled when its turn comes.
        unawaited(piece.then((_) {}, onError: (Object _) {}));
        pending.add(piece);
        next += n;
      }
    }

    var pos = start;
    while (pos <= last) {
      if (gone) return;
      topUp();
      final want = math.min(webBridgePiece, last - pos + 1);
      final Uint8List piece;
      try {
        piece = await pending.removeFirst();
      } on Object {
        return _abort(res);
      }
      // A file that shrank while it was served: end the connection rather
      // than leave the browser waiting for bytes that do not exist.
      if (piece.length != want) return _abort(res);
      pos += want;
      res.add(piece);
      await res.flush();
    }
    await res.close();
  }
}

// ======================= port forward =======================

final class _ForwardBridge extends _Bridge {
  _ForwardBridge._(super.host, PortForward super.spec, super.token, this._server);

  final ServerSocket _server;
  final _connections = <Socket>{};

  PortForward get target => spec as PortForward;

  @override
  int get port => _server.port;

  static Future<_ForwardBridge> bind(WebBridgeHost host, PortForward spec, String token, int port) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    final bridge = _ForwardBridge._(host, spec, token, server);
    server.listen(bridge._accept, onError: (Object _) {});
    return bridge;
  }

  @override
  Future<void> closeListener() async {
    for (final s in _connections.toList()) {
      s.destroy();
    }
    await _server.close();
  }

  void _accept(Socket socket) {
    if (_connections.length >= webBridgeMaxConnections) {
      socket.destroy();
      return;
    }
    _connections.add(socket);
    begin();
    unawaited(
      _serveGuarded(socket).whenComplete(() {
        _connections.remove(socket);
        end();
      }),
    );
  }

  /// Whatever goes wrong with one connection ends that connection. This code
  /// runs in the transport isolate, where an error nobody caught ends the
  /// isolate and fails every request of the machine.
  Future<void> _serveGuarded(Socket socket) async {
    try {
      await _serve(socket);
    } on Object {
      socket.destroy();
    }
  }

  /// Index of the blank line that ends a request head, or -1.
  static int _indexOfHeadEnd(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static final _listenerCookie = RegExp(r'^herdr_\d+$');

  /// [bytes] (a request head and whatever body bytes came with it) without
  /// the `herdr_<digits>` cookies, which are this app's own credentials for
  /// its listeners: the browser sends every one it holds to every listener
  /// of the same host name, so the dev server on the machine received the
  /// tokens of other listeners, and, for a second machine's listener on a
  /// colliding port number, one machine received another machine's token.
  /// Every other cookie and every other byte stays as it was; a `Cookie`
  /// header left with nothing is dropped. Returns [bytes] itself when there is
  /// nothing to remove. Only the first request of a connection is rewritten:
  /// after it the stream is bytes both ways (a WebSocket upgrade is not HTTP
  /// any more), so a keep-alive connection carries the cookies of its later
  /// requests to the machine unchanged.
  static Uint8List _withoutListenerCookies(Uint8List bytes) {
    final end = _indexOfHeadEnd(bytes);
    if (end < 0) return bytes;
    // Latin-1 maps every byte to one character, so the head survives the
    // round trip untouched.
    final lines = latin1.decode(bytes.sublist(0, end)).split('\r\n');
    var changed = false;
    final kept = <String>[lines.first];
    for (final line in lines.skip(1)) {
      final colon = line.indexOf(':');
      if (colon <= 0 || line.substring(0, colon).trim().toLowerCase() != 'cookie') {
        kept.add(line);
        continue;
      }
      final pairs = line.substring(colon + 1).split(';');
      final remaining = [
        for (final p in pairs)
          if (!_listenerCookie.hasMatch(p.split('=').first.trim())) p,
      ];
      if (remaining.length == pairs.length) {
        kept.add(line);
        continue;
      }
      changed = true;
      if (remaining.any((p) => p.trim().isNotEmpty)) {
        kept.add('${line.substring(0, colon + 1)}${remaining.join(';')}');
      }
    }
    if (!changed) return bytes;
    return Uint8List.fromList([...latin1.encode(kept.join('\r\n')), ...Uint8List.sublistView(bytes, end)]);
  }

  Uint8List _response(int code, String reason, String body, {Map<String, String> headers = const {}}) {
    final bytes = utf8.encode(body);
    final h = {'content-length': '${bytes.length}', 'connection': 'close', 'cache-control': 'no-store', ...headers};
    final head = 'HTTP/1.1 $code $reason\r\n${[for (final e in h.entries) '${e.key}: ${e.value}\r\n'].join()}\r\n';
    return Uint8List.fromList([...latin1.encode(head), ...bytes]);
  }

  Uint8List _errorResponse(int code, String reason, String title, String body) =>
      _response(code, reason, WebBridgeHost._page(title, body), headers: {'content-type': 'text/html; charset=utf-8'});

  Future<void> _reply(Socket socket, Uint8List bytes) async {
    try {
      socket.add(bytes);
      await socket.flush();
    } on Object {
      // The browser went away.
    }
    socket.destroy();
  }

  Future<void> _serve(Socket socket) async {
    socket.setOption(SocketOption.tcpNoDelay, true);
    final buffer = BytesBuilder(copy: false);
    final head = Completer<Uint8List?>();
    final timer = Timer(host.headTimeout, () {
      if (!head.isCompleted) head.complete(null);
    });
    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        if (head.isCompleted) return;
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final i = _indexOfHeadEnd(bytes);
        if (i >= 0) {
          head.complete(bytes);
        } else if (bytes.length > 16 * 1024) {
          head.complete(null);
        }
      },
      onDone: () {
        if (!head.isCompleted) head.complete(null);
      },
      onError: (Object _) {
        if (!head.isCompleted) head.complete(null);
      },
      cancelOnError: true,
    );
    final bytes = await head.future;
    timer.cancel();
    if (bytes == null) {
      unawaited(sub.cancel());
      socket.destroy();
      return;
    }

    // From here the subscription keeps reading: a browser that leaves while the
    // machine is being dialed (15 s on a bad link) is noticed, and what it sent
    // after the head is held for the machine.
    final early = BytesBuilder(copy: false);
    final gone = Completer<void>();
    sub
      ..onData(early.add)
      ..onDone(() {
        if (!gone.isCompleted) gone.complete();
      })
      ..onError((Object _) {
        if (!gone.isCompleted) gone.complete();
      });

    // The head decides whether anything is dialed: a wrong name, a missing
    // token or the entry URL never reach the machine.
    final text = latin1.decode(bytes.sublist(0, _indexOfHeadEnd(bytes)));
    final lines = text.split('\r\n');
    final requestLine = lines.first.split(' ');
    final targetPath = requestLine.length > 1 ? requestLine[1] : '/';
    // A header sent twice is one value joined (cookies with `;`): the last
    // one must not hide the first, and two `Host` lines are not a name the
    // allowlist knows.
    final headers = <String, String>{};
    for (final line in lines.skip(1)) {
      final i = line.indexOf(':');
      if (i > 0) {
        final name = line.substring(0, i).trim().toLowerCase();
        final value = line.substring(i + 1).trim();
        final before = headers[name];
        headers[name] = before == null
            ? value
            : name == 'cookie'
            ? '$before; $value'
            : '$before, $value';
      }
    }
    Uri? parsed;
    try {
      parsed = Uri.parse(targetPath);
    } on FormatException {
      parsed = null;
    }
    if (!WebBridgeHost._hostAllowed(headers['host'], port)) {
      unawaited(sub.cancel());
      return _reply(
        socket,
        _errorResponse(403, 'Forbidden', 'Wrong address', '<p>This address is only for herdr-mobile.</p>'),
      );
    }
    // The entry URL is answered by the host's entry listener, on another port,
    // and never here: the browser reuses its connections to this port, and
    // what is written on one of them is the machine's, so an entry URL sent
    // here would reach the dev server (and its log) with the token in it. The
    // port number is what keeps the two apart, so this check is only the
    // answer for a hand-made request.
    if (parsed != null && parsed.path == '/__herdr/open') {
      unawaited(sub.cancel());
      return _reply(socket, _errorResponse(404, 'Not Found', 'Not found', WebBridgeHost._openText));
    }
    final cookieGood = WebBridgeHost._tokenOk(WebBridgeHost._cookie(headers['cookie'], 'herdr_$port'), token);
    if (!cookieGood && !host._siblingOrigin(headers, port)) {
      unawaited(sub.cancel());
      return _reply(socket, _errorResponse(403, 'Forbidden', 'Not allowed', WebBridgeHost._openText));
    }

    final SSHSocket channel;
    try {
      final dialing = host.dial(target.host, target.port);
      final first = await Future.any<SSHSocket?>([dialing, gone.future.then((_) => null)]);
      if (first == null) {
        // Nobody is waiting for the connection any more: it is closed when it comes.
        unawaited(dialing.then((c) => c.destroy(), onError: (Object _) {}));
        socket.destroy();
        return;
      }
      channel = first;
    } on Object catch (e) {
      unawaited(sub.cancel());
      final why = e is HerdrTransportException && e.fatal
          ? '<p>${WebBridgeHost._esc(e.message)}</p>'
          : "<p>Couldn’t reach <code>localhost:${target.port}</code> on ${WebBridgeHost._esc(target.machineName)}. "
                'The server may have stopped. Reload to retry.</p>';
      return _reply(socket, _errorResponse(502, 'Bad Gateway', "Couldn’t reach the server", why));
    }

    // From here on it is bytes both ways (keep-alive, WebSocket upgrades): one
    // connection is one client, so later requests on it are not looked at.
    final closed = Completer<void>();
    void finish() {
      if (!closed.isCompleted) closed.complete();
    }

    // The browser is read only as fast as the machine takes it. `sink.add`
    // never waits, so a browser sending at full speed (an upload) piled up in
    // memory (400 MiB sent through a forward held about 450 MiB). Everything
    // for the machine goes through [up], whose listener is the channel's
    // `addStream`: when the channel is backed up it pauses [up], and [up]
    // pauses the browser's subscription, so the kernel's socket buffers and
    // TCP flow control hold the rest. Pauses nest: nothing here may call
    // `sub.resume()` of its own, or it would undo the pause [up] asked for
    // (the first version did, and still read 64 MiB with the machine stalled).
    final up = StreamController<Uint8List>(onPause: sub.pause, onResume: sub.resume);
    // A browser that stops sending closes only its side: the machine gets the
    // end of the request (`sink.close`) and may still answer. A sink that
    // fails ends the whole connection.
    unawaited(
      channel.sink
          .addStream(up.stream)
          .then(
            (_) => channel.sink.close().catchError((Object _) {}),
            onError: (Object _) {
              channel.destroy();
              socket.destroy();
              finish();
            },
          ),
    );
    up.add(_withoutListenerCookies(bytes));
    final held = early.takeBytes();
    if (held.isNotEmpty) up.add(held);
    if (gone.isCompleted) unawaited(up.close());
    sub
      ..onData(up.add)
      ..onDone(() => unawaited(up.close()))
      ..onError((Object _) {
        channel.destroy();
        socket.destroy();
        finish();
      });
    unawaited(
      socket
          .addStream(channel.stream)
          .then((_) => socket.close(), onError: (Object _) => socket.destroy())
          .whenComplete(finish),
    );
    unawaited(channel.done.then((_) => finish(), onError: (Object _) => finish()));
    unawaited(socket.done.then((_) => finish(), onError: (Object _) => finish()));
    await closed.future;
    unawaited(sub.cancel().catchError((Object _) {}));
    unawaited(up.close());
    channel.destroy();
    socket.destroy();
  }
}
