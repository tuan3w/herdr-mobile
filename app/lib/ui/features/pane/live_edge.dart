import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';

/// How long the output has been stale, as the label says it: whole seconds up
/// to a minute, then minutes, then hours. `stale · 12s`.
String staleLabel(Duration since) {
  final seconds = since.inSeconds < 0 ? 0 : since.inSeconds;
  final text = seconds < 60
      ? '${seconds}s'
      : seconds < 3600
          ? '${seconds ~/ 60}m'
          : '${seconds ~/ 3600}h';
  return 'stale · $text';
}

/// The bottom edge of the terminal: a 2 px rule that says whether what is
/// shown is live.
///
/// - [streaming] (the last read brought new output): tinted with the accent;
/// - quiet (it found nothing new): the hairline;
/// - [stale] (the last read failed, or the link is down): `textMuted`, or the
///   danger colour when the read [failed], with a label, `stale · 12s`, for
///   the time since the last read that worked.
///
/// The label is the only thing that moves: while stale and on screen, one
/// timer a second redraws it. A live pane runs no timer and no ticker; the
/// timer goes when the pane stops being stale, goes off screen, or is disposed.
/// The owner dims the terminal text itself (it is not this widget's to cover).
class LiveEdge extends StatefulWidget {
  const LiveEdge({
    super.key,
    required this.stale,
    required this.failed,
    required this.streaming,
    required this.lastRead,
    this.now = DateTime.now,
  });

  final bool stale;

  /// A read failed (as opposed to the link being down, which the banner says).
  final bool failed;
  final bool streaming;

  /// When a read last succeeded. Asked for when the label is drawn.
  final DateTime? Function() lastRead;
  final DateTime Function() now;

  /// Height of the rule.
  static const ruleHeight = 2.0;

  @override
  State<LiveEdge> createState() => _LiveEdgeState();
}

class _LiveEdgeState extends State<LiveEdge> {
  Timer? _timer;
  var _onScreen = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A screen covered by another (a file opened over it) has tickers off.
    _onScreen = TickerMode.valuesOf(context).enabled;
    _syncTimer();
  }

  @override
  void didUpdateWidget(LiveEdge old) {
    super.didUpdateWidget(old);
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    final wanted = widget.stale && _onScreen && widget.lastRead() != null;
    if (!wanted) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer(const Duration(seconds: 1), _tick);
    }
  }

  void _tick() {
    _timer = null;
    if (!mounted) return;
    setState(() {});
    _syncTimer();
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final stale = widget.stale;
    final Color rule;
    if (stale) {
      rule = widget.failed ? ds.danger : ds.textMuted;
    } else if (widget.streaming) {
      rule = ds.accent.withValues(alpha: 0.6);
    } else {
      rule = ds.hairline;
    }
    final read = stale ? widget.lastRead() : null;
    return IgnorePointer(
      child: Stack(
        children: [
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: LiveEdge.ruleHeight,
            child: AnimatedContainer(
              duration: Motion.reduced(context) ? Duration.zero : Motion.standard,
              curve: Motion.easeOut,
              color: rule,
            ),
          ),
          if (read != null)
            Positioned(
              left: Gap.md,
              bottom: LiveEdge.ruleHeight + Gap.sm,
              child: Semantics(
                label: 'Output is stale',
                // The seconds change every second: not for a screen reader.
                excludeSemantics: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // Opaque: it floats over text.
                    color: ds.bg,
                    borderRadius: BorderRadius.circular(Radii.tile),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.sm, vertical: 2),
                    child: Text(
                      staleLabel(widget.now().difference(read)),
                      maxLines: 1,
                      style: Type.caption.copyWith(
                        color: widget.failed ? ds.dangerText : ds.textSecondary,
                        fontFeatures: Type.tabular,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
