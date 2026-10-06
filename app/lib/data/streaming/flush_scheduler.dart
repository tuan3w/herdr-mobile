import 'dart:async';

/// Stops a flush that was scheduled and has not run. Safe to call after it ran.
typedef FlushCancel = void Function();

/// When a session tells its listeners about what arrived since the last time.
///
/// A session coalesces: chunks, tool updates and the like only mark it dirty,
/// and one flush per frame notifies. The data layer cannot know what a frame
/// is, so the app injects it: `FrameFlush` (`ui/core/frame_flush.dart`) flushes
/// at the start of the next frame, before build; [TimerFlush] (the default, and
/// what tests use) flushes after a fixed delay and needs no binding.
abstract interface class FlushScheduler {
  /// Runs [flush] once, as soon as listeners can use it: before the next
  /// frame is built. Used while the app is in front.
  FlushCancel nextFrame(void Function() flush);

  /// Runs [flush] once after [delay], frame or no frame. Used when nobody is
  /// looking (the session is kept alive in the background, and frames do not
  /// run) and for the slow rate there.
  FlushCancel after(Duration delay, void Function() flush);
}

/// The scheduler without a frame: [nextFrame] is a [Timer] of [frame] (16 ms
/// by default, one frame at 60 Hz). What a session used before frames were
/// injected, and what tests with a `FakeAsync` clock rely on.
class TimerFlush implements FlushScheduler {
  const TimerFlush([this.frame = const Duration(milliseconds: 16)]);

  final Duration frame;

  @override
  FlushCancel nextFrame(void Function() flush) => after(frame, flush);

  @override
  FlushCancel after(Duration delay, void Function() flush) => Timer(delay, flush).cancel;
}
