import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';
import 'tokens.dart';

/// Static placeholder bars while a file or folder loads: no animation, so a
/// slow link does not keep the GPU busy.
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.rows = false});

  /// Bars shaped like list rows (a tile and two lines) instead of code lines.
  final bool rows;

  static const _widths = [0.62, 0.84, 0.4, 0.74, 0.55, 0.9, 0.3, 0.68, 0.5, 0.78];

  @override
  Widget build(BuildContext context) {
    final fill = context.ds.fill;
    Widget bar(double width, double height) => FractionallySizedBox(
      widthFactor: width,
      alignment: Alignment.centerLeft,
      child: Container(
        height: height,
        decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(Radii.xs)),
      ),
    );
    return Semantics(
      label: context.l10n.uiLoading,
      excludeSemantics: true,
      child: ExcludeFocus(
        child: IgnorePointer(
          child: ListView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, MediaQuery.paddingOf(context).bottom),
            itemCount: rows ? 14 : 30,
            itemBuilder: (_, i) => rows
                ? SizedBox(
                    height: 64,
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(Radii.xs)),
                        ),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              bar(_widths[i % _widths.length] * 0.8 + 0.1, 12),
                              const SizedBox(height: 8),
                              bar(0.28, 9),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : SizedBox(
                    height: 22,
                    child: Align(alignment: Alignment.centerLeft, child: bar(_widths[i % _widths.length], 10)),
                  ),
          ),
        ),
      ),
    );
  }
}

/// A skeleton that stays out of sight for [delay]: a link that answers inside
/// that time shows the real content straight away, with no grey placeholder
/// flashing in and out. The one timer is cancelled with the widget.
class DelayedSkeleton extends StatefulWidget {
  const DelayedSkeleton({super.key, this.rows = false, this.delay = Dwell.spinnerDelay, this.note});

  final bool rows;
  final Duration delay;

  /// What the wait is for when it is more than one read ("Looking in other
  /// checkouts…"), drawn above the placeholder.
  final String? note;

  @override
  State<DelayedSkeleton> createState() => _DelayedSkeletonState();
}

class _DelayedSkeletonState extends State<DelayedSkeleton> {
  Timer? _timer;
  var _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.expand();
    final note = widget.note;
    if (note == null) return Skeleton(rows: widget.rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, 0),
          child: Text(note, style: Type.secondary.copyWith(color: context.ds.textSecondary)),
        ),
        Expanded(child: Skeleton(rows: widget.rows)),
      ],
    );
  }
}
