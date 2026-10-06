import 'dart:async';

/// A periodic timer whose ticks fall on the multiples of [period] of the
/// clock, not [period] after it was started.
///
/// In the background every packet wakes the radio, and it stays awake for
/// seconds after the last one. Timers that each count their own period (one
/// per machine, one for the agent sessions) drift apart and each pays that
/// tail; ticks on a shared grid land together and pay it once. The clock is the
/// phone's, so every ticker of the app agrees without knowing the others.
class AlignedTicker {
  AlignedTicker(this.period, this._clock, this._onTick) {
    assert(period > Duration.zero);
    _arm();
  }

  final Duration period;
  final DateTime Function() _clock;
  final void Function() _onTick;

  Timer? _timer;
  bool _cancelled = false;

  /// The time from [now] to the next multiple of [period] since the epoch; a
  /// whole [period] when [now] is on one.
  static Duration untilNext(Duration period, DateTime now) {
    final p = period.inMicroseconds;
    return Duration(microseconds: p - now.microsecondsSinceEpoch % p);
  }

  void _arm() {
    _timer = Timer(untilNext(period, _clock()), () {
      if (_cancelled) return;
      _onTick();
      if (!_cancelled) _arm();
    });
  }

  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
  }
}
