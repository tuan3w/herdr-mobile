import 'dart:math' as math;

import 'package:flutter/material.dart';
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
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,
    this.leading,
    this.leadingExtent = 32,
    this.subtitle,
    this.subtitle2,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.divider = true,
    this.dim = false,
    this.titleMaxLines = 1,
    this.padding = const EdgeInsets.symmetric(vertical: 12),
    this.semanticLabel,
  });

  final String title;
  final Widget? leading;

  /// Width of [leading], used to inset the divider to the text.
  final double leadingExtent;
  final String? subtitle;
  final String? subtitle2;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool divider;

  /// Stale data: whole row at reduced opacity.
  final bool dim;
  final int titleMaxLines;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  static const _leadingGap = 14.0;
  static const _inset = 8.0;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final indent = Gap.gutter + (leading == null ? 0 : leadingExtent + _leadingGap);
    return Opacity(
      opacity: dim ? 0.55 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PressBuilder(
            onTap: onTap,
            onLongPress: onLongPress,
            semanticLabel: semanticLabel ?? title,
            builder: (context, pressed) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: _inset),
              child: AnimatedContainer(
                duration: pressed ? Motion.press : Motion.release,
                curve: Motion.easeOut,
                decoration: BoxDecoration(
                  color: pressed ? ds.fill : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(horizontal: Gap.gutter - _inset)
                    .add(padding),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (leading != null) ...[
                      SizedBox(width: leadingExtent, child: Center(child: leading)),
                      const SizedBox(width: _leadingGap),
                    ],
                    Expanded(
                      child: Column(
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
                                style: Type.secondary.copyWith(color: ds.textTertiary),
                              ),
                            ),
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
      ),
    );
  }
}

/// Section header in sentence case ("Needs you  2"), optionally collapsible
/// with a rotating chevron, like Notion's "Recents ⌄".
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
    return PressBuilder(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, pressed) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.gutter, 22, Gap.gutter, 6),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            // Label, count and chevron share the leftover width; only the label
            // yields (ellipsis), so counts and the chevron are never truncated.
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (count != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '$count',
                      style: Type.label.copyWith(color: ds.textTertiary, fontFeatures: Type.tabular),
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
    );
  }
}

/// Collapses [child] with a height + opacity transition.
class Collapse extends StatelessWidget {
  const Collapse({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
        curve: Motion.easeOut,
        alignment: Alignment.topCenter,
        child: open ? child : const SizedBox(width: double.infinity),
      );
}

/// Quiet empty state: text first, one optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
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
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: ds.fill,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 24, color: ds.textSecondary),
              ),
              const SizedBox(height: Gap.lg),
              Text(title, style: Type.title.copyWith(color: ds.text), textAlign: TextAlign.center),
              const SizedBox(height: Gap.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Type.body.copyWith(color: ds.textSecondary, fontSize: 14.5),
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
