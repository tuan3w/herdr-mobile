import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'controls.dart';
import 'motion.dart';
import 'tokens.dart';

/// One physical pixel, so dividers stay crisp at any density.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0, this.endIndent = 0});

  final double indent;
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    final px = 1 / MediaQuery.devicePixelRatioOf(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: indent, end: endIndent),
      child: SizedBox(
        height: math.max(px, 0.5),
        width: double.infinity,
        child: ColoredBox(color: context.ds.hairline),
      ),
    );
  }
}

/// A flat list row: leading glyph, title, quiet secondary lines, trailing.
///
/// No card and no elevation. Pressed state is a soft rounded highlight inset
/// from the screen edge (the Notion row), and the divider starts at the text.
///
/// The text column starts at 64 on the page grid (gutter 20 + [leadingExtent]
/// 32 + gap 12). A small [leading] (a status glyph) is centred on the TITLE
/// line, not on the whole block, so rows are scanned by their first line.
///
/// Semantics: with [semanticLabel] null the visible texts (and the leading
/// glyph's own label) merge into one node, "Needs you, title, subtitle". Pass
/// a label only to replace all of that with something hand-composed.
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.leading,
    this.leadingExtent = 32,
    this.leadingOnTitle = true,
    this.subtitle,
    this.subtitle2,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.divider = true,
    this.dim = false,
    this.titleMaxLines = 2,
    this.padding = const EdgeInsets.symmetric(vertical: 12),
    this.semanticLabel,
  });

  final String title;
  final Widget? leading;

  /// Width of the leading column, used to inset the divider to the text.
  final double leadingExtent;

  /// Centre a small [leading] on the title line (default). False centres it on
  /// the whole text block, which suits a tall icon tile.
  final bool leadingOnTitle;
  final String? subtitle;

  /// A third, quieter line. Screens usually fold it into [subtitle].
  final String? subtitle2;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool divider;

  /// Stale data: whole row at reduced opacity.
  final bool dim;

  /// Titles wrap to two lines by default: the tail of a long task title is
  /// often what tells two agents apart.
  final int titleMaxLines;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  static const _leadingGap = 12.0;
  static const _inset = 8.0;
  static const _minHeight = 56.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final indent = Gap.gutter + (leading == null ? 0 : leadingExtent + _leadingGap);
    final titleLine = MediaQuery.textScalerOf(context).scale(Type.row.fontSize!) * Type.row.height!;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: titleMaxLines,
          overflow: TextOverflow.ellipsis,
          style: Type.row.copyWith(color: ds.text),
        ),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ),
        if (subtitle2 != null && subtitle2!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              subtitle2!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: ds.textMuted),
            ),
          ),
      ],
    );
    Widget row = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressBuilder(
          onTap: onTap,
          onLongPress: onLongPress,
          semanticLabel: semanticLabel,
          builder: (context, pressed) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: _inset),
            child: AnimatedContainer(
              duration: Motion.pressing(pressed),
              curve: Motion.easeOut,
              constraints: const BoxConstraints(minHeight: _minHeight),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: pressed ? ds.fill : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.row),
              ),
              padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - _inset).add(padding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: leadingOnTitle ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                      children: [
                        if (leading != null) ...[
                          if (leadingOnTitle)
                            _TitleLineSlot(width: leadingExtent, lineHeight: titleLine, child: leading!)
                          else
                            SizedBox(width: leadingExtent, child: Center(child: leading)),
                          const SizedBox(width: _leadingGap),
                        ],
                        Expanded(child: text),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[const SizedBox(width: 12), trailing!],
                ],
              ),
            ),
          ),
        ),
        if (divider) Hairline(indent: indent, endIndent: 0),
      ],
    );
    // An Opacity layer only for the rare stale row, never for the usual one.
    if (dim) row = Opacity(opacity: 0.55, child: row);
    return row;
  }
}

/// Fixed-width slot whose child is centred on the first text line when it is
/// shorter than the line, and top-aligned when it is taller.
class _TitleLineSlot extends SingleChildRenderObjectWidget {
  const _TitleLineSlot({required this.width, required this.lineHeight, required super.child});

  final double width;
  final double lineHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderTitleLineSlot(width, lineHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderTitleLineSlot renderObject) {
    renderObject
      ..width = width
      ..lineHeight = lineHeight;
  }
}

class _RenderTitleLineSlot extends RenderShiftedBox {
  _RenderTitleLineSlot(this._width, this._lineHeight) : super(null);

  double _width;
  double _lineHeight;

  set width(double v) {
    if (v == _width) return;
    _width = v;
    markNeedsLayout();
  }

  set lineHeight(double v) {
    if (v == _lineHeight) return;
    _lineHeight = v;
    markNeedsLayout();
  }

  @override
  double computeMinIntrinsicWidth(double height) => _width;

  @override
  double computeMaxIntrinsicWidth(double height) => _width;

  @override
  double computeMinIntrinsicHeight(double width) =>
      math.max(_lineHeight, child?.getMinIntrinsicHeight(_width) ?? 0);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      math.max(_lineHeight, child?.getMaxIntrinsicHeight(_width) ?? 0);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final childSize = child?.getDryLayout(BoxConstraints(maxWidth: _width)) ?? Size.zero;
    return constraints.constrain(Size(_width, math.max(_lineHeight, childSize.height)));
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.constrain(Size(_width, _lineHeight));
      return;
    }
    c.layout(BoxConstraints(maxWidth: _width), parentUsesSize: true);
    size = constraints.constrain(Size(_width, math.max(_lineHeight, c.size.height)));
    (c.parentData! as BoxParentData).offset =
        Offset((size.width - c.size.width) / 2, (size.height - c.size.height) / 2);
  }
}

/// Section header in sentence case ("Needs you  2"), optionally collapsible
/// with a rotating chevron, like Notion's "Recents ⌄".
///
/// Announced as a heading; a collapsible one is also a button that reports its
/// expanded state.
class SectionLabel extends StatelessWidget {
  const SectionLabel({
    super.key,
    required this.label,
    this.count,
    this.expanded,
    this.onTap,
    this.leading,
    this.trailing,
  });

  final String label;
  final int? count;

  /// Null = not collapsible (no chevron).
  final bool? expanded;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      header: true,
      expanded: expanded,
      child: PressBuilder(
        onTap: onTap,
        haptic: true,
        builder: (context, pressed) => Padding(
          // A trailing action is a 44dp hit box: it brings its own height, so
          // the label's air above and below shrinks to keep the rhythm.
          padding: EdgeInsets.fromLTRB(
            Gap.gutter,
            trailing == null ? 22 : 8,
            Gap.gutter,
            trailing == null ? 6 : 0,
          ),
          child: Row(
            children: [
              if (leading != null) ...[leading!, const SizedBox(width: 8)],
              // Label, count and chevron share the leftover width; only the label
              // yields (ellipsis), so counts and the chevron are never truncated.
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: AnimatedDefaultTextStyle(
                        duration: Motion.pressing(pressed),
                        curve: Motion.easeOut,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.label.copyWith(
                          color: pressed ? ds.text : ds.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                        child: Text(label),
                      ),
                    ),
                    if (count != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '$count',
                        style: Type.label.copyWith(color: ds.textMuted, fontFeatures: Type.tabular),
                      ),
                    ],
                    if (expanded != null) ...[
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: expanded! ? 0 : -0.25,
                        duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
                        curve: Motion.easeOut,
                        child: Icon(LucideIcons.chevronDown, size: 14, color: ds.textTertiary),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapses [child] with a height + opacity transition, in both directions.
///
/// The child stays mounted until the closing animation has finished (so rows
/// visibly fold away instead of vanishing and leaving a blank gap), then is
/// unmounted. While closing it is inert: no taps, no focus, no semantics.
class Collapse extends StatefulWidget {
  const Collapse({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<Collapse> createState() => _CollapseState();
}

class _CollapseState extends State<Collapse> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, value: widget.open ? 1 : 0);
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: Motion.easeOut,
    // Closing is an ease-out in time too, not the opening curve played backwards.
    reverseCurve: Motion.easeOut.flipped,
  );

  /// Lets the child move between wrappers (clip/fade while animating, bare when
  /// fully open) without being rebuilt from scratch.
  final _bodyKey = GlobalKey();

  @override
  void didUpdateWidget(Collapse old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    _controller.duration = Motion.reduced(context) ? Duration.zero : Motion.expand;
    widget.open ? _controller.forward() : _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _progress,
        child: KeyedSubtree(key: _bodyKey, child: widget.child),
        builder: (context, child) {
          final v = _progress.value;
          if (v <= 0) return const SizedBox(width: double.infinity);
          return ExcludeFocus(
            excluding: !widget.open,
            child: ExcludeSemantics(
              excluding: !widget.open,
              child: IgnorePointer(
                ignoring: !widget.open,
                child: v >= 1
                    ? child!
                    : ClipRect(
                        child: Align(
                          alignment: Alignment.topCenter,
                          heightFactor: v,
                          child: Opacity(opacity: v, child: child),
                        ),
                      ),
              ),
            ),
          );
        },
      );
}

/// Quiet empty state: text first, one optional action. The art is an [icon]
/// on a soft tile, or a [mark] widget in its place (the brand mark on first
/// run).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    this.icon,
    this.mark,
    required this.title,
    required this.message,
    this.action,
  }) : assert((icon == null) != (mark == null), 'an icon or a mark, not both');

  final IconData? icon;
  final Widget? mark;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              mark ??
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: ds.fill,
                      borderRadius: BorderRadius.circular(Radii.emptyTile),
                    ),
                    child: Icon(icon, size: 24, color: ds.textSecondary),
                  ),
              const SizedBox(height: Gap.lg),
              Semantics(
                header: true,
                child: Text(title, style: Type.title.copyWith(color: ds.text), textAlign: TextAlign.center),
              ),
              const SizedBox(height: Gap.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Type.compact.copyWith(color: ds.textSecondary),
              ),
              if (action != null) ...[const SizedBox(height: Gap.xl), action!],
            ],
          ),
        ),
      ),
    );
  }
}

/// Last path segment, for compact cwd display.
String cwdTail(String? cwd) {
  if (cwd == null || cwd.isEmpty) return '';
  final parts = cwd.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? '/' : parts.last;
}
