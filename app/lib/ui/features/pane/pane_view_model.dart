import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/services/herdr_api.dart' show ReadSource;
import '../../../data/services/herdr_transport.dart';
import '../../core/terminal_view.dart' show TerminalTop;
import 'scrollback_history.dart';

/// Rows requested by the live tail: cheap enough to read every 120 ms.
const _tailRows = 300;

/// The most rows herdr serves in one read (it clamps `lines` to this). A read
/// this deep is ~250 KB and runs on herdr's main loop, so it is only made
/// while the user is reading back, and not at the tail's pace.
const _serverRows = 1000;

/// Reads `lines` rows of a pane from the given herdr source.
typedef PaneReader = Future<PaneRead> Function(ReadSource source, int lines);

/// Live tail of one pane plus the ability to type into it.
///
/// Reads are driven by herdr's `pane.updated` events, throttled (busy agents
/// emit continuously, so a debounce would never fire), with a slow poll as a
/// backstop for lost events. Nothing runs while the app is not resumed.
///
/// The tail is [_tailRows] rows. When the user scrolls near the top of what is
/// loaded and herdr has more, reads go [_serverRows] deep until they have
/// been back at the newest row for [deepRevertDelay]; while deep, reads are at
/// most one per [deepReadInterval]. Rows that scroll off the top of the window
/// are kept (see [ScrollbackHistory]), so the user can scroll back further
/// than herdr serves, for as long as the screen is open.
///
/// A pane that is not the visible tab is [pause]d: it stops reading, keeps what
/// it has (text, history), and [resume] reads at once.
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
    this.deepReadInterval = const Duration(milliseconds: 1500),
    this.deepRevertDelay = const Duration(seconds: 2),
    this.fallbackInterval = const Duration(seconds: 4),
    this._wrap = false,
  }) {
    WidgetsBinding.instance.addObserver(this);
    // The fallback poll covers a failed activity stream.
    _activity = activity.listen(_onActivity, onError: (Object _) {});
    _schedule();
  }

  /// The pane [paneId] of [machine]. This is the one place the pane screen
  /// reaches the machine's API: the widget tree only sees the view model.
  factory PaneViewModel.forMachine(
    MachineConnection machine,
    String paneId, {
    required bool wrap,
  }) =>
      PaneViewModel(
        activity: machine.paneActivity,
        paneId: paneId,
        read: (source, lines) => machine.api.readPane(
          paneId,
          source: source,
          lines: lines,
          ansi: true,
        ),
        sendLine: (text) => machine.api.sendLine(paneId, text),
        sendKeys: (keys) => machine.api.sendKeys(paneId, keys),
        wrap: wrap,
      );

  final String paneId;
  final PaneReader _read;
  final Future<void> Function(String text) _sendLine;
  final Future<void> Function(List<String> keys) _sendKeys;

  /// Minimum time between the starts of two reads of the tail.
  final Duration minReadInterval;

  /// Minimum time between the starts of two deep reads.
  final Duration deepReadInterval;

  /// How long the user stays at the newest row before reads are shallow again.
  final Duration deepRevertDelay;

  /// Longest time without a read while the pane is on screen.
  final Duration fallbackInterval;

  late final StreamSubscription<String> _activity;
  Timer? _cooldown;
  bool _cooldownDeep = false;
  Timer? _revert;
  Timer? _fallback;
  bool _inFlight = false;

  /// Activity (or a send) arrived while a read was running or cooling down;
  /// one trailing read will pick it up.
  bool _pending = false;
  bool _active = true;

  /// Not the visible tab: no reads until [resume].
  bool _paused = false;
  bool _fatal = false;
  bool _disposed = false;
  bool _wrap;

  /// Reads go [_serverRows] deep.
  bool _deep = false;

  /// The history belongs to the source it was read from; the next read of
  /// another one starts it afresh.
  bool _resetHistory = false;
  final _history = ScrollbackHistory();

  String? _error;
  bool _stale = false;
  bool _sending = false;

  /// The live window: what the last read returned, as raw text. The rows above
  /// it are [history].
  String get text => _history.window;

  /// Rows that scrolled off the top of [text], oldest first. The same list
  /// while nothing changed.
  List<String> get history => _history.rows;

  /// What the view says above the first row.
  TerminalTop get top {
    if (_history.dropped > 0) return TerminalTop.localLimit;
    if (!_history.truncated) return TerminalTop.none;
    return _loadable ? TerminalTop.loading : TerminalTop.serverLimit;
  }

  /// herdr has older rows that a deeper read would add.
  bool get _loadable =>
      _history.truncated && _history.contiguousRows < _serverRows;

  String? get error => _error;
  bool get sending => _sending;

  /// The last read failed, so [text] may be out of date.
  bool get isStale => _stale;

  /// Whether reads are suspended because the pane is not on screen.
  bool get paused => _paused;

  /// The pane left the screen (a background tab): stops reading. What was read
  /// stays, so coming back shows it while the next read is under way.
  void pause() {
    if (_paused || _disposed) return;
    _paused = true;
    _cooldown?.cancel();
    _cooldown = null;
    _fallback?.cancel();
    _fallback = null;
    _pending = false;
  }

  /// The pane is on screen again: reads now, without waiting out the interval.
  void resume() {
    if (!_paused || _disposed) return;
    _paused = false;
    _cooldown?.cancel();
    _cooldown = null;
    refresh();
  }

  /// Reads now (still throttled), and retries after a fatal failure.
  void refresh() {
    _fatal = false;
    _schedule();
  }

  /// Where the user is in the loaded rows, as the view reports it. Near the
  /// top, with older rows to fetch, starts deep reads at once; at the newest
  /// row for [deepRevertDelay] ends them.
  ///
  /// Does not notify: the view reports while it lays out.
  void viewChanged({required bool nearTop, required bool following}) {
    if (nearTop && _loadable && !_deep) {
      _deep = true;
      // A deep read is not due at the tail's pace, but this one is wanted now.
      if (!_cooldownDeep) {
        _cooldown?.cancel();
        _cooldown = null;
      }
      _schedule();
    }
    if (_deep && following && !nearTop) {
      _revert ??= Timer(deepRevertDelay, () {
        _revert = null;
        _deep = false;
      });
    } else {
      _revert?.cancel();
      _revert = null;
    }
  }

  /// Whether the pane is read unwrapped, for the view to wrap to the screen.
  bool get wrap => _wrap;

  /// Switches between the terminal's own rows and unwrapped lines, and reads
  /// from the new source right away (not after the throttle interval).
  void setWrap(bool value) {
    if (value == _wrap) return;
    _wrap = value;
    _resetHistory = true;
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
    if (_disposed || !_active || _paused || _fatal) return;
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
    final deep = _deep;
    _cooldownDeep = deep;
    _cooldown = Timer(deep ? deepReadInterval : minReadInterval, _cooledDown);
    final wrap = _wrap;
    try {
      final read = await _read(
        wrap ? ReadSource.recentUnwrapped : ReadSource.recent,
        deep ? _serverRows : _tailRows,
      );
      // The mode changed while reading: this is the other source's text, and
      // setWrap already queued a read of the right one.
      if (wrap == _wrap) _apply(read: read, error: null, stale: false);
    } on HerdrApiException catch (e) {
      if (wrap == _wrap) _apply(error: e.toString(), stale: true);
    } on HerdrTransportException catch (e) {
      if (wrap == _wrap) {
        _fatal = e.fatal;
        _apply(error: e.message, stale: true);
      }
    } finally {
      _inFlight = false;
      if (!_disposed && _active && !_paused && !_fatal) {
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
  void _apply({PaneRead? read, required String? error, required bool stale}) {
    if (_disposed) return;
    var changed = error != _error || stale != _stale;
    if (read != null) {
      final before = _history.revision;
      if (_resetHistory) {
        _history.clear();
        _resetHistory = false;
      }
      _history.update(read.text, truncated: read.truncated);
      if (_history.revision != before) changed = true;
    }
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
    _revert?.cancel();
    _fallback?.cancel();
    super.dispose();
  }
}
