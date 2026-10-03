import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controls.dart';
import 'motion.dart';
import 'tokens.dart';

/// Large-title page header (Apple/Notion pattern) as a pinned sliver.
///
/// At rest it shows a big bold title over the page background with no
/// separator. As the list scrolls the big title slides under a compact bar,
/// the compact title fades in, and a hairline appears: a scroll-edge effect
/// instead of a permanent divider. [leading] and [actions] stay put.
class SliverLargeTitle extends StatelessWidget {
  const SliverLargeTitle({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.bottom,
    this.bottomHeight = 0,
  });

  final String title;

  /// One quiet line under the big title.
  final Widget? subtitle;

  /// Typically a back [CircleButton].
  final Widget? leading;
  final List<Widget> actions;

  /// Scrolls away with the title (filter chips, a segmented control).
  final Widget? bottom;
  final double bottomHeight;

  @override
  Widget build(BuildContext context) => SliverPersistentHeader(
    pinned: true,
    delegate: _LargeTitleDelegate(
      topInset: MediaQuery.paddingOf(context).top,
      title: title,
      subtitle: subtitle,
      leading: leading,
      actions: actions,
      bottom: bottom,
      bottomHeight: bottomHeight,
      ds: context.ds,
      reduced: Motion.reduced(context),
    ),
  );
}

class _LargeTitleDelegate extends SliverPersistentHeaderDelegate {
  _LargeTitleDelegate({
    required this.topInset,
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.actions,
    required this.bottom,
    required this.bottomHeight,
    required this.ds,
    required this.reduced,
  });

  static const barHeight = 56.0;
  static const titleBlock = 50.0;
  static const subtitleBlock = 22.0;

  final double topInset;
  final String title;
  final Widget? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final double bottomHeight;
  final Ds ds;
  final bool reduced;

  double get _large =>
      titleBlock + (subtitle != null ? subtitleBlock : 0) + bottomHeight + 8;

  @override
  double get minExtent => topInset + barHeight;

  @override
  double get maxExtent => topInset + barHeight + _large;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final t = (shrinkOffset / (_large * 0.55)).clamp(0.0, 1.0);
    final compact = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
    final big = (1 - t * 1.25).clamp(0.0, 1.0);
    final collapsed = shrinkOffset >= _large - 1;

    // Bars clamp text scale like iOS navigation bars: their blocks are fixed
    // height, so unbounded system scaling would clip the title.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: ClipRect(
        child: Container(
          color: ds.bg,
          child: Stack(
            children: [
              // Large title block, anchored under the bar so it slides beneath it.
              Positioned(
                left: Gap.gutter,
                right: Gap.gutter,
                top: topInset + barHeight - shrinkOffset.clamp(0.0, _large),
                child: Opacity(
                  opacity: big,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: titleBlock,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Type.largeTitle.copyWith(color: ds.text),
                          ),
                        ),
                      ),
                      if (subtitle != null)
                        SizedBox(height: subtitleBlock, child: subtitle),
                      if (bottom != null)
                        SizedBox(
                          height: bottomHeight + 8,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: bottom,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // Top bar.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: topInset + barHeight,
                child: Container(
                  color: ds.bg,
                  padding: EdgeInsets.only(top: topInset),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Opacity(
                        opacity: compact,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 64),
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Type.barTitle.copyWith(color: ds.text),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Gap.gutter - 4,
                        ),
                        child: Row(
                          children: [
                            ?leading,
                            const Spacer(),
                            for (final (i, a) in actions.indexed) ...[
                              if (i > 0) const SizedBox(width: 8),
                              a,
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: collapsed || overlapsContent ? 1 : 0,
                  duration: reduced ? Duration.zero : Motion.standard,
                  child: ColoredBox(
                    color: ds.hairline,
                    child: SizedBox(
                      height: 1 / MediaQuery.devicePixelRatioOf(context),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_LargeTitleDelegate old) =>
      old.title != title ||
      old.ds != ds ||
      old.topInset != topInset ||
      old.bottomHeight != bottomHeight ||
      old.leading != leading ||
      old.subtitle != subtitle ||
      old.bottom != bottom ||
      old.actions != actions;
}

class TabSpec {
  const TabSpec({required this.icon, required this.label, this.badge = 0});

  final IconData icon;
  final String label;

  /// Count shown as a small dot with number; 0 hides it.
  final int badge;
}

/// Floating pill tab bar. Content scrolls under it, so lists must reserve
/// [clearance] at the bottom. Opaque-ish surface with a hairline and one soft
/// shadow: no backdrop blur, which costs a full-screen blur pass per frame on
/// mid-range GPUs.
class FloatingTabBar extends StatelessWidget {
  const FloatingTabBar({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<TabSpec> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  static const _height = 56.0;
  static const _margin = 12.0;

  /// Space a scrolling list should keep free at its bottom.
  static double clearance(BuildContext context) =>
      _height + _margin * 2 + MediaQuery.paddingOf(context).bottom;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom + _margin),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: ds.surface.withValues(alpha: 0.97),
              borderRadius: BorderRadius.circular(_height / 2),
              border: Border.all(color: ds.hairline),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: ds.isDark ? 0.45 : 0.07,
                  ),
                  blurRadius: 28,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, tab) in tabs.indexed)
                    _TabItem(
                      tab: tab,
                      selected: i == index,
                      onTap: () => onChanged(i),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.tab,
    required this.selected,
    required this.onTap,
  });

  final TabSpec tab;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final color = selected ? ds.text : ds.textTertiary;
    return PressBuilder(
      onTap: onTap,
      haptic: !selected,
      scale: 0.95,
      semanticLabel: tab.label,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.standard,
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minWidth: 104),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        height: 48,
        decoration: BoxDecoration(
          color: selected ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(tab.icon, size: 20, color: color),
                if (tab.badge > 0)
                  Positioned(
                    right: -6,
                    top: -5,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 14),
                      height: 14,
                      padding: const EdgeInsets.symmetric(horizontal: 3.5),
                      decoration: BoxDecoration(
                        color: ds.blocked,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: ds.surface, width: 1.5),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '${math.min(tab.badge, 99)}',
                        style: const TextStyle(
                          fontFamily: Type.family,
                          fontSize: 9,
                          height: 1,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            Text(
              tab.label,
              style: Type.label.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 13.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal bottom sheet in the app's style: rounded top, grabber, safe-area aware.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  isDismissible: dismissible,
  backgroundColor: context.ds.surface,
  barrierColor: context.ds.scrim,
  sheetAnimationStyle: const AnimationStyle(
    curve: Motion.easeOut,
    reverseCurve: Motion.easeOut,
    duration: Duration(milliseconds: 280),
    reverseDuration: Duration(milliseconds: 200),
  ),
  builder: (ctx) => SafeArea(
    top: false,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: ctx.ds.hairline,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        builder(ctx),
      ],
    ),
  ),
);

class SheetAction {
  const SheetAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;
}

/// A list of actions in a sheet (replaces popup menus).
Future<void> showActionSheet(
  BuildContext context, {
  String? title,
  required List<SheetAction> actions,
}) => showAppSheet<void>(
  context,
  builder: (ctx) {
    final ds = ctx.ds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                title,
                style: Type.label.copyWith(color: ds.textSecondary),
              ),
            ),
          for (final a in actions)
            PressBuilder(
              onTap: () {
                Navigator.of(ctx).pop();
                a.onTap();
              },
              semanticLabel: a.label,
              builder: (context, pressed) => AnimatedContainer(
                duration: pressed ? Motion.press : Motion.release,
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: pressed ? ds.fill : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(
                      a.icon,
                      size: 20,
                      color: a.destructive ? ds.danger : ds.textSecondary,
                    ),
                    const SizedBox(width: 14),
                    Text(
                      a.label,
                      style: Type.row.copyWith(
                        color: a.destructive ? ds.danger : ds.text,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  },
);

/// Confirmation in a sheet. Returns true if confirmed.
Future<bool> showConfirmSheet(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = true,
}) async {
  final result = await showAppSheet<bool>(
    context,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(
        Gap.gutter,
        Gap.xl,
        Gap.gutter,
        Gap.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Type.title.copyWith(color: ctx.ds.text)),
          const SizedBox(height: Gap.sm),
          Text(
            message,
            style: Type.body.copyWith(
              color: ctx.ds.textSecondary,
              fontSize: 14.5,
            ),
          ),
          const SizedBox(height: Gap.xl),
          AppButton(
            label: confirmLabel,
            kind: destructive ? AppButtonKind.danger : AppButtonKind.primary,
            expand: true,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
          const SizedBox(height: Gap.sm),
          AppButton(
            label: 'Cancel',
            kind: AppButtonKind.ghost,
            expand: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}
