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
///
/// Only the title and subtitle fade. [bottom] (filter chips, a segmented
/// control) slides under the opaque bar at full opacity, and cannot be tapped
/// once it is fully hidden. Both titles are announced as headings.
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

  /// Height reserved for [bottom]; [AppChip.height] (44) for a chip row.
  final double bottomHeight;

  static const _barHeight = 56.0;
  static const _titleBlock = 50.0;
  static const _subtitleBlock = 22.0;
  static const _gap = 8.0;

  /// Height of the part that scrolls away.
  static double _large(bool hasSubtitle, double bottomHeight) =>
      _titleBlock + (hasSubtitle ? _subtitleBlock : 0) + bottomHeight + _gap;

  /// The pinned header's full (unscrolled) height: where the list content
  /// starts. Use it as the `edgeOffset` of a pull-to-refresh indicator.
  static double extent(
    BuildContext context, {
    bool hasSubtitle = false,
    double bottomHeight = 0,
  }) => MediaQuery.paddingOf(context).top + _barHeight + _large(hasSubtitle, bottomHeight);

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

  final double topInset;
  final String title;
  final Widget? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final double bottomHeight;
  final Ds ds;
  final bool reduced;

  static const _bar = SliverLargeTitle._barHeight;
  static const _titleBlock = SliverLargeTitle._titleBlock;
  static const _subtitleBlock = SliverLargeTitle._subtitleBlock;

  double get _large => SliverLargeTitle._large(subtitle != null, bottomHeight);

  @override
  double get minExtent => topInset + _bar;

  @override
  double get maxExtent => topInset + _bar + _large;

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

    Widget titles = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _titleBlock,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Semantics(
              header: true,
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Type.largeTitle.copyWith(color: ds.text),
              ),
            ),
          ),
        ),
        if (subtitle != null) SizedBox(height: _subtitleBlock, child: subtitle),
      ],
    );
    // No layer at rest (opacity 1); the title is simply absent once it is gone.
    if (big < 1) titles = Opacity(opacity: big, child: titles);
    if (big == 0) {
      titles = SizedBox(height: _titleBlock + (subtitle != null ? _subtitleBlock : 0));
    }

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
                top: topInset + _bar - shrinkOffset.clamp(0.0, _large),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    titles,
                    if (bottom != null)
                      SizedBox(
                        height: bottomHeight + SliverLargeTitle._gap,
                        child: ExcludeSemantics(
                          excluding: collapsed,
                          child: IgnorePointer(
                            ignoring: collapsed,
                            child: Padding(
                              padding: const EdgeInsets.only(top: SliverLargeTitle._gap),
                              child: bottom,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Top bar.
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: topInset + _bar,
                child: Container(
                  color: ds.bg,
                  padding: EdgeInsets.only(top: topInset),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (compact > 0)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 64),
                          child: Semantics(
                            header: true,
                            child: _fade(
                              compact,
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Type.barTitle.copyWith(color: ds.text),
                              ),
                            ),
                          ),
                        ),
                      // Round buttons paint 40 inside a 44 touch box, so the
                      // painted edge still sits 16 from the screen edge.
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Gap.gutter - 6,
                        ),
                        child: Row(
                          children: [
                            ?leading,
                            const Spacer(),
                            for (final (i, a) in actions.indexed) ...[
                              if (i > 0) const SizedBox(width: 4),
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

  static Widget _fade(double opacity, Widget child) =>
      opacity >= 1 ? child : Opacity(opacity: opacity, child: child);

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
  const TabSpec({
    required this.icon,
    required this.label,
    this.badge = 0,
    this.badgeLabel = 'need you',
  });

  final IconData icon;
  final String label;

  /// Count shown as a small dot with number; 0 hides it.
  final int badge;

  /// What the count means, for screen readers: "Agents, 2 need you".
  final String badgeLabel;
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
    final badge = tab.badge;
    return PressBuilder(
      onTap: onTap,
      haptic: !selected,
      scale: 0.95,
      selected: selected,
      semanticLabel: badge > 0 ? '${tab.label}, $badge ${tab.badgeLabel}' : tab.label,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minWidth: 104),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        height: 48,
        decoration: BoxDecoration(
          color: selected ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: selected ? ds.text : ds.textSecondary),
          duration: Motion.standard,
          builder: (context, color, _) => Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(tab.icon, size: 20, color: color),
                  if (badge > 0)
                    Positioned(
                      left: 11,
                      top: -8,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 17),
                        height: 17,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: ds.blocked,
                          borderRadius: BorderRadius.circular(8.5),
                          border: Border.all(color: ds.surface, width: 1.5),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: TextStyle(
                            fontFamily: Type.family,
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w700,
                            fontFeatures: Type.tabular,
                            color: ds.onStatus,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
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
      ),
    );
  }
}

/// Pull-to-refresh in the app's style: no disc, just a thin 2 px ring over the
/// page background. Give [edgeOffset] the pinned header's height
/// (`SliverLargeTitle.extent(context, ...)`) so the ring appears below it, not
/// on top of the first row.
class AppRefresh extends StatelessWidget {
  const AppRefresh({
    super.key,
    required this.onRefresh,
    required this.edgeOffset,
    required this.child,
  });

  final Future<void> Function() onRefresh;
  final double edgeOffset;
  final Widget child;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    edgeOffset: edgeOffset,
    color: context.ds.textSecondary,
    backgroundColor: Colors.transparent,
    elevation: 0,
    strokeWidth: 2,
    child: child,
  );
}

/// Modal bottom sheet in the app's style: rounded top, grabber, safe-area aware.
///
/// Colours come from the theme (`bottomSheetTheme`, `modalBarrierColor`), so a
/// light/dark switch while a sheet is open restyles it. The body scrolls when
/// it does not fit (large text, landscape).
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  isDismissible: dismissible,
  sheetAnimationStyle: const AnimationStyle(
    curve: Motion.easeOut,
    reverseCurve: Motion.easeOut,
    duration: Motion.sheetIn,
    reverseDuration: Motion.sheetOut,
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
            color: ctx.ds.textTertiary.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Flexible(child: SingleChildScrollView(child: builder(ctx))),
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
    // Outer inset 4 + row padding 16: icons and titles sit on the 20 gutter.
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Semantics(
                header: true,
                child: Text(
                  title,
                  style: Type.label.copyWith(color: ds.textSecondary),
                ),
              ),
            ),
          for (final a in actions)
            PressBuilder(
              onTap: () {
                Navigator.of(ctx).pop();
                a.onTap();
              },
              builder: (context, pressed) => AnimatedContainer(
                duration: Motion.pressing(pressed),
                curve: Motion.easeOut,
                height: 52,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                decoration: BoxDecoration(
                  color: pressed ? ds.fill : Colors.transparent,
                  borderRadius: BorderRadius.circular(Radii.row),
                ),
                child: Row(
                  children: [
                    Icon(
                      a.icon,
                      size: 20,
                      color: a.destructive ? ds.dangerText : ds.textSecondary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        a.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.row.copyWith(
                          color: a.destructive ? ds.dangerText : ds.text,
                        ),
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
          Semantics(
            header: true,
            child: Text(title, style: Type.title.copyWith(color: ctx.ds.text)),
          ),
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
            kind: AppButtonKind.secondary,
            expand: true,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}
