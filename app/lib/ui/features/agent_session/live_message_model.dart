import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter/scheduler.dart';

import '../../../data/acp/live_text.dart';
import '../../../data/streaming/reveal_pacer.dart';
import '../../core/markdown/markdown.dart';

/// What the screen shows of the message that is streaming in right now: the
/// text that has been *revealed* so far, as a [StreamingMd] (frozen blocks and
/// an open tail), and the pacing that decides how fast it grows.
///
/// The transcript owns one per live message, not the row: the row that draws
/// it (`LiveMessageRow`) is built lazily and is gone when the reader scrolls
/// away, but the text keeps arriving, the blocks keep freezing (the "N new"
/// count) and nothing is shown late or twice when the reader comes back.
///
/// It listens to the message's [LiveText] (announced once per frame by the
/// session), hands what is new to a [RevealPacer], and appends what the pacer
/// lets through to [md]; it notifies when [md] grew. The pacer is driven by a
/// [Ticker] that exists only while the pacer holds text back: it starts when
/// text is held back and stops the frame the backlog is empty (never a loop).
///
/// **Snap** ([snap]: everything pending is shown at once, no animation) when
/// the owner says so (the app resumed, the person touched the transcript, the
/// switch Smooth text went off, the transcript is not on screen), or by itself
/// when the backlog passes the pacer's limit. Text that is already there when
/// the model is made is history: shown whole. The message ending needs no
/// snap: the transcript replaces the live row with the rows of the settled
/// message, which show all of it.
class LiveMessageModel extends ChangeNotifier {
  LiveMessageModel({required this.live, required TickerProvider vsync, this.onFrozen}) {
    _ticker = vsync.createTicker(_tick);
    md.append(live.text);
    _seen = live.length;
    _frozen = md.frozen.length;
    live.addListener(_onText);
  }

  /// The growing text of the message.
  final LiveText live;

  /// The revealed text, parsed.
  final StreamingMd md = StreamingMd();

  /// Rate and cuts; its snap and reduced-motion rules are documented there.
  final RevealPacer pacer = RevealPacer();

  /// Told when the number of frozen blocks changed.
  final void Function(int frozen)? onFrozen;

  late final Ticker _ticker;

  /// Characters of [live] handed to the pacer (or straight to [md]).
  int _seen = 0;
  int _frozen = 0;

  /// Ticker time of the last tick; null at the first tick of a run.
  Duration? _last;
  bool _disposed = false;

  /// With false (Smooth text off, or the transcript hidden) text is shown as
  /// it arrives.
  bool smooth = true;

  /// The system asks for less motion: whole lines instead of a rate.
  set reducedMotion(bool value) => pacer.reducedMotion = value;

  /// Blocks of the message that can no longer change.
  int get frozenBlocks => _frozen;

  /// The ticker runs: text is being held back and revealed at the pacer's pace.
  bool get isPacing => _ticker.isActive;

  /// The session announced text (once per frame): hand what is new to the
  /// pacer, and show the share it allows at once, in the frame the text
  /// arrived in.
  void _onText() {
    if (_disposed || live.length <= _seen) return;
    final fresh = live.tail(_seen);
    _seen = live.length;
    if (!smooth) {
      md.append(fresh);
      _shown();
      return;
    }
    final running = _ticker.isActive;
    pacer.append(fresh);
    // The first frame of a burst shows its share now; a running ticker does it
    // at its own tick.
    if (!running) _advance(pacer.frame);
    if (!pacer.isIdle && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    _advance(last == null ? pacer.frame : elapsed - last);
    if (pacer.isIdle) _stop();
  }

  void _advance(Duration dt) {
    final out = pacer.advance(dt);
    if (out.isEmpty) return;
    md.append(out);
    _shown();
  }

  void _stop() {
    if (_ticker.isActive) _ticker.stop();
    _last = null;
  }

  void _shown() {
    notifyListeners();
    final frozen = md.frozen.length;
    if (frozen != _frozen) {
      _frozen = frozen;
      onFrozen?.call(frozen);
    }
  }

  /// Shows everything pending, now, with no animation.
  void snap() {
    if (_disposed) return;
    _stop();
    final rest = pacer.snap();
    if (rest.isEmpty) return;
    md.append(rest);
    _shown();
  }

  @override
  void dispose() {
    _disposed = true;
    live.removeListener(_onText);
    _ticker.dispose();
    super.dispose();
  }
}
