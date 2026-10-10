import 'dart:async';

import 'package:flutter/material.dart';

import 'controls.dart';
import 'motion.dart';
import 'pop.dart';
import 'toast.dart' show ToastShelf;
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
    this.mark = false,
    this.markLabel = '',
  });

  final IconData icon;
  final String label;

  /// Count shown as a small dot with number; 0 hides it.
  final int badge;

  /// What the count means, for screen readers: "Agents, 2 need you".
  final String badgeLabel;

  /// A small plain dot, in the accent: something here is worth a look, and
  /// nothing needs the person (the count [badge] is the loud one). Not drawn
  /// next to a count. [markLabel] is its meaning for screen readers.
  final bool mark;
  final String markLabel;
}

/// Floating pill tab bar: three equal cells, an icon over a name in each, the
/// selected one on a soft capsule. Content scrolls under it, so lists must
/// reserve [clearance] at the bottom. A hairline and no shadow (a shadow
/// rendered as a hard grey band under the pill, and the app is flat), and no
/// backdrop blur, which costs a full-screen blur pass per frame on mid-range
/// GPUs.
///
/// Slim on purpose: 56 dp tall, at most [_maxWidth] wide and centred, so it
/// sits in the thumb's reach without spreading edge to edge over the board it
/// serves (the first version was 64 dp and the full width, and read as big).
///
/// Every tab is named and every cell is the same width, so nothing moves when a
/// tab is chosen (a second tap from memory lands where the first did) and a
/// count badge, which rides the icon's corner, never meets a label. Three
/// cells fit a 320 dp phone: the text is clamped at 1.15x, and a cell holds
/// "Machines" at that. Every tab keeps its full name for screen readers, and
/// [tabKey] finds one by label in tests.
///
/// One number, the capsule's place in tab units, drives the capsule and every
/// cell's colour, so the text warms as the capsule arrives under it and cools
/// as it leaves, in step. Two clocks (a position curve and a separate linear
/// colour tween) drifted apart, and the label weight, which cannot be
/// interpolated, snapped on its own: it no longer changes.
class FloatingTabBar extends StatefulWidget {
  const FloatingTabBar({
    super.key,
    required this.tabs,
    required this.index,
    required this.onChanged,
  });

  final List<TabSpec> tabs;
  final int index;
  final ValueChanged<int> onChanged;

  /// Key of the tab labelled [label], for tests and callers.
  static Key tabKey(String label) => ValueKey('tab:$label');

  /// Key of the selection capsule, for tests.
  static const capsuleKey = ValueKey('tab:capsule');

  static const _height = 56.0;
  static const _pad = 4.0;
  static const _cell = _height - _pad * 2;
  static const _margin = 8.0;
  static const _side = 12.0;
  static const _maxWidth = 312.0;

  /// Space a scrolling list should keep free at its bottom.
  static double clearance(BuildContext context) =>
      _height + _margin * 2 + MediaQuery.paddingOf(context).bottom;

  @override
  State<FloatingTabBar> createState() => _FloatingTabBarState();
}

class _FloatingTabBarState extends State<FloatingTabBar> with SingleTickerProviderStateMixin {
  // The capsule's place in tab units (0 is the first cell). It stops when it
  // arrives; nothing runs at rest.
  late final AnimationController _place = AnimationController.unbounded(
    vsync: this,
    value: widget.index.toDouble(),
  );

  final _cellsKey = GlobalKey();

  // A finger holds the capsule: it follows 1:1 and the glide stays out of the way.
  bool _scrubbing = false;
  int _over = 0;

  /// Seconds of the flick's speed that carry on after the finger lifts, to
  /// choose the tab the capsule would have coasted to (Apple's projection).
  static const _momentum = 0.1;

  @override
  void didUpdateWidget(FloatingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index == widget.index || _scrubbing) return;
    _glideTo(widget.index);
  }

  // From where it is now, never from the old tab: a second tap mid-glide
  // carries on from the live place. Under reduced motion it is there at once.
  void _glideTo(int i) {
    if (Motion.reduced(context)) {
      _place.value = i.toDouble();
    } else {
      unawaited(_place.animateTo(i.toDouble(), duration: Motion.standard, curve: Motion.easeOut));
    }
  }

  double get _cellWidth => (_cellsKey.currentContext?.size?.width ?? 0) / widget.tabs.length;

  void _scrubStart(DragStartDetails _) {
    _scrubbing = true;
    _place.stop();
    _over = _place.value.round();
  }

  void _scrubUpdate(DragUpdateDetails d) {
    final cell = _cellWidth;
    if (cell <= 0) return;
    final last = widget.tabs.length - 1;
    // The capsule lives inside the pill: it stops at the first and last cell.
    final next = (_place.value + d.delta.dx / cell).clamp(0.0, last.toDouble());
    _place.value = next;
    final over = next.round().clamp(0, last);
    if (over != _over) {
      _over = over;
      Haptics.tick();
    }
  }

  // Chosen where a flick would have stopped, so a quick flick is enough.
  void _scrubEnd(double velocity) {
    if (!_scrubbing) return;
    _scrubbing = false;
    final cell = _cellWidth;
    final last = widget.tabs.length - 1;
    final projected = _place.value + (cell > 0 ? velocity * _momentum / cell : 0);
    final target = projected.round().clamp(0, last);
    if (target != widget.index) {
      widget.onChanged(target);
      // The caller owns the selection: if it did not take it, the capsule goes back.
      WidgetsBinding.instance
        ..addPostFrameCallback((_) {
          if (mounted && !_scrubbing && widget.index != target) _glideTo(widget.index);
        })
        ..ensureVisualUpdate();
    } else {
      _glideTo(widget.index);
    }
  }

  @override
  void dispose() {
    _place.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ToastShelf(lift: FloatingTabBar.clearance(context), child: _bar(context));

  Widget _bar(BuildContext context) {
    final ds = context.ds;
    final inset = MediaQuery.paddingOf(context);
    final n = widget.tabs.length;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          inset.left + FloatingTabBar._side,
          0,
          inset.right + FloatingTabBar._side,
          inset.bottom + FloatingTabBar._margin,
        ),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: FloatingTabBar._maxWidth),
            child: GestureDetector(
              // The capsule is an object in the hand: drag it along the bar and
              // it follows the finger; the tab changes where it is let go. A tap
              // on a cell does the same without it.
              onHorizontalDragStart: _scrubStart,
              onHorizontalDragUpdate: _scrubUpdate,
              onHorizontalDragEnd: (d) => _scrubEnd(d.velocity.pixelsPerSecond.dx),
              onHorizontalDragCancel: () => _scrubEnd(0),
              child: DecoratedBox(
              decoration: BoxDecoration(
                color: ds.surface,
                borderRadius: BorderRadius.circular(FloatingTabBar._height / 2),
                border: Border.all(color: ds.hairline),
              ),
              child: Padding(
                padding: const EdgeInsets.all(FloatingTabBar._pad),
                child: SizedBox(
                  key: _cellsKey,
                  height: FloatingTabBar._cell,
                  child: AnimatedBuilder(
                    animation: _place,
                    builder: (context, _) {
                      final at = _place.value;
                      return Stack(
                        children: [
                          // One capsule under the cells that travels from where
                          // it was to where it is, so the eye follows it; the
                          // cells themselves never move. [ds.fill] on the pill's
                          // surface was about 1.1:1 and vanished in dark.
                          Align(
                            alignment: Alignment(n < 2 ? 0 : -1 + 2 * at / (n - 1), 0),
                            child: FractionallySizedBox(
                              key: FloatingTabBar.capsuleKey,
                              widthFactor: 1 / n,
                              heightFactor: 1,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: ds.fillPressed,
                                  borderRadius: BorderRadius.circular(FloatingTabBar._cell / 2),
                                ),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              for (final (i, tab) in widget.tabs.indexed)
                                Expanded(
                                  child: _TabItem(
                                    key: FloatingTabBar.tabKey(tab.label),
                                    tab: tab,
                                    selected: i == widget.index,
                                    // 1 with the capsule centred under this cell, 0 a cell away.
                                    near: (1 - (at - i).abs()).clamp(0.0, 1.0).toDouble(),
                                    onTap: () => widget.onChanged(i),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
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
    super.key,
    required this.tab,
    required this.selected,
    required this.near,
    required this.onTap,
  });

  final TabSpec tab;
  final bool selected;
  final double near;
  final VoidCallback onTap;

  static const _icon = 22.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final badge = tab.badge;
    return PressBuilder(
      onTap: onTap,
      haptic: !selected,
      selected: selected,
      semanticLabel: badge > 0
          ? '${tab.label}, $badge ${tab.badgeLabel}'
          : tab.mark
              ? '${tab.label}, ${tab.markLabel}'
              : tab.label,
      builder: (context, pressed) => SizedBox(
        height: FloatingTabBar._cell,
        // The press warms the text at once; the capsule's place does the rest.
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: pressed ? 1 : 0),
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          builder: (context, press, _) {
            final color = Color.lerp(ds.textSecondary, ds.text, near > press ? near : press);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(tab.icon, size: _icon, color: color),
                    if (badge > 0)
                      Positioned(
                        left: _icon - 8,
                        top: -7,
                        child: PopOnRise(
                          value: badge,
                          child: Container(
                            constraints: const BoxConstraints(minWidth: 18),
                            height: 18,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            decoration: BoxDecoration(
                              color: ds.blocked,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: ds.surface, width: 1.5),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              badge > 99 ? '99+' : '$badge',
                              style: Type.caption.copyWith(
                                height: 1,
                                fontWeight: FontWeight.w700,
                                fontFeatures: Type.tabular,
                                color: ds.onStatus,
                              ),
                            ),
                          ),
                        ),
                      )
                    else if (tab.mark)
                      Positioned(
                        left: _icon - 5,
                        top: -3,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: ds.accent,
                            shape: BoxShape.circle,
                            border: Border.all(color: ds.surface, width: 1.5),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  tab.label,
                  maxLines: 1,
                  softWrap: false,
                  style: Type.label.copyWith(color: color, fontWeight: FontWeight.w500),
                ),
              ],
            );
          },
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
    this.notificationPredicate = defaultScrollNotificationPredicate,
  });

  final Future<void> Function() onRefresh;
  final double edgeOffset;
  final Widget child;

  /// Which scrollables pull it down. The default is the one right below it; a
  /// list inside a sideways scroll view needs `(n) => n.metrics.axis ==
  /// Axis.vertical`.
  final ScrollNotificationPredicate notificationPredicate;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    edgeOffset: edgeOffset,
    notificationPredicate: notificationPredicate,
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
/// it does not fit (large text, landscape). A tall sheet stops below the
/// status bar (`useSafeArea`): the session overview used to grow under the
/// clock, its grabber and title drawn over the status icons. Under reduced
/// motion the sheet appears and goes without sliding (drag to dismiss still
/// works).
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  isDismissible: dismissible,
  sheetAnimationStyle: Motion.reduced(context)
      ? AnimationStyle.noAnimation
      : const AnimationStyle(
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
    this.unavailable,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool destructive;

  /// Why the action cannot be used now. The row stays, dimmed and inert, and
  /// says this under its label.
  final String? unavailable;
}

/// One row of an action sheet: [onTap] runs when the action is available.
class SheetActionRow extends StatelessWidget {
  const SheetActionRow({super.key, required this.action, required this.onTap});

  final SheetAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final reason = action.unavailable;
    final inert = reason != null;
    return PressBuilder(
      onTap: inert ? null : onTap,
      // A dimmed row is still read as a button, a disabled one.
      button: inert ? true : null,
      builder: (context, pressed) => AnimatedContainer(
  useSafeArea: true,
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        height: inert ? null : 52,
        constraints: inert ? const BoxConstraints(minHeight: 52) : null,
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: inert ? 6 : 0),
        decoration: BoxDecoration(
          color: pressed ? ds.fill : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.row),
        ),
        child: Row(
          children: [
            Icon(
              action.icon,
              size: 20,
              color: inert
                  ? ds.textTertiary
                  : action.destructive
                  ? ds.dangerText
                  : ds.textSecondary,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                // Shrink-wrapped, so the row centres the label with its icon
                // (a full-height column pinned the label to the top).
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    action.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.row.copyWith(
                      color: inert
                          ? ds.textMuted
                          : action.destructive
                          ? ds.dangerText
                          : ds.text,
                    ),
                  ),
                  if (reason != null)
                    Text(
                      reason,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Type.caption.copyWith(color: ds.textSecondary),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
            SheetActionRow(
              action: a,
              onTap: () {
                Navigator.of(ctx).pop();
                a.onTap();
              },
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
            style: Type.compact.copyWith(color: ctx.ds.textSecondary),
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
