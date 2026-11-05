import '../models/remote_file.dart';
import '../models/web_bridge.dart';
import '../services/herdr_transport.dart';

/// Why a page could not be opened on the phone, in words for the person:
/// `Couldn't open on this phone: <reason>.`
class WebPreviewException implements Exception {
  const WebPreviewException(this.message);

  final String message;

  /// The reason alone, as a sentence: `Cannot open a local port: no free
  /// port.`, for a place that already says what could not be opened.
  String get reason {
    const prefix = "Couldn’t open on this phone: ";
    if (!message.startsWith(prefix)) return message;
    final r = message.substring(prefix.length);
    return r.isEmpty ? message : r[0].toUpperCase() + r.substring(1);
  }

  @override
  String toString() => message;
}

/// A page shown through one of a machine's listeners, as the person knows it
/// on the machine: a dev server address ([url], with the machine's own port
/// even when the phone's listener got another) or a file of a served folder
/// ([file]). Never the phone's address, which carries no meaning elsewhere.
class MachinePage {
  const MachinePage.server(Uri this.url) : file = null;
  const MachinePage.file(String this.file) : url = null;

  /// `http://localhost:8790/page2.html`.
  final Uri? url;

  /// `/home/dev/site/page2.html`.
  final String? file;

  /// What Copy link (or Copy path) copies.
  String get address => url?.toString() ?? file!;

  /// Where it is, short: `localhost:8790`, or the file's name.
  String get place => switch (url) {
    final u? => u.hasPort ? '${u.host}:${u.port}' : u.host,
    null => RemotePath.basename(file!),
  };

  /// The page without a title: `localhost:8790/page2.html` (the root is the
  /// bare host and port), or the file's name.
  String get label => switch (url) {
    final u? => u.path.isEmpty || u.path == '/' ? place : '$place${u.path}',
    null => place,
  };
}

/// Gives the app a URL for something an agent made on a machine: an HTML
/// file from its folder (read over SFTP), or a dev server link on the
/// machine (carried over SSH). The URL is a loopback address the app listens
/// on (see `WebBridgeHost`), shown in the app (`WebPreviewScreen`) or, on
/// request, in the phone's browser.
class WebPreview {
  WebPreview(this._transport, {required this.machineName});

  final HerdrTransport _transport;

  /// Only for the pages the listener shows when something goes wrong.
  final String machineName;

  /// What each listener opened for this machine shows, by its port on the
  /// phone (a listener that came back on another port drops its old one),
  /// and the port of the entry listener that answers forwards' entry URLs:
  /// the pages of this machine an in-app page may go to.
  final _specs = <int, WebBridgeSpec>{};
  int? _forwardEntry;

  /// The phone's ports of every listener opened for this machine, the entry
  /// listener included.
  Set<int> get ports => {..._specs.keys, ?_forwardEntry};

  /// Whether a link can be opened on the phone through [forwardUrl]: plain
  /// `http` to the machine itself, spelled `localhost`, `127.0.0.1`, `[::1]`,
  /// `0.0.0.0` or `[::]`, with a port that exists. Not any other `127.x`
  /// address, `*.localhost` or `*.local`: a forward dials the host from the
  /// machine, so a `.local` name reaches other devices on its network and a
  /// row could read `localhost` while the machine dials `127.0.0.5`. An
  /// `https` address on the machine needs its certificate to name
  /// `localhost`, which a development one never does, so it stays copy-only.
  static bool canPreview(String url) {
    final uri = Uri.tryParse(url);
    return uri != null && _isPreviewLink(uri) && _portExists(uri);
  }

  static bool _isPreviewLink(Uri uri) => uri.scheme == 'http' && isPreviewHost(uri.host);

  static bool _portExists(Uri uri) => !uri.hasPort || (uri.port >= 1 && uri.port <= 65535);

  /// The URL that shows [file] in the browser: the listener serves the file's
  /// own folder (so the page's relative links work and nothing above that
  /// folder is ever asked for) and the URL opens [file] in it. Keeps
  /// [fragment] (`#section`) for the browser.
  Future<Uri> staticUrl(RemoteStat file, {String? fragment}) async {
    if (!_transport.supportsFiles) {
      throw const WebPreviewException('Files are not available on this machine.');
    }
    if (!RemotePath.isAbsolute(file.path)) {
      throw const WebPreviewException("Couldn’t open on this phone: the file’s location isn’t known.");
    }
    final info = await _open(StaticSite(RemotePath.parent(file.path), machineName: machineName));
    return _entry(info, '/${Uri.encodeComponent(file.name)}', fragment);
  }

  /// The URL that shows [link] (an address on the machine) in the browser.
  /// The page keeps talking to `localhost:<port>` as it was written to, so the
  /// listener takes the same port number whenever it is free. When it could
  /// not (another listener or app holds that number), [onNote] gets one
  /// sentence saying so: a page that hardcodes `localhost:<port>` then calls
  /// whatever holds the number, which may be another machine's listener.
  Future<Uri> forwardUrl(Uri link, {void Function(String note)? onNote}) async {
    if (_isPreviewLink(link) && !_portExists(link)) {
      throw WebPreviewException(_sentence('That port number isn’t valid.'));
    }
    if (!_isPreviewLink(link)) {
      throw const WebPreviewException("Couldn’t open on this phone: only http addresses on the machine can be opened.");
    }
    // Every spelling of the machine itself is one listener: the machine resolves
    // `localhost` to whichever of 127.0.0.1 and ::1 the server is on.
    const host = 'localhost';
    final target = link.hasPort ? link.port : 80;
    final info = await _open(PortForward(host, target, machineName: machineName));
    if (info.port != target) {
      onNote?.call('Opened on port ${info.port}: a page that expects localhost:$target may not work.');
    }
    final path = link.path.isEmpty ? '/' : link.path;
    return _entry(
      info,
      link.hasQuery ? '$path?${link.query}' : path,
      link.hasFragment ? _decoded(link.fragment) : null,
    );
  }

  /// [url], a page the phone shows from one of this machine's listeners, as
  /// it is on the machine; null for anything else, the entry URL included.
  MachinePage? machinePage(Uri url) {
    if (url.scheme != 'http' || !_isListenerHost(url.host) || isEntryUrl(url)) return null;
    return switch (_specs[url.port]) {
      PortForward(:final host, :final port) => MachinePage.server(url.replace(host: host, port: port)),
      StaticSite(:final root) => MachinePage.file(
        url.pathSegments.every((s) => s.isEmpty) ? root : RemotePath.join(root, url.pathSegments.join('/')),
      ),
      null => null,
    };
  }

  /// The entry URL that shows [url] (a page of one of this machine's
  /// listeners) again: the listener is asked for again, so one that stopped
  /// (10 minutes of nothing, or a new connection) starts, and the browser
  /// gets its cookie anew. For Retry after a failed load and for a page
  /// handed to the phone's browser, which has none of the app's cookies.
  Future<Uri> reopen(Uri url) async {
    final spec = url.scheme == 'http' && _isListenerHost(url.host) ? _specs[url.port] : null;
    if (spec == null) {
      throw const WebPreviewException("Couldn’t open on this phone: herdr didn’t open this page.");
    }
    final info = await _open(spec);
    final path = url.path.isEmpty ? '/' : url.path;
    return _entry(info, url.hasQuery ? '$path?${url.query}' : path, url.hasFragment ? _decoded(url.fragment) : null);
  }

  /// Whether [url] is the one URL that carries a listener's token
  /// (`/__herdr/open`), which sends the browser on to the page.
  static bool isEntryUrl(Uri url) => url.path == _entryPath;

  static const _entryPath = '/__herdr/open';

  /// The name a listener's cookie is set for (it also answers `127.0.0.1`,
  /// where a browser sends no cookie).
  static bool _isListenerHost(String host) => host == 'localhost';

  Future<WebBridgeInfo> _open(WebBridgeSpec spec) async {
    final WebBridgeInfo info;
    try {
      info = await _transport.openWebBridge(spec);
    } on HerdrTransportException catch (e) {
      throw WebPreviewException(_sentence(e.message));
    } on RemoteFileException catch (e) {
      throw WebPreviewException(_sentence(e.message));
    }
    _specs
      ..removeWhere((_, s) => s.key == spec.key)
      ..[info.port] = spec;
    if (info.entryPort != info.port) _forwardEntry = info.entryPort;
    return info;
  }

  /// A [Uri] holds its fragment encoded and encodes it again when it is built
  /// from a string.
  static String _decoded(String encoded) {
    try {
      return Uri.decodeComponent(encoded);
    } on FormatException {
      return encoded;
    }
  }

  /// `Couldn't open on this phone: <reason>.`, the reason without its own full
  /// stop and, when it starts with a word and not a name, in lower case.
  static String _sentence(String reason) {
    var r = reason.trim();
    if (r.endsWith('.')) r = r.substring(0, r.length - 1);
    if (r.length > 1 && r[0] == r[0].toUpperCase() && r[1] == r[1].toLowerCase() && r[1] != ' ') {
      r = r[0].toLowerCase() + r.substring(1);
    }
    return "Couldn’t open on this phone: $r.";
  }

  /// `http://localhost:<entryPort>/__herdr/open?t=<token>&to=<where>`: the one
  /// URL that carries the token. The listener on [WebBridgeInfo.entryPort]
  /// answers it with a cookie and a page that sends the browser on to [to] on
  /// [WebBridgeInfo.port]. A [fragment] rides in `to`: the browser keeps the
  /// entry URL's own fragment across a redirect, but not when a page sends it
  /// on (see `WebBridgeHost._enter`).
  static Uri _entry(WebBridgeInfo info, String to, String? fragment) => Uri(
    scheme: 'http',
    host: 'localhost',
    port: info.entryPort,
    path: _entryPath,
    queryParameters: {
      't': info.token,
      'to': fragment == null || fragment.isEmpty ? to : '$to${Uri(fragment: fragment)}',
    },
  );
}
