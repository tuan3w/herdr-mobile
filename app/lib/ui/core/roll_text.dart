import 'package:flutter/material.dart';

import 'motion.dart';
import 'tokens.dart';

/// Text whose changes roll: when [text] changes, the part that stayed the
/// same (the common start and end) holds still and only the changed middle
/// moves, the old leaving and the new arriving by [Motion.rollTravel] of the
/// font size, crossing in opacity over [Motion.settle]. Its width follows from
/// the old to the new. Up when a number rose, down when it fell.
///
/// For counts that bring news: a badge, the selection count. Never for a clock: a time that changes every second
/// would never rest.
///
/// At rest it is one plain [Text.rich] (so it finds and reads as its text) and
/// owns no running ticker: the controller runs once per change and stops.
/// Reduced motion swaps the text at once. A screen reader hears only the new
/// text.
class RollText extends StatefulWidget {
  const RollText({
    super.key,
    required this.text,
    this.style,
    this.upward,
    this.trailing,
    this.overflow = TextOverflow.ellipsis,
  });

  final String text;
  final TextStyle? style;

  /// Which way the change rolls; null infers it from the numbers in the old
  /// and new text (up when it rose, and up when there is no number).
  final bool? upward;

  /// Text after [text] in another style that never rolls (` · 2 to review`).
  final InlineSpan? trailing;
  final TextOverflow overflow;

  @override
  State<RollText> createState() => _RollTextState();
}

class _RollTextState extends State<RollText> with SingleTickerProviderStateMixin {
  // Created on the first change: a count that never changes holds one null.
  AnimationController? _controller;

  /// The text rolling away; null at rest.
  String? _from;
  bool _up = true;

  @override
  void didUpdateWidget(RollText old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    if (Motion.reduced(context)) {
      _controller?.stop();
      _from = null;
      return;
    }
    _from = old.text;
    _up = widget.upward ?? _rose(old.text, widget.text);
    (_controller ??= _create()).forward(from: 0);
  }

  AnimationController _create() => AnimationController(vsync: this, duration: Motion.settle)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) setState(() => _from = null);
    });

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  static final _number = RegExp(r'\d+');

  /// Whether the change reads as a rise: the changed numbers compared, else
  /// the first number of each text.
  static bool _rose(String from, String to) {
    final (p, s) = _common(from, to);
    int? n(String t) => int.tryParse(t);
    final a = n(from.substring(p, from.length - s)) ?? n(_number.firstMatch(from)?.group(0) ?? '');
    final b = n(to.substring(p, to.length - s)) ?? n(_number.firstMatch(to)?.group(0) ?? '');
    if (a == null || b == null) return true;
    return b >= a;
  }

  /// The lengths of the common start and the common end of [a] and [b], never
  /// overlapping. A number keeps its digits whole: `9` to `10` changes both.
  static (int, int) _common(String a, String b) {
    final max = a.length < b.length ? a.length : b.length;
    var p = 0;
    while (p < max && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    // Back off into a run of digits, so a number is replaced, not spliced.
    while (p > 0 && _digit(a, p - 1) && (_digit(a, p) || _digit(b, p))) {
      p--;
    }
    var s = 0;
    while (s < max - p && a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    while (s > 0 && _digit(a, a.length - s) && (_digit(a, a.length - s - 1) || _digit(b, b.length - s - 1))) {
      s--;
    }
    return (p, s);
  }

  static bool _digit(String t, int i) {
    if (i < 0 || i >= t.length) return false;
    final c = t.codeUnitAt(i);
    return c >= 0x30 && c <= 0x39;
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final from = _from;
    final controller = _controller;
    final plain = widget.trailing == null ? text : '$text${widget.trailing!.toPlainText()}';
    final Widget child;
    if (from == null || controller == null) {
      child = Text.rich(
        TextSpan(text: text, style: widget.style, children: [?widget.trailing]),
        maxLines: 1,
        overflow: widget.overflow,
      );
    } else {
      final (p, s) = _common(from, text);
      final style = DefaultTextStyle.of(context).style.merge(widget.style);
      child = Text.rich(
        TextSpan(
          style: widget.style,
          children: [
            TextSpan(text: text.substring(0, p)),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _Roll(
                animation: Motion.curved(controller),
                from: from.substring(p, from.length - s),
                to: text.substring(p, text.length - s),
                style: style,
                up: _up,
              ),
            ),
            TextSpan(text: text.substring(text.length - s)),
            ?widget.trailing,
          ],
        ),
        maxLines: 1,
        overflow: widget.overflow,
      );
    }
    return Semantics(label: plain, excludeSemantics: true, child: child);
  }
}

/// The changed middle while it rolls. Inside a [WidgetSpan] the paragraph
/// already scales it with the text, so it measures and draws unscaled.
class _Roll extends StatelessWidget {
  const _Roll({required this.animation, required this.from, required this.to, required this.style, required this.up});

  final Animation<double> animation;
  final String from;
  final String to;
  final TextStyle style;
  final bool up;

  double _width(String s) {
    final painter = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final a = _width(from);
    final b = _width(to);
    final travel = (style.fontSize ?? Type.body.fontSize!) * Motion.rollTravel * (up ? 1 : -1);
    Widget line(String s) => Text(
      s,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: style,
      textScaler: TextScaler.noScaling,
    );
    final old = line(from);
    final next = line(to);
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        return SizedBox(
          width: a + (b - a) * t,
          // Transforms move the paint only: the baseline, and so the line,
          // stay where the text sits at rest.
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Transform.translate(
                offset: Offset(0, -travel * t),
                child: Opacity(opacity: 1 - t, child: old),
              ),
              Transform.translate(
                offset: Offset(0, travel * (1 - t)),
                child: Opacity(opacity: t, child: next),
              ),
            ],
          ),
        );
      },
    );
  }
}
