import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/services/herdr_api.dart' show ReadSource;
import '../../../data/services/herdr_transport.dart';

/// Reads a pane's text from the given herdr source.
typedef PaneReader = Future<PaneRead> Function(ReadSource source);

/// Live tail of one pane plus the ability to type into it.
///
/// Reads are driven by herdr's `pane.updated` events, throttled (busy agents
/// emit continuously, so a debounce would never fire), with a slow poll as a
/// backstop for lost events. Nothing runs while the app is not resumed.
///
/// In [wrap] mode the pane is read as `recent_unwrapped` (herdr joins the rows
/// the terminal soft-wrapped, leaving one logical line per line, for the view
/// to re-flow to the screen); otherwise as `recent`, the terminal's own rows.
class PaneViewModel extends ChangeNotifier with WidgetsBindingObserver {
  PaneViewModel({
    required Stream<String> activity,
    required this.paneId,
    required this._read,
    required this._sendLine,
    required this._sendKeys,
    this.minReadInterval = const Duration(milliseconds: 120),
    this.fallbackInterval = const Duration(seconds: 4),
    this._wrap = false,
  }) {
    WidgetsBinding.instance.addObserver(this);
    // The fallback poll covers a failed activity stream.
    _activity = activity.listen(_onActivity, onError: (Object _) {});
    _schedule();
  }

  final String paneId;
  final PaneReader _read;
  final Future<void> Function(String text) _sendLine;
  final Future<void> Function(List<String> keys) _sendKeys;

  /// Minimum time between the starts of two reads.
  final Duration minReadInterval;

  /// Longest time without a read while the pane is on screen.
  final Duration fallbackInterval;

  late final StreamSubscription<String> _activity;
  Timer? _cooldown;
  Timer? _fallback;
  bool _inFlight = false;

  /// Activity (or a send) arrived while a read was running or cooling down;
  /// one trailing read will pick it up.
  bool _pending = false;
  bool _active = true;
  bool _fatal = false;
  bool _disposed = false;
  bool _wrap;

  String _text = '';
  String? _error;
  bool _stale = false;
  bool _sending = false;

  String get text => _text;
  String? get error => _error;
  bool get sending => _sending;

  /// The last read failed, so [text] may be out of date.
  bool get isStale => _stale;

  /// Reads now (still throttled), and retries after a fatal failure.
  void refresh() {
    _fatal = false;
    _schedule();
  }

  /// Whether the pane is read unwrapped, for the view to wrap to the screen.
  bool get wrap => _wrap;

  /// Switches between the terminal's own rows and unwrapped lines, and reads
  /// from the new source right away (not after the throttle interval).
  void setWrap(bool value) {
    if (value == _wrap) return;
    _wrap = value;
    _cooldown?.cancel();
    _cooldown = null;
    _fatal = false;
    if (_inFlight) {
      _pending = true;
    } else {
      _schedule();
    }
    notifyListeners();
  }

  void _onActivity(String id) {
    if (id == paneId) _schedule();
  }

  void _schedule() {
    if (_disposed || !_active || _fatal) return;
    if (_inFlight || _cooldown != null) {
      _pending = true;
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    _inFlight = true;
    _pending = false;
    _fallback?.cancel();
    _fallback = null;
    _cooldown = Timer(minReadInterval, _cooledDown);
    final wrap = _wrap;
    try {
      final read = await _read(wrap ? ReadSource.recentUnwrapped : ReadSource.recent);
      // The mode changed while reading: this is the other source's text, and
      // setWrap already queued a read of the right one.
      if (wrap == _wrap) _apply(text: read.text, error: null, stale: false);
    } on HerdrApiException catch (e) {
      if (wrap == _wrap) _apply(error: e.toString(), stale: true);
    } on HerdrTransportException catch (e) {
      if (wrap == _wrap) {
        _fatal = e.fatal;
        _apply(error: e.message, stale: true);
      }
    } finally {
      _inFlight = false;
      if (!_disposed && _active && !_fatal) {
        _fallback = Timer(fallbackInterval, _schedule);
        if (_pending && _cooldown == null) unawaited(_run());
      }
    }
  }

  void _cooledDown() {
    _cooldown = null;
    if (_pending && !_inFlight) _schedule();
  }

  /// Keeps the previous text when a read fails. Listeners are only told when
  /// something they can see changed.
  void _apply({String? text, required String? error, required bool stale}) {
    if (_disposed) return;
    final changed =
        (text != null && text != _text) || error != _error || stale != _stale;
    if (text != null) _text = text;
    _error = error;
    _stale = stale;
    if (changed) notifyListeners();
  }

  /// Types [text] and presses enter.
  Future<bool> sendLine(String text) => _send(() => _sendLine(text));

  /// Sends herdr key-combo strings (`esc`, `ctrl+c`, `up` …).
  Future<bool> sendKeys(List<String> keys) => _send(() => _sendKeys(keys));

  Future<bool> _send(Future<void> Function() action) async {
    _sending = true;
    notifyListeners();
    try {
      await action();
      refresh();
      return true;
    } on HerdrApiException catch (e) {
      _error = e.toString();
      return false;
    } on HerdrTransportException catch (e) {
      _error = e.message;
      return false;
    } finally {
      _sending = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _active) return;
    _active = active;
    if (active) {
      refresh();
    } else {
      _cooldown?.cancel();
      _cooldown = null;
      _fallback?.cancel();
      _fallback = null;
      _pending = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_activity.cancel());
    _cooldown?.cancel();
    _fallback?.cancel();
    super.dispose();
  }
}
