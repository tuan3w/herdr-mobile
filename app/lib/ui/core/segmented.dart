import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'press.dart';

class SegmentOption<T> {
  const SegmentOption(this.value, this.label, {this.icon, this.count, this.leading, this.semanticLabel});

  final T value;
  final String label;
  final IconData? icon;

  /// A number after the label (`Pages 17`), muted, in tabular figures.
  final int? count;

  /// A small widget before the label (a live dot). Not drawn with an [icon].
  final Widget? leading;

  /// What a screen reader says for this option instead of `label` / `label, count`
  /// (for state the sighted see as a dot or colour: `Apps, 2, running`).
  final String? semanticLabel;
}

/// The app's one switch: a slim tinted pill (`ds.fill`, no border) and ONE
/// capsule under the chosen cell in `ds.accentWash`, its label in
/// `ds.accentText`: the app's one selection look. It picks the value of a setting (theme,
/// how agents open) and switches what a sheet shows (the kinds of what a session made);
/// the job differs, the look does not.
///
/// Cells are equal width when every option fits at its own size, and the row
/// scrolls sideways (cells as wide as their content) when one does not, so a
/// label is never cut to fit. The capsule slides to the chosen cell
/// ([Motion.standard], [Motion.easeOut]; it jumps under reduced motion) and
/// one number, its place in cell units, drives it and every cell's colour, so
/// a label warms as the capsule arrives under it and cools as it leaves, in
/// step (the label weight never changes: it cannot be interpolated, and used to
/// snap on its own). No press scale, no ripple. Text stops growing at 1.2x: the
/// pill is a fixed 44 dp and every option is a full-height touch target.
class Segmented<T> extends StatefulWidget {
  const Segmented({super.key, required this.options, required this.value, required this.onChanged});

  final List<SegmentOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  State<Segmented<T>> createState() => _SegmentedState<T>();
}

class _SegmentedState<T> extends State<Segmented<T>> {
  /// The capsule's air inside the pill.
  static const _inset = 2.0;

  /// Air at each side of a label: [_pad] when the row scrolls, at least [_padMin] when the cells are equal.
  static const _pad = 14.0;
  static const _padMin = 8.0;
  static const _gap = 6.0;

  final _scroll = ScrollController();
  var _placed = false;

  /// What the row was last scrolled to show: the chosen cell and the view's
  /// width, null while the cells are equal. A rebuild with the same key leaves
  /// the scroll where the person put it.
  (int, double)? _revealed;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TextStyle get _style => Type.buttonCompact;

  /// How wide an option's content is, without its padding.
  double _contentWidth(BuildContext context, SegmentOption<T> o, {required bool icons}) {
    final scaler = MediaQuery.textScalerOf(context);
    double text(String s, TextStyle style) {
      final p = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      return p.width;
    }

    var w = text(o.label, _style);
    if (icons && o.icon != null) w += 15 + _gap;
    if (o.leading != null) w += 8 + _gap;
    if (o.count != null) w += 5 + text('${o.count}', Type.secondaryStrong);
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final options = widget.options;
    final n = options.length;
    if (n == 0) return const SizedBox.shrink();
    // -1 when the value is none of the options: no capsule, no cell selected.
    final index = options.indexWhere((o) => o.value == widget.value);
    final reduced = Motion.reduced(context);
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Builder(
        builder: (context) => LayoutBuilder(
          builder: (context, box) {
            // An unbounded parent (a Row, a scroll view) gives no width to share: size to the content.
            final bounded = box.hasBoundedWidth;
            final inner = bounded ? box.maxWidth : double.infinity;
            // Equal cells with the icons; else equal cells with the words alone (an icon
            // is decoration, a word is the option); else a scrolling row, icons kept.
            bool equal(bool icons) =>
                options.every((o) => _contentWidth(context, o, icons: icons) + 2 * _padMin <= inner / n);
            final icons = equal(true) || !equal(false);
            final fits = bounded && equal(icons);
            final natural = [for (final o in options) _contentWidth(context, o, icons: true) + 2 * _pad];
            final widths = fits ? List.filled(n, inner / n) : natural;
            final lefts = <double>[];
            var x = 0.0;
            for (final w in widths) {
              lefts.add(x);
              x += w;
            }
            final total = x;
            final scrolls = bounded && !fits;
            // Bring the chosen cell into view when it, or the view, changed; not on every
            // rebuild, or a new count would pull the row back from where the person dragged it.
            final key = scrolls && index >= 0 ? (index, inner) : null;
            if (key != _revealed) {
              _revealed = key;
              if (key != null) _reveal(lefts[index], widths[index], inner, reduced, first: !_placed);
            }
            _placed = true;
            Widget row(double place) {
              // The capsule's left edge and width at [place], between the cells it is travelling across.
              final lo = place.floor().clamp(0, n - 1);
              final hi = place.ceil().clamp(0, n - 1);
              final t = place - lo;
              final capLeft = lefts[lo] + (lefts[hi] - lefts[lo]) * t;
              final capWidth = widths[lo] + (widths[hi] - widths[lo]) * t;
              return SizedBox(
                width: total,
                height: kMinTap,
                child: Stack(
                  children: [
                    if (index >= 0)
                      Positioned(
                        left: capLeft + _inset,
                        width: capWidth - 2 * _inset,
                        top: _inset,
                        bottom: _inset,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            // Lighter than the track in both themes: white on the tint, the next rung up on ink.
                            color: ds.accentWash,
                            borderRadius: BorderRadius.circular(kMinTap / 2),
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        for (final (i, o) in options.indexed)
                          SizedBox(
                            width: widths[i],
                            child: _cell(context, o, i, place, selected: i == index, icons: icons),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }

            final track = TweenAnimationBuilder<double>(
              tween: Tween<double>(end: math.max(index, 0).toDouble()),
              duration: reduced ? Duration.zero : Motion.standard,
              curve: Motion.easeOut,
              builder: (context, place, _) => row(place),
            );
            return Container(
              height: kMinTap,
              decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(kMinTap / 2)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(kMinTap / 2),
                child: ClipRect(
                  child: bounded
                      ? SingleChildScrollView(
                          controller: _scroll,
                          scrollDirection: Axis.horizontal,
                          physics: fits ? const NeverScrollableScrollPhysics() : null,
                          child: track,
                        )
                      : track,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Keeps the chosen cell in view when the row scrolls.
  void _reveal(double left, double width, double view, bool reduced, {required bool first}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final want = (left + width / 2 - view / 2).clamp(0.0, max);
      if ((_scroll.offset - want).abs() < 1) return;
      if (first || reduced) {
        _scroll.jumpTo(want);
      } else {
        unawaited(_scroll.animateTo(want, duration: Motion.standard, curve: Motion.easeOut));
      }
    });
  }

  Widget _cell(
    BuildContext context,
    SegmentOption<T> o,
    int i,
    double place, {
    required bool selected,
    required bool icons,
  }) {
    final ds = context.ds;
    // 1 under the capsule, 0 a cell away: the colour follows the capsule.
    final warm = (1 - (place - i).abs()).clamp(0.0, 1.0);
    // Hue carries the choice: secondary ink to accent text.
    final color = Color.lerp(ds.textSecondary, ds.accentText, warm)!;
    return PressBuilder(
      onTap: () {
        if (!selected) widget.onChanged(o.value);
      },
      haptic: !selected,
      semanticLabel: o.semanticLabel ?? (o.count == null ? o.label : '${o.label}, ${o.count}'),
      selected: selected,
      minTapSize: kMinTap,
      builder: (context, _) => Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (o.leading != null) ...[o.leading!, const SizedBox(width: _gap)],
            if (icons && o.icon != null) ...[Icon(o.icon, size: 15, color: color), const SizedBox(width: _gap)],
            Flexible(
              child: Text(
                o.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _style.copyWith(color: color),
              ),
            ),
            if (o.count != null) ...[
              const SizedBox(width: 5),
              Text(
                '${o.count}',
                style: Type.secondaryStrong.copyWith(
                  // The chosen count takes the chosen label's accent text.
                  color: selected ? ds.accentText : ds.textMuted,
                  fontFeatures: Type.tabular,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
