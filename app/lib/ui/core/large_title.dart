import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'press.dart';
import 'chips.dart';
import 'motion.dart';
import 'tokens.dart';
import 'top_bar.dart';

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
    this.compactTitle = true,
    this.subtitleLines = 1,
  });

  /// A pushed screen's header: [AppBackButton] leads.
  const SliverLargeTitle.back({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.bottom,
    this.bottomHeight = 0,
    this.subtitleLines = 1,
  }) : leading = const AppBackButton(),
       compactTitle = true;

  final String title;

  /// One quiet line under the big title, or [subtitleLines] of them. A
  /// control in it (home's `3 to review`) is hit from a [kMinTap] band: its
  /// words, the title block's bottom above them and the gap under the line,
  /// each touch taken into the nearest line.
  final Widget? subtitle;

  /// How many lines [subtitle] is given (1 or 2). Home's status line takes a
  /// second line rather than cut its end on a narrow phone: the end says how
  /// many machines are not connected, the part that matters most.
  final int subtitleLines;

  /// Pushed screens use [SliverLargeTitle.back]; home has its machines chip.
  final Widget? leading;
  final List<Widget> actions;

  /// Scrolls away with the title (filter chips, a segmented control).
  final Widget? bottom;

  /// Height reserved for [bottom]; [AppChip.height] (44) for a chip row.
  final double bottomHeight;

  /// Whether the title fades into the bar once the large title has scrolled
  /// away. Home turns it off: its leading chip says the fleet's health where
  /// a centred `Agents` would collide with it on a narrow phone, and home
  /// needs no name to say where the person is.
  final bool compactTitle;

  static const _barHeight = 56.0;
  static const _titleBlock = 50.0;
  static const _subtitleBlock = 22.0;
  static const _gap = 8.0;

  /// Height of the part that scrolls away.
  static double _large(bool hasSubtitle, double bottomHeight, [int subtitleLines = 1]) =>
      _titleBlock + (hasSubtitle ? _subtitleBlock * subtitleLines : 0) + bottomHeight + _gap;

  /// The pinned header's full (unscrolled) height: where the list content
  /// starts. Use it as the `edgeOffset` of a pull-to-refresh indicator.
  static double extent(
    BuildContext context, {
    bool hasSubtitle = false,
    double bottomHeight = 0,
    int subtitleLines = 1,
  }) => MediaQuery.paddingOf(context).top + _barHeight + _large(hasSubtitle, bottomHeight, subtitleLines);

  /// The pinned bar's height once the large title has scrolled away: the part
  /// of the screen's top that content scrolled under is hidden by.
  static double collapsedExtent(BuildContext context) => MediaQuery.paddingOf(context).top + _barHeight;

  @override
  Widget build(BuildContext context) => SliverPersistentHeader(
    pinned: true,
    delegate: _LargeTitleDelegate(
      topInset: MediaQuery.paddingOf(context).top,
      title: title,
      subtitle: subtitle,
      subtitleLines: subtitleLines,
      leading: leading,
      actions: actions,
      bottom: bottom,
      bottomHeight: bottomHeight,
      compactTitle: compactTitle,
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
    required this.subtitleLines,
    required this.leading,
    required this.actions,
    required this.bottom,
    required this.bottomHeight,
    required this.compactTitle,
    required this.ds,
    required this.reduced,
  });

  final double topInset;
  final String title;
  final Widget? subtitle;
  final int subtitleLines;
  final Widget? leading;
  final List<Widget> actions;
  final Widget? bottom;
  final double bottomHeight;
  final bool compactTitle;
  final Ds ds;
  final bool reduced;

  static const _bar = SliverLargeTitle._barHeight;
  static const _titleBlock = SliverLargeTitle._titleBlock;
  static const _subtitleBlock = SliverLargeTitle._subtitleBlock;

  double get _large => SliverLargeTitle._large(subtitle != null, bottomHeight, subtitleLines);

  double get _subtitleHeight => _subtitleBlock * subtitleLines;

  @override
  double get minExtent => topInset + _bar;

  @override
  double get maxExtent => topInset + _bar + _large;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
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
        if (subtitle != null)
          _HitBand(
            // Up into the title block (which takes no tap): a whole touch
            // target above the first line's middle, so a control there is
            // one even with a second line under it. Down through the gap
            // under the line, when nothing sits there.
            above: kMinTap - _subtitleBlock / 2,
            below: bottom == null ? SliverLargeTitle._gap : 0,
            child: SizedBox(height: _subtitleHeight, child: subtitle),
          ),
        // The gap under the line is the band's to hit (it paints nothing).
        if (subtitle != null && bottom == null) const SizedBox(height: SliverLargeTitle._gap),
      ],
    );
    // No layer at rest (opacity 1); the title is simply absent once it is gone.
    if (big < 1) titles = Opacity(opacity: big, child: titles);
    if (big == 0) {
      titles = SizedBox(
        height: _titleBlock + (subtitle != null ? _subtitleHeight + (bottom == null ? SliverLargeTitle._gap : 0) : 0),
      );
    }

    // Bars clamp text scale like iOS navigation bars: their blocks are fixed
    // height, so unbounded system scaling would clip the title.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: kBarTextScale,
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
                      if (compactTitle && compact > 0)
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
                        padding: const EdgeInsets.symmetric(horizontal: AppTopBar.edge),
                        child: Row(
                          children: [
                            // The leading control takes what the actions
                            // leave, so a wide one (home's machines chip)
                            // shrinks and ellipsizes instead of overflowing.
                            Expanded(
                              child: Align(alignment: AlignmentDirectional.centerStart, child: leading),
                            ),
                            for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 4), a],
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
                    child: SizedBox(height: 1 / MediaQuery.devicePixelRatioOf(context)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _fade(double opacity, Widget child) => opacity >= 1 ? child : Opacity(opacity: opacity, child: child);

  @override
  bool shouldRebuild(_LargeTitleDelegate old) =>
      old.title != title ||
      old.ds != ds ||
      old.topInset != topInset ||
      old.bottomHeight != bottomHeight ||
      old.compactTitle != compactTitle ||
      old.leading != leading ||
      old.subtitle != subtitle ||
      old.subtitleLines != subtitleLines ||
      old.bottom != bottom ||
      old.actions != actions;
}

/// Takes a touch up to [above] dp over its child and [below] dp under it to
/// the nearest point well inside the child, so a control on a line shorter than
/// [kMinTap] is still a [kMinTap] target. Only where its parents reach: a
/// parent hit-tests within its own size first.
class _HitBand extends SingleChildRenderObjectWidget {
  const _HitBand({required this.above, required this.below, required super.child});

  final double above;
  final double below;

  @override
  _RenderHitBand createRenderObject(BuildContext context) => _RenderHitBand(above, below);

  @override
  void updateRenderObject(BuildContext context, _RenderHitBand renderObject) => renderObject
    ..above = above
    ..below = below;
}

class _RenderHitBand extends RenderProxyBox {
  _RenderHitBand(this.above, this.below);

  static const _edge = 8.0;

  double above;
  double below;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final band = Rect.fromLTRB(0, -above, size.width, size.height + below);
    if (!band.contains(position)) return false;
    // Well inside the line, not on its edge: the words sit a little inside
    // their line box.
    final inset = size.height / 2 < _edge ? size.height / 2 : _edge;
    final inside = Offset(position.dx, position.dy.clamp(inset, size.height - inset));
    if (hitTestChildren(result, position: inside)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}
