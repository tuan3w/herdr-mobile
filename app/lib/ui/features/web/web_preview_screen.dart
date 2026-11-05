import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/models/web_bridge.dart';
import '../../../data/repositories/fleet_repository.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/web_preview.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/visible_text.dart';
import '../../support/open_link.dart';
import '../pane/link_sheet.dart';
import 'http_auth_sheet.dart';
import 'web_navigation.dart';

/// What a [WebPreviewScreen] shows.
sealed class WebPage {
  const WebPage();

  /// What the bar says before the page has a title of its own.
  String get label;

  /// What Copy link (or Copy path) copies before the page has loaded.
  String get address;
}

/// A dev server address on the machine (`http://localhost:8790/#b`). [name] is
/// what started it, when known (`python label_server.py --port 8765`).
final class ServerPage extends WebPage {
  const ServerPage(this.link, {this.name});

  final Uri link;
  final String? name;

  MachinePage get _page => MachinePage.server(link);

  @override
  String get label => _page.label;

  @override
  String get address => link.toString();
}

/// An HTML or SVG file on the machine, served from its own folder: [stat]
/// when it is known, else [path] (relative to [cwd]) looked up first.
final class FilePage extends WebPage {
  const FilePage(this.path, {this.cwd}) : stat = null;
  FilePage.stat(RemoteStat this.stat) : path = stat.path, cwd = null;

  final String path;
  final String? cwd;
  final RemoteStat? stat;

  @override
  String get label => RemotePath.basename(path);

  @override
  String get address => path;
}

/// Shows [page] of [machine] in herdr ([WebPreviewScreen]). The screen goes
/// up at once and asks the machine inside it.
Future<void> openWebPreview(BuildContext context, MachineConnection machine, WebPage page) {
  FocusManager.instance.primaryFocus?.unfocus();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => WebPreviewScreen(machine: machine, page: page),
    ),
  );
}

/// A page from a machine, shown inside herdr: a dev server on the machine's
/// `localhost`, or an HTML file from its folder, carried over the machine's
/// SSH connection by a loopback listener on the phone (`WebBridgeHost`).
///
/// Why inside herdr and not the phone's browser (what this used to do): in a
/// Custom Tab herdr went to the background, Android dropped its SSH
/// connection, and the page waited on "Opening…" forever. While this screen
/// is on the stack its machine's connection is held up
/// ([FleetRepository.holdAlive], with the Watching notice), so switching
/// apps or turning the screen off does not end the page either. Where that
/// cannot hold (no notice: refused, or iOS), a dropped connection is said on
/// the screen and the page comes back by itself when the machine does.
///
/// The view loads only this machine's listeners ([webNavigation]); a page of
/// the web is offered to the phone's browser on the person's tap, never opened
/// by a page's script. JavaScript runs (dev pages need it) with no channel to
/// the app, no file access and no third-party cookies; cookies, web storage
/// and the cache are cleared when the last such screen closes. `Open in
/// browser` in ⋯ hands the page to the phone's browser for what needs it (a
/// Google sign-in refuses embedded views).
class WebPreviewScreen extends StatefulWidget {
  const WebPreviewScreen({super.key, required this.machine, required this.page});

  final MachineConnection machine;
  final WebPage page;

  @override
  State<WebPreviewScreen> createState() => _WebPreviewScreenState();
}

enum _Phase {
  /// The machine is being asked for the listener.
  opening,

  /// The view loads, behind a cover, until the first page is in.
  loading,

  /// A page is shown.
  shown,
}

/// What went wrong, for the panel. The bar already names the page, so the
/// title does not.
typedef _Failure = ({String title, String message});

class _WebPreviewScreenState extends State<WebPreviewScreen> {
  /// Page screens open now, over every machine: the last one to close clears
  /// what the views kept ([_forget]).
  static var _open = 0;

  /// The first page screen to open clears, before its first load, what a
  /// process that was killed with a page open could not.
  late var _forgetFirst = _open == 0;

  late final WebViewController _view = _newView();
  late final Toaster _toaster = Toaster.of(context);
  VoidCallback? _release;

  var _phase = _Phase.opening;
  _Failure? _failure;

  /// The page that failed to load: what Retry opens again.
  Uri? _failedUrl;

  /// The machine's connection dropped while a page was shown: the page comes
  /// back by itself when it is live again.
  var _linkLost = false;

  /// The page shown (the phone's address).
  Uri? _url;
  String? _title;
  var _progress = 0;
  Timer? _titleTimer;

  /// How many pages of this screen's own sit behind the one shown in the
  /// view's history. Back goes back while there is one, and leaves when there
  /// is none, without a trip through the entry page the view keeps behind the
  /// first page (Android's plugin loads every navigation anew, so that entry
  /// stays in the history; landing on it would show "Opening…").
  var _behind = 0;

  /// The pages of this visit that [_behind] counts, oldest first, the one
  /// shown last, with their titles once read: what `Pages in this visit`
  /// lists (a long press on the page-back arrow). Only the newest
  /// [_visitCap] are kept; the steps back to one are counted from the end,
  /// so a list cut at its start still lands right.
  final _visit = <({Uri url, String? title})>[];
  static const _visitCap = 50;

  /// Steps still to take after the one under way, for a jump from the list
  /// to a page further back: one step per page, each after the last page is
  /// in (see [_onPageFinished]).
  var _stepsLeft = 0;

  /// The next page is the first after an entry page: it starts with [_carry]
  /// pages behind it.
  var _afterEntry = false;
  var _carry = 0;

  /// Back was asked of the view: a page it lands on that is an entry URL is
  /// not a page (see [_skipEntry]).
  var _goingBack = false;

  /// The view is on an entry URL: covered, so its "Opening…" never shows.
  var _atEntry = false;

  /// The last address let through, until a page starts: Android hands a
  /// download back as a second request for the same address, which loading
  /// would answer with the same download, forever.
  String? _pending;

  WebPreview get _web => widget.machine.web;

  @override
  void initState() {
    super.initState();
    _forgetFirst;
    _open++;
    widget.machine.addListener(_onLink);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // After the first frame: the hold tells the fleet's listeners, which
      // must not rebuild while this route is being built.
      _release = context.read<FleetRepository>().holdAlive(
        widget.machine.profile.id,
        page: '${widget.page.label} on ${widget.machine.profile.label}',
      );
      unawaited(_openPage());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // While nothing is shown the view is the screen's own colour, so no
    // white flashes in the dark; a page shown gets the web's own default.
    if (_phase != _Phase.shown) unawaited(_view.setBackgroundColor(context.ds.bg));
  }

  @override
  void dispose() {
    widget.machine.removeListener(_onLink);
    _titleTimer?.cancel();
    final release = _release;
    // Not inside the frame that unmounts this route: the hold tells the
    // fleet's listeners, which may rebuild.
    if (release != null) scheduleMicrotask(release);
    if (--_open == 0) unawaited(_forget(_view));
    super.dispose();
  }

  /// Clears the cookies, web storage (local storage, IndexedDB) and cache
  /// every page view keeps, for all sites. Why: storage is kept per origin,
  /// and an origin is the phone's `localhost:<port>`, which two machines can
  /// hold one after the other: one machine's page would read the other's
  /// storage and send its listener cookies. Service workers are not cleared
  /// (the plugin has no call for them).
  static Future<void> _forget(WebViewController view) async {
    try {
      await WebViewCookieManager().clearCookies();
      await view.clearLocalStorage();
      await view.clearCache();
    } on Object catch (e) {
      debugPrint('herdr: page storage not cleared: $e');
    }
  }

  WebViewController _newView() {
    final view = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onProgress: (p) {
            if (mounted && p != _progress) setState(() => _progress = p);
          },
          onUrlChange: (change) => _onUrl(change.url),
          onWebResourceError: _onError,
          onHttpAuthRequest: _onAuthRequest,
        ),
      );
    final android = view.platform;
    if (android is AndroidWebViewController) {
      unawaited(android.setAllowFileAccess(false));
      unawaited(android.setAllowContentAccess(false));
      unawaited(android.setGeolocationEnabled(false));
      unawaited(android.setMixedContentMode(MixedContentMode.neverAllow));
      final cookies = WebViewCookieManager().platform;
      if (cookies is AndroidWebViewCookieManager) unawaited(cookies.setAcceptThirdPartyCookies(android, false));
      // `window.open` cannot be turned off through the plugin; a new window
      // is asked of [_onNavigation] like any navigation and opens nowhere
      // the rule refuses.
    }
    return view;
  }

  // -- opening ---------------------------------------------------------------

  /// Asks the machine for the page ([at]: a page of it that failed, else the
  /// one this screen was opened for) and loads it. A page opened again starts
  /// its own history: Back leaves after it.
  Future<void> _openPage({Uri? at}) async {
    setState(() {
      _phase = _Phase.opening;
      _failure = null;
      _progress = 0;
    });
    try {
      if (_forgetFirst) {
        _forgetFirst = false;
        await _forget(_view);
      }
      final entry = at != null && _web.machinePage(at) != null ? await _web.reopen(at) : await _entryOf(widget.page);
      if (!mounted) return;
      setState(() => _phase = _Phase.loading);
      _carry = 0;
      await _view.loadRequest(entry);
    } on WebPreviewException catch (e) {
      _fail('Couldn’t open this page', e.reason, at ?? _url);
    } on RemoteFileException catch (e) {
      _fail(
        'Couldn’t open this page',
        e.kind == RemoteFileErrorKind.notFound
            ? '${visibleText(widget.page.label)} isn’t on the machine any more.'
            : visibleText(e.message),
        at,
      );
    } on Object catch (e) {
      debugPrint('herdr: page not opened: $e');
      _fail('Couldn’t open this page', 'Something went wrong on the phone. Retry tries again.', at);
    }
  }

  /// The entry URL of [page]: the only URL that carries the listener's token.
  Future<Uri> _entryOf(WebPage page) async {
    switch (page) {
      case ServerPage(:final link):
        return _web.forwardUrl(link, onNote: _toaster.show);
      case FilePage(:final stat?):
        return _web.staticUrl(stat);
      case FilePage(:final path, :final cwd):
        final files = widget.machine.files;
        if (!files.supported) throw const WebPreviewException('Files are not available on this machine.');
        return _web.staticUrl(await files.stat(await files.resolve(path, cwd: cwd)));
    }
  }

  void _fail(String title, String message, Uri? url) {
    if (!mounted) return;
    _goingBack = false;
    _stepsLeft = 0;
    setState(() {
      _failure = (title: title, message: message);
      _failedUrl = url;
      if (_phase == _Phase.opening) _phase = _Phase.loading;
    });
  }

  void _retry() => unawaited(_openPage(at: _failedUrl));

  /// The machine's connection went down or came back. A page shown over a
  /// connection that dropped (Android froze herdr without the notice, or the
  /// network went) cannot work, so the screen says so; back, the page opens
  /// again by itself.
  void _onLink() {
    if (!mounted) return;
    final live = widget.machine.isLive;
    if (!live && !_linkLost && _url != null) {
      setState(() {
        _linkLost = true;
        _failure = (
          title: 'Lost the connection to ${widget.machine.profile.label}',
          message: 'The page comes back by itself when herdr is connected again.',
        );
        _failedUrl = _url;
      });
    } else if (live && _linkLost) {
      _linkLost = false;
      unawaited(_openPage(at: _failedUrl));
    }
  }

  // -- the view's events -------------------------------------------------------

  NavigationDecision _onNavigation(NavigationRequest request) {
    final url = Uri.tryParse(request.url);
    if (url == null) return NavigationDecision.prevent;
    // Back reached an entry URL, which sends the view on again at once; Back
    // goes past it instead ([_skipEntry]).
    if (_goingBack && _atEntry) return NavigationDecision.prevent;
    switch (webNavigation(url, ports: _web.ports, mainFrame: request.isMainFrame)) {
      case WebNavigation.load:
        if (request.isMainFrame && _pending == request.url) {
          // A file: Android asks for it again instead of showing it.
          if (mounted) setState(() => _progress = 100);
          _toaster.show('That link is a file, and herdr doesn’t download files. Open in browser (⋯) can.');
          return NavigationDecision.prevent;
        }
        if (request.isMainFrame) _pending = request.url;
        return NavigationDecision.navigate;
      case WebNavigation.web:
        _offerWeb(url);
        return NavigationDecision.prevent;
      case WebNavigation.refuse:
        if (request.isMainFrame) _refused(url);
        return NavigationDecision.prevent;
    }
  }

  /// A page of the web the page wanted to go to. A script can ask for that
  /// without anyone's tap, so nothing opens by itself: the person is told
  /// where it leads and opens it in the phone's browser with a tap.
  void _offerWeb(Uri url) {
    _toaster.show(
      '${visibleText(url.host)} isn’t from ${widget.machine.profile.label}.',
      action: ToastAction('Open', () => unawaited(_openWeb(url))),
    );
  }

  /// [url] of the web in the phone's browser: `https` at once, plain `http`
  /// through the link sheet, which shows the whole address and says it is
  /// not encrypted.
  Future<void> _openWeb(Uri url) async {
    if (url.scheme == 'https') {
      if (!await openInBrowser(url.toString())) {
        _toaster.show('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
      }
    } else if (mounted) {
      await showLinkSheet(context, url.toString());
    }
  }

  /// Says why [url] did not open. Another port of the machine's `localhost`
  /// (a front end linking its API) is one deliberate tap away: the same
  /// forward `Open page` would open, never on its own.
  void _refused(Uri url) {
    final where = visibleText(url.hasPort ? '${url.host}:${url.port}' : url.host);
    if (WebPreview.canPreview(url.toString())) {
      final service = sensitiveServiceOf(url.hasPort ? url.port : 80);
      if (service != null) {
        _toaster.show('$where is a $service port. Open its link from the terminal if you mean to.');
        return;
      }
      _toaster.show('$where isn’t open on this phone.', action: ToastAction('Open', () => unawaited(_forward(url))));
      return;
    }
    if (isMachineLocalUrl(url.toString())) {
      _toaster.show('$where isn’t open on this phone.');
      return;
    }
    _toaster.show('herdr doesn’t open ${visibleText(url.scheme)}: links from a page.');
  }

  /// Another port of the machine, on the person's tap. Back from it returns
  /// to the page that linked it.
  Future<void> _forward(Uri link) async {
    if (!mounted) return;
    try {
      final entry = await _web.forwardUrl(link, onNote: _toaster.show);
      if (!mounted) return;
      _carry = _behind + 1;
      await _view.loadRequest(entry);
    } on WebPreviewException catch (e) {
      _toaster.show(e.message, kind: ToastKind.failed);
    }
  }

  // -- sign-in ----------------------------------------------------------------

  /// Requests for sign-in that arrived while the sheet is up (a page and the
  /// pictures on it ask together): they get the answer the sheet gets, so the
  /// person types once.
  List<HttpAuthRequest>? _authAsked;

  /// The page's server wants a user name and password (Basic or Digest: a
  /// dev server, or a reverse proxy in front of it). The view waits for an
  /// answer and shows nothing meanwhile, so every request is answered:
  /// dismissing the sheet, or leaving the screen, cancels it.
  void _onAuthRequest(HttpAuthRequest request) {
    final waiting = _authAsked;
    if (waiting != null) {
      waiting.add(request);
      return;
    }
    if (!mounted) {
      request.onCancel();
      return;
    }
    final asked = _authAsked = [request];
    unawaited(_askLogin(asked));
  }

  Future<void> _askLogin(List<HttpAuthRequest> asked) async {
    HttpLogin? login;
    try {
      login = await showHttpAuthSheet(
        context,
        where: widget.machine.profile.label,
        realm: asked.first.realm == null ? null : visibleText(asked.first.realm!),
      );
    } finally {
      _authAsked = null;
      for (final request in asked) {
        if (login == null) {
          request.onCancel();
        } else {
          request.onProceed(WebViewCredential(user: login.user, password: login.password));
        }
      }
    }
  }

  void _onPageStarted(String url) {
    _pending = null;
    final uri = Uri.tryParse(url);
    if (!mounted) return;
    setState(() {
      if (uri != null) _atEntry = WebPreview.isEntryUrl(uri);
      if (!_linkLost) _failure = null;
      _progress = 0;
    });
  }

  void _onPageFinished(String url) {
    final uri = Uri.tryParse(url);
    if (!mounted || uri == null || WebPreview.isEntryUrl(uri) || _failure != null) return;
    if (_phase != _Phase.shown) {
      // The web's default canvas: a page with no background of its own
      // expects white, as in any browser.
      // design-lint: allow(raw-color) the web's own default canvas, not a herdr surface
      unawaited(_view.setBackgroundColor(const Color(0xFFFFFFFF)));
      setState(() => _phase = _Phase.shown);
    }
    _onUrl(url);
    // A jump from the list goes on once the page a step landed on is in, not
    // on its address alone: a step taken at once would cut that page's load
    // short, and its late report would count as a page of its own.
    if (_stepsLeft > 0 && !_goingBack && uri == _url) {
      _stepsLeft--;
      unawaited(_stepBack());
    }
  }

  /// The view shows [url]: counts the page in [_behind] (once per change:
  /// a page's load reports its address twice), and reads its title.
  void _onUrl(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !mounted || uri.scheme == 'about') return;
    if (WebPreview.isEntryUrl(uri)) {
      _atEntry = true;
      if (_goingBack) {
        unawaited(_skipEntry());
      } else {
        _afterEntry = true;
      }
      return;
    }
    _atEntry = false;
    if (_goingBack) {
      _goingBack = false;
      if (_behind > 0) _behind--;
      if (_visit.isNotEmpty) _visit.removeLast();
      if (_visit.isEmpty || _visit.last.url != uri) {
        // A list cut at its start, or a page the count and the view disagree
        // on: the page shown is the newest either way.
        if (_visit.isNotEmpty) _visit.removeLast();
        _visit.add((url: uri, title: null));
      }
    } else if (_afterEntry) {
      _afterEntry = false;
      _stepsLeft = 0;
      _behind = _carry;
      // A page opened again starts its own visit; another port, opened from
      // a link, goes on with this one.
      if (_carry == 0) _visit.clear();
      _addToVisit(uri);
      _carry = 0;
    } else if (uri != _url) {
      _stepsLeft = 0;
      _behind++; // a link, a `#section`, a single-page app's route
      _addToVisit(uri);
    }
    setState(() => _url = uri);
    unawaited(_readTitle());
    // A single-page app sets its title after its route renders.
    _titleTimer?.cancel();
    _titleTimer = Timer(Dwell.titleSettle, () => unawaited(_readTitle()));
  }

  Future<void> _readTitle() async {
    final shown = _url;
    final title = await _view.getTitle();
    if (!mounted || shown == null || _url != shown) return;
    final usable = _usable(title, shown.toString());
    if (_visit.isNotEmpty && _visit.last.url == shown) _visit.last = (url: shown, title: usable);
    if (usable != _title) setState(() => _title = usable);
  }

  void _addToVisit(Uri url) {
    _visit.add((url: url, title: null));
    if (_visit.length > _visitCap) _visit.removeAt(0);
  }

  /// Back landed on an entry URL, the page that sends the view on with a
  /// cookie: it is no page of the machine, and showing it would send the
  /// person forward again. Back goes on past it, or leaves the screen when
  /// it was the first thing loaded.
  Future<void> _skipEntry() async {
    if (await _view.canGoBack()) {
      await _view.goBack();
    } else if (mounted) {
      _goingBack = false;
      Navigator.of(context).pop();
    }
  }

  void _onError(WebResourceError error) {
    if (error.isForMainFrame == false) return;
    final url = error.url == null ? _url : Uri.tryParse(error.url!);
    _fail('Couldn’t load this page', _why(error), url);
  }

  /// What a failed load means here, and what Retry does about it.
  String _why(WebResourceError error) {
    final machine = widget.machine.profile.label;
    return switch (error.errorType) {
      WebResourceErrorType.connect =>
        'herdr stopped serving it on this phone (after 10 minutes unused, or a new connection). Retry opens it again.',
      WebResourceErrorType.timeout => '$machine took too long to answer. Retry asks again.',
      WebResourceErrorType.io => 'The connection to $machine broke while the page loaded. Retry asks again.',
      WebResourceErrorType.redirectLoop => 'The page sends itself round in a loop. Retry asks again.',
      WebResourceErrorType.webContentProcessTerminated =>
        'The page stopped: its view ran out of memory or crashed. Retry opens it again.',
      _ when error.description.contains('EMPTY_RESPONSE') || error.description.contains('CONNECTION_CLOSED') =>
        'The server on $machine closed the connection without an answer. Is it still running? Retry asks again.',
      _ when error.description.contains('CONNECTION_RESET') =>
        'The connection to $machine broke while the page loaded. Retry asks again.',
      _ => 'It didn’t load. Retry asks again.',
    };
  }

  /// [title] when it names the page: not empty and not the address itself
  /// (what a page without a `<title>` reports).
  static String? _usable(String? title, String url) {
    final t = title?.trim();
    if (t == null || t.isEmpty || t == url || t.contains('://')) return null;
    return t;
  }

  // -- the person's actions ------------------------------------------------------

  /// The phone's Back goes back in the page's history first, then leaves,
  /// as a browser's does: what the person already knows keeps working. The
  /// bar's ✕ leaves at once ([_close]).
  Future<void> _back() async {
    if (_goingBack) return;
    if (_behind > 0 && await _view.canGoBack()) {
      await _stepBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  /// Leaves the page from any depth in one tap. Why: Back walked every page
  /// of the visit first, so ten links deep was ten presses back to the chat.
  /// `pop` passes the [PopScope] that holds the phone's Back for the pages.
  void _close() => Navigator.of(context).pop();

  /// [steps] pages back in this visit, never past its first page: the
  /// page-back arrow takes one, a row of `Pages in this visit` as many as it
  /// sits below the page shown.
  Future<void> _pageBack(int steps) async {
    if (_goingBack || _behind == 0 || steps < 1) return;
    if (!await _view.canGoBack()) return;
    _stepsLeft = (steps > _behind ? _behind : steps) - 1;
    await _stepBack();
  }

  Future<void> _stepBack() async {
    _goingBack = true;
    await _view.goBack();
  }

  /// A long press on the page-back arrow: the pages of this visit, newest
  /// first, the one shown marked `Here`; a tap on another goes back to it.
  /// The last row leaves, as ✕ does.
  void _showVisit() {
    final pages = _visit.reversed.toList();
    unawaited(
      showAppSheet<void>(
        context,
        builder: (ctx) {
          final ds = ctx.ds;
          return SheetScaffold(
            title: 'Pages in this visit',
            kind: SheetKind.list,
            // The rows bring their own gutter.
            bleed: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < pages.length; i++) ...[
                  if (i > 0) Hairline(indent: ListRow.textIndent()),
                  _visitRow(ctx, pages[i], steps: i),
                ],
                Hairline(indent: ListRow.textIndent()),
                ListRow(
                  title: 'Close page',
                  leading: Icon(LucideIcons.x, size: IconSize.lead, color: ds.textSecondary),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _close();
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// A page of the visit, [steps] back from the one shown: its title when
  /// known, over where it is; else where it is alone.
  Widget _visitRow(BuildContext ctx, ({Uri url, String? title}) page, {required int steps}) {
    final ds = ctx.ds;
    final where = visibleText(_web.machinePage(page.url)?.label ?? '${page.url.host}${page.url.path}');
    final title = page.title;
    final here = steps == 0;
    return ListRow(
      title: visibleText(title ?? where),
      subtitle: title == null ? null : where,
      leading: Icon(LucideIcons.globe, size: IconSize.lead, color: ds.textSecondary),
      trailing: here ? Text('Here', style: Type.label.copyWith(color: ds.textSecondary)) : null,
      onTap: () {
        Navigator.of(ctx).pop();
        if (!here) unawaited(_pageBack(steps));
      },
    );
  }

  MachinePage? get _shownPage => _url == null ? null : _web.machinePage(_url!);

  /// The page shown is not from the machine (a form a page posted to another
  /// site, which Android does not ask about).
  bool get _foreign => _url != null && _shownPage == null;

  void _showOptions() {
    final page = _shownPage;
    final foreign = _foreign;
    final isFile = !foreign && widget.page is FilePage;
    final ds = context.ds;
    // The whole link, as Copy link copies it: the bar's line is cut to fit,
    // and the person often wants to see (and check) the full address.
    final link = foreign ? _url.toString() : page?.address ?? widget.page.address;
    unawaited(
      showActionSheet(
        context,
        title: visibleText(link),
        actions: [
          // In ⋯ since the bar holds two actions (the page-back arrow and ⋯).
          SheetAction(
            label: 'Reload',
            icon: LucideIcons.rotateCw,
            unavailable: _failure != null
                ? 'Retry, under the message, opens it again.'
                : _phase == _Phase.opening
                ? 'The page is still opening.'
                : null,
            onTap: () => unawaited(_view.reload()),
          ),
          SheetAction(
            label: isFile ? 'Copy path' : 'Copy link',
            icon: LucideIcons.link,
            onTap: () => copyText(context, link, what: isFile ? 'Path copied' : 'Link copied'),
          ),
          SheetAction(
            label: 'Open in browser',
            icon: LucideIcons.externalLink,
            onTap: () => unawaited(foreign ? _openWeb(_url!) : _openInBrowser()),
          ),
        ],
        footer: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.sm),
            child: Text(
              'For a page that needs your browser, such as a sign-in. The browser’s copy works only while this screen stays open.',
              style: Type.caption.copyWith(color: ds.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// The page in the phone's browser, for what an embedded view cannot do
  /// (Google refuses sign-in in one). The browser has none of this view's
  /// cookies, so it gets an entry URL of its own; the page keeps working
  /// while this screen (and its hold on the connection) stays.
  Future<void> _openInBrowser() async {
    try {
      final url = _url;
      final entry = url != null && _web.machinePage(url) != null ? await _web.reopen(url) : await _entryOf(widget.page);
      if (!await openPreviewUrl(entry)) {
        _toaster.show('Couldn’t open on this phone: no browser could open it.', kind: ToastKind.failed);
      }
    } on WebPreviewException catch (e) {
      _toaster.show(e.message, kind: ToastKind.failed);
    } on RemoteFileException catch (e) {
      _toaster.show(visibleText(e.message), kind: ToastKind.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final page = _shownPage;
    final foreign = _foreign;
    final place =
        page?.place ??
        switch (widget.page) {
          ServerPage(:final link) => MachinePage.server(link).place,
          FilePage() => widget.page.label,
        };
    // An app the agent started says what it is (`python label_server.py`) where
    // the address `localhost:8790` said nothing; the address stays in `⋯`.
    final appName = !foreign && widget.page is ServerPage ? (widget.page as ServerPage).name : null;
    final title = visibleText(_title ?? (foreign ? _url!.host : appName ?? page?.label ?? widget.page.label));
    final address = foreign ? visibleText(_url!.host) : visibleText(appName ?? page?.label ?? place);
    final failure = _failure;
    final covered = failure != null || _phase != _Phase.shown || _atEntry;
    final loading = failure == null && _phase != _Phase.opening && _progress < 100;
    return PopScope(
      canPop: _behind == 0 && !_goingBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Scaffold(
        backgroundColor: ds.bg,
        body: Column(
          children: [
            AppTopBar(
              // The same bar as every other screen: a glyph, the title and a
              // `where` line. The globe in the glyph's place (where an agent
              // screen shows its status) says "a web page"; the line says where
              // it comes from, once (a title that is the address leaves the line
              // the machine's name). A page from another site shows that site's
              // host alone, never the machine's name. The whole link is in `⋯`.
              glyph: Icon(LucideIcons.globe, size: IconSize.row, color: ds.textSecondary),
              title: title,
              // A long command ends in an ellipsis: the machine leads, so it is never the part cut.
              subtitle: foreign
                  ? address
                  : address == title
                  ? widget.machine.profile.label
                  : appName != null
                  ? '${widget.machine.profile.label} · $address'
                  : '$address · ${widget.machine.profile.label}',
              // ✕ leaves from any depth; the arrow steps back through the
              // pages. Why two controls: Back alone walked every page, so ten
              // links deep was ten presses back to the chat.
              leading: CircleButton(icon: LucideIcons.x, tooltip: 'Close page', onPressed: _close),
              actions: [
                _PageBackButton(
                  canGoBack: _behind > 0,
                  onPressed: () => unawaited(_pageBack(1)),
                  onLongPress: _showVisit,
                ),
                CircleButton(icon: LucideIcons.ellipsis, tooltip: 'Page options', onPressed: _showOptions),
              ],
            ),
            _LoadBar(progress: loading ? _progress : null),
            Expanded(
              child: Padding(
                // The app is edge to edge: a page's own footer must not sit
                // under the gesture bar.
                padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
                child: Stack(
                  children: [
                    Positioned.fill(child: WebViewWidget(controller: _view)),
                    if (covered)
                      Positioned.fill(
                        child: ColoredBox(
                          color: ds.bg,
                          child: failure != null
                              ? ListView(
                                  padding: const EdgeInsets.all(Gap.lg),
                                  children: [
                                    StatusPanel(
                                      color: _linkLost ? ds.blocked : ds.danger,
                                      icon: _linkLost ? LucideIcons.unplug : LucideIcons.globe,
                                      title: failure.title,
                                      message: failure.message,
                                      liveRegion: true,
                                      trailing: AppButton(
                                        label: 'Retry',
                                        kind: AppButtonKind.secondary,
                                        compact: true,
                                        onPressed: _retry,
                                      ),
                                    ),
                                  ],
                                )
                              : _phase == _Phase.opening
                              ? const Center(child: BusySpinner())
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One page back in the visit; held, the visit's pages to jump back to. With
/// nothing behind the page shown it stays, dimmed, and says why.
class _PageBackButton extends StatelessWidget {
  const _PageBackButton({required this.canGoBack, required this.onPressed, required this.onLongPress});

  final bool canGoBack;
  final VoidCallback onPressed;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      hint: canGoBack ? 'Hold for the pages of this visit' : 'This is the first page of this visit',
      child: CircleButton(
        icon: LucideIcons.arrowLeft,
        tooltip: 'Previous page',
        onPressed: canGoBack ? onPressed : null,
        onLongPress: canGoBack ? onLongPress : null,
      ),
    ),
  );
}

/// The edge between herdr and the page: a hairline under the bar, always,
/// that fills with the accent from the left as a page loads ([progress] of
/// 100) and is plain again when it is in. It moves only with real progress:
/// no loop.
class _LoadBar extends StatelessWidget {
  const _LoadBar({required this.progress});

  final int? progress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final p = progress;
    return SizedBox(
      height: Gap.hair,
      child: ColoredBox(
        color: ds.hairline,
        child: p == null
            ? null
            : Align(
                alignment: Alignment.centerLeft,
                child: AnimatedFractionallySizedBox(
                  duration: Motion.of(context, Motion.standard),
                  curve: Motion.easeOut,
                  widthFactor: p.clamp(0, 100) / 100,
                  heightFactor: 1, // the hairline's own height; Align alone would give none
                  child: ColoredBox(color: ds.accent),
                ),
              ),
      ),
    );
  }
}
