import 'package:herdr_mobile/data/streaming/flush_scheduler.dart';

/// A [FlushScheduler] the test drives: nothing runs until [frame] (what the
/// engine does at the start of a frame) or [fire] (a timer) is called.
class FakeFlush implements FlushScheduler {
  final _frames = <_Entry>[];
  final _timers = <_Entry>[];

  /// Flushes waiting for the next frame.
  int get framesWaiting => _frames.length;

  /// Delays of the timers waiting, in the order they were asked for.
  List<Duration> get timersWaiting => [for (final e in _timers) e.delay!];

  var scheduledFrames = 0;
  var scheduledTimers = 0;

  @override
  FlushCancel nextFrame(void Function() flush) {
    scheduledFrames++;
    final e = _Entry(flush, null);
    _frames.add(e);
    return () => _frames.remove(e);
  }

  @override
  FlushCancel after(Duration delay, void Function() flush) {
    scheduledTimers++;
    final e = _Entry(flush, delay);
    _timers.add(e);
    return () => _timers.remove(e);
  }

  /// The start of a frame: every flush that waits for one runs, once.
  void frame() {
    final due = List.of(_frames);
    _frames.clear();
    for (final e in due) {
      e.flush();
    }
  }

  /// The timers fire (all of them, whatever their delay).
  void fire() {
    final due = List.of(_timers);
    _timers.clear();
    for (final e in due) {
      e.flush();
    }
  }
}

class _Entry {
  _Entry(this.flush, this.delay);

  final void Function() flush;
  final Duration? delay;
}
