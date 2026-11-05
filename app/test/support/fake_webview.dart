import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'fake_network.dart';
import 'fake_transport.dart';
import 'memory_stores.dart';

/// A web view that behaves like Android's, as far as the page screen relies
/// on it: a linear history, a page's own navigations asked of the navigation
/// delegate (and, when let through, loaded again with `loadUrl`, which is
/// what the Android plugin does: a new history entry), and an entry URL that
/// sends the view on to its `to` on [pagePort] like the listener's
/// `Refresh: 0` page does.
class FakeWebView extends WebViewPlatform {
  FakeWebView({this.pagePort = 41234});

  /// The port the entry URL sends the view on to (the listener's).
  int pagePort;

  /// Every URL loaded, in order (the entry URLs included).
  final List<Uri> loaded = [];

  /// The `<title>` of a page, by URL; none for the rest.
  final Map<String, String> titles = {};

  /// Loads of these URLs fail as the main frame's ([WebResourceErrorType.connect]).
  final Set<String> failing = {};

  /// Loads of these URLs fail with this Chromium description and no type.
  final Map<String, String> _otherFailures = {};
  void failWith(String url, String description) => _otherFailures[url] = description;

  final List<String> history = [];
  int _at = -1;

  /// What the view shows now.
  String? get current => _at < 0 ? null : history[_at];

  /// Background colours set on the view, in order.
  final List<Color> backgrounds = [];

  bool javaScript = false;

  /// What the view draws for the page it shows (for screenshots); nothing
  /// when unset.
  Widget Function(BuildContext context, String? url)? paint;

  FakeNavigationDelegate? _delegate;

  /// Addresses that answer with a file: like the Android plugin, a load of
  /// one asks the delegate again for the same address (`onDownloadStart`)
  /// instead of starting a page. Capped, so a test that loops ends.
  final Set<String> downloads = {};

  /// Every address the delegate was asked about, in order.
  final List<String> asked = [];

  /// How many times each kind of stored state was cleared.
  int cookiesCleared = 0;
  int storageCleared = 0;
  int cacheCleared = 0;

  /// How many times the page was reloaded.
  int reloads = 0;

  /// A navigation Android does not ask about (a form POST): it loads.
  void land(String url) => _load(Uri.parse(url));

  /// The page's server asks for a user name and password, as the view does for
  /// a 401: the answer comes through [HttpAuthRequest.onProceed] or
  /// [HttpAuthRequest.onCancel].
  void askAuth(HttpAuthRequest request) => _delegate?.onHttpAuthRequest?.call(request);

  /// A single-page app's route: the address changes, no page loads.
  void pushState(String url) {
    history
      ..removeRange(_at + 1, history.length)
      ..add(url);
    _at = history.length - 1;
    _delegate?.onUrlChange?.call(UrlChange(url: url));
  }

  /// A load of [url] that has started and reached [progress] of 100, and
  /// goes no further: the page shown so far stays.
  void startLoading(String url, int progress) {
    _delegate?.onPageStarted?.call(url);
    _delegate?.onProgress?.call(progress);
  }

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) =>
      _FakeController(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      FakeNavigationDelegate(params);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(PlatformWebViewCookieManagerCreationParams params) =>
      _FakeCookies(params, this);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) =>
      _FakeWidget(params, this);

  /// The page asks for [url] (a link tapped, a script's `location`): what
  /// the delegate decides happens. Returns whether it was loaded.
  Future<bool> navigate(String url, {bool mainFrame = true}) async {
    asked.add(url);
    final decide = _delegate?.onNavigationRequest;
    final decision = decide == null
        ? NavigationDecision.navigate
        : await decide(NavigationRequest(url: url, isMainFrame: mainFrame));
    if (decision != NavigationDecision.navigate) return false;
    if (!mainFrame) return true;
    if (downloads.contains(url)) {
      if (asked.where((a) => a == url).length < 5) scheduleMicrotask(() => unawaited(navigate(url)));
      return true;
    }
    _load(Uri.parse(url));
    return true;
  }

  void _load(Uri url) {
    loaded.add(url);
    final s = url.toString();
    history
      ..removeRange(_at + 1, history.length)
      ..add(s);
    _at = history.length - 1;
    _show(s);
  }

  /// Back in the history, as Android does it: the page is shown again (an
  /// entry URL sends the view on again).
  void back() {
    if (_at <= 0) return;
    _at--;
    _show(history[_at]);
  }

  void _show(String s) {
    final d = _delegate;
    d?.onPageStarted?.call(s);
    d?.onUrlChange?.call(UrlChange(url: s));
    final other = _otherFailures[s];
    if (failing.contains(s) || other != null) {
      d?.onWebResourceError?.call(
        WebResourceError(
          errorCode: -6,
          description: other ?? 'net::ERR_CONNECTION_REFUSED',
          errorType: other == null ? WebResourceErrorType.connect : WebResourceErrorType.unknown,
          isForMainFrame: true,
          url: s,
        ),
      );
      d?.onPageFinished?.call(s);
      return;
    }
    d?.onProgress?.call(100);
    d?.onPageFinished?.call(s);
    final url = Uri.parse(s);
    if (url.path == '/__herdr/open') {
      final to = url.queryParameters['to'] ?? '/';
      // The listener's refresh, a navigation the page starts itself; a page
      // the view has left meanwhile (Back went on past it) refreshes nothing.
      final at = _at;
      scheduleMicrotask(() {
        if (_at == at && current == s) unawaited(navigate('http://localhost:$pagePort$to'));
      });
    }
  }

  /// Puts this view in place of the platform's for one test.
  static FakeWebView install({int pagePort = 41234}) {
    final view = FakeWebView(pagePort: pagePort);
    WebViewPlatform.instance = view;
    return view;
  }
}

class FakeNavigationDelegate extends PlatformNavigationDelegate {
  FakeNavigationDelegate(super.params) : super.implementation();

  NavigationRequestCallback? onNavigationRequest;
  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  ProgressCallback? onProgress;
  WebResourceErrorCallback? onWebResourceError;
  UrlChangeCallback? onUrlChange;
  HttpAuthRequestCallback? onHttpAuthRequest;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async =>
      this.onNavigationRequest = onNavigationRequest;

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async => this.onPageStarted = onPageStarted;

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async => this.onPageFinished = onPageFinished;

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async => this.onProgress = onProgress;

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async =>
      this.onWebResourceError = onWebResourceError;

  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async => this.onUrlChange = onUrlChange;

  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback onHttpAuthRequest) async =>
      this.onHttpAuthRequest = onHttpAuthRequest;
}

class _FakeController extends PlatformWebViewController {
  _FakeController(super.params, this.view) : super.implementation();

  final FakeWebView view;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async =>
      view.javaScript = javaScriptMode == JavaScriptMode.unrestricted;

  @override
  Future<void> setPlatformNavigationDelegate(covariant FakeNavigationDelegate handler) async =>
      view._delegate = handler;

  @override
  Future<void> setBackgroundColor(Color color) async => view.backgrounds.add(color);

  @override
  Future<void> loadRequest(LoadRequestParams params) async => view._load(params.uri);

  @override
  Future<String?> currentUrl() async => view.current;

  @override
  Future<String?> getTitle() async => view.titles[view.current];

  @override
  Future<bool> canGoBack() async => view._at > 0;

  @override
  Future<void> goBack() async => view.back();

  @override
  Future<void> reload() async {
    view.reloads++;
    final s = view.current;
    if (s != null) view._show(s);
  }

  @override
  Future<void> clearLocalStorage() async => view.storageCleared++;

  @override
  Future<void> clearCache() async => view.cacheCleared++;
}

class _FakeCookies extends PlatformWebViewCookieManager {
  _FakeCookies(super.params, this.view) : super.implementation();

  final FakeWebView view;

  @override
  Future<bool> clearCookies() async {
    view.cookiesCleared++;
    return true;
  }
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget(super.params, this.view) : super.implementation();

  final FakeWebView view;

  @override
  Widget build(BuildContext context) => view.paint?.call(context, view.current) ?? const SizedBox.expand();
}

/// A fleet with no machines, for a screen that holds the connections up
/// ([FleetRepository.holdAlive]) without a real fleet behind it.
FleetRepository emptyFleet() => FleetRepository(
  machines: MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore()),
  network: FakeNetwork(),
  connect: (profile, secrets) => MachineConnection(profile: profile, api: HerdrApi(FakeTransport())),
);

/// [child] under [fleet], as the app has it.
Widget withFleet(FleetRepository fleet, Widget child) => ChangeNotifierProvider.value(value: fleet, child: child);

/// A machine for page tests.
MachineConnection pageMachine(FakeTransport transport, {String label = 'build-box'}) => MachineConnection(
  profile: MachineProfile(id: 'm', label: label, host: 'h', username: 'u'),
  api: HerdrApi(transport),
  backoff: (_) => const Duration(hours: 1),
  pollInterval: const Duration(hours: 1),
);
