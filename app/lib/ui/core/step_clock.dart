import 'dart:async';

import 'package:flutter/widgets.dart';

/// A shared, low-rate clock. One timer serves every widget that listens, it
/// only runs while at least one widget holds a lease, and it stops while the
/// app is in the background.
///
/// Two instances exist, both deliberately slow:
/// - [glyph]: 4 steps per second, the turn of a working agent's arc. Discrete
///   steps instead of a 60 fps animation: the painted area is a 20 px glyph in
///   its own repaint boundary, so a step re-records a handful of draw calls and
///   re-rasterises that glyph only.
/// - [minute]: twice a minute, for "working 12m" labels.
///
/// Leases are taken with [StepClockLease] (a widget state mixin) so a widget
/// only runs the clock while it is mounted, on screen and (for motion) not
/// under reduced motion.
class StepClock {
  StepClock(this.period);

  /// The arc of a working status glyph: at most 4 steps a second.
  static final glyph = StepClock(const Duration(milliseconds: 250));

  /// Elapsed-time labels: minute resolution, polled twice a minute.
  static final minute = StepClock(const Duration(seconds: 30));

  final Duration period;

  /// Counts steps. Listen for repaints or rebuilds.
  final ValueNotifier<int> steps = ValueNotifier(0);

  int _leases = 0;
  Timer? _timer;
  _Lifecycle? _observer;

  /// True while the timer is running (tests and diagnostics).
  bool get running => _timer != null;

  /// Number of active leases.
  int get leases => _leases;

  void acquire() {
    if (_leases++ == 0) {
      final observer = _observer = _Lifecycle(this);
      WidgetsBinding.instance.addObserver(observer);
      final state = WidgetsBinding.instance.lifecycleState;
      // Starting happens mid-build (a widget just mounted): do not notify.
      if (state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive) {
        _start(notify: false);
      }
    }
  }

  void release() {
    assert(_leases > 0, 'release without acquire');
    if (--_leases == 0) {
      _stop();
      if (_observer case final o?) WidgetsBinding.instance.removeObserver(o);
      _observer = null;
    }
  }

  void _start({required bool notify}) {
    if (_timer != null || _leases == 0) return;
    _timer = Timer.periodic(period, (_) => steps.value++);
    // Back from the background every label is stale: step once now.
    if (notify) steps.value++;
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}

class _Lifecycle with WidgetsBindingObserver {
  _Lifecycle(this.clock);

  final StepClock clock;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden || AppLifecycleState.detached:
        clock._stop();
      case AppLifecycleState.resumed:
        clock._start(notify: true);
      case AppLifecycleState.inactive:
        // Transient (a permission dialog, split screen): still visible.
        break;
    }
  }
}

/// Keeps a [StepClock] running while this widget is mounted, visible and
/// [wantsClock]. "Visible" is `TickerMode`: a tab that is not on screen, or a
/// route covered by another, switches its tickers off, and so the clock.
///
/// The lease is re-evaluated whenever dependencies change (`TickerMode`,
/// `MediaQuery`); call [syncClock] too if [wantsClock] can change otherwise.
/// It is released on dispose.
mixin StepClockLease<T extends StatefulWidget> on State<T> {
  StepClock get clock;

  /// Whether this widget wants ticks at all. Glyph arcs say false under
  /// reduced motion; labels always want them.
  bool get wantsClock => true;

  bool _leased = false;

  void syncClock() {
    final want = wantsClock && TickerMode.valuesOf(context).enabled;
    if (want == _leased) return;
    _leased = want;
    want ? clock.acquire() : clock.release();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    syncClock();
  }

  @override
  void dispose() {
    if (_leased) {
      _leased = false;
      clock.release();
    }
    super.dispose();
  }
}

/// Rebuilds [builder] once per step of [StepClock.minute]; the label it draws
/// ("working 12m") therefore moves by the minute, never per second.
class MinuteBuilder extends StatefulWidget {
  const MinuteBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, DateTime now) builder;

  @override
  State<MinuteBuilder> createState() => _MinuteBuilderState();
}

class _MinuteBuilderState extends State<MinuteBuilder> with StepClockLease<MinuteBuilder> {
  @override
  StepClock get clock => StepClock.minute;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: clock.steps,
        builder: (context, _, _) => widget.builder(context, DateTime.now()),
      );
}
