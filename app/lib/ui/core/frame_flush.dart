import 'dart:async';

import 'package:flutter/scheduler.dart';

import '../../data/streaming/flush_scheduler.dart';

/// A [FlushScheduler] aligned to frames: [nextFrame] runs the flush as a
/// *transient frame callback*, which the engine calls at the start of the next
/// frame, before microtasks, build, layout and paint of that frame. A session
/// that flushes there notifies its listeners in time for them to `setState`
/// and be built in the very frame the chunks belong to: nothing lands a frame
/// late and nothing fires in the middle of a frame, which a `Timer(16 ms)`
/// cannot promise (it is not aligned to the vsync).
///
/// Chunks that arrive before the callback run are coalesced by the session
/// (one flush per frame, however many). A flush requested while the flush of
/// this frame is running belongs to the next frame.
///
/// While the app is hidden or paused the engine produces no frames, and a
/// frame callback would wait for the app to come back; [nextFrame] then falls
/// back to a timer of [hiddenDelay], so state that other parts of the app
/// listen to (notifications, the board) is not held until the person returns.
class FrameFlush implements FlushScheduler {
  FrameFlush({this._binding, this.hiddenDelay = const Duration(milliseconds: 250)});

  final SchedulerBinding? _binding;

  /// How long a flush waits when no frame will come.
  final Duration hiddenDelay;

  @override
  FlushCancel nextFrame(void Function() flush) {
    final binding = _binding ?? SchedulerBinding.instance;
    if (!binding.framesEnabled) return after(hiddenDelay, flush);
    final id = binding.scheduleFrameCallback((_) => flush());
    return () => binding.cancelFrameCallbackWithId(id);
  }

  @override
  FlushCancel after(Duration delay, void Function() flush) => Timer(delay, flush).cancel;
}
