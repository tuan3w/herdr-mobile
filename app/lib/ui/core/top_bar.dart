import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'buttons.dart';
import 'motion.dart';
import 'press.dart';
import 'tokens.dart';

/// The one Back control: a chevron [CircleButton] that pops the route, or
/// runs [onPressed] when the screen has to leave its own way.
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => CircleButton(
    icon: LucideIcons.chevronLeft,
    tooltip: 'Back',
    onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
  );
}

/// The slim bar above a detail screen: Back, an optional status [glyph]
/// beside the title over one quiet [subtitle] line, and at most two trailing
/// [actions] (⋯ included). It pads itself below the status bar.
///
/// [onTitleTap] makes the whole title block a button (a pressed tint, no
/// scale); [titleTapLabel] then names what it does for a screen reader.
/// [titleTrailing] sits right after the title text (the agent switcher's
/// chevron and count). [bottom] sits under the row, lined up with the title.
/// [overlay] draws the bar over a photo: a scrim gradient and light marks.
/// Text is clamped at [kBarTextScale] so large text never pushes the actions
/// off the bar.
class AppTopBar extends StatelessWidget {
  const AppTopBar({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.subtitleAlert,
    this.subtitleLine,
    this.glyph,
    this.actions = const [],
    this.onTitleTap,
    this.titleTapLabel,
    this.titleTrailing,
    this.bottom,
    this.overlay = false,
    this.announceTitle = false,
  }) : assert(actions.length <= 2, 'A bar carries at most two trailing actions, ⋯ included.');

  /// Defaults to [AppBackButton].
  final Widget? leading;
  final String title;
  final String? subtitle;

  /// A warning after [subtitle], in the danger tone, kept whole until the
  /// line is narrower than it (the subtitle yields first).
  final String? subtitleAlert;

  /// A line drawn its own way in place of [subtitle] (a path cut at its
  /// start, so the folder that differs stays).
  final Widget? subtitleLine;

  /// Status glyph left of the title, [IconSize.row].
  final Widget? glyph;
  final List<Widget> actions;
  final VoidCallback? onTitleTap;

  /// What the title button does, said before the texts inside it (`Switch
  /// agent`, then the status, the title and the subtitle).
  final String? titleTapLabel;

  /// Drawn after the title text on its line, never cut: the title yields.
  final Widget? titleTrailing;
  final Widget? bottom;
  final bool overlay;

  /// Read the title out when it changes (a photo's `3 of 12`).
  final bool announceTitle;

  static const height = 56.0;

  /// A phone on its side: the bar and docked answers get less.
  static const shortHeight = 52.0;
  static const _shortScreen = 520.0;

  /// Whether the screen is short enough ([_shortScreen]) for the lower bar.
  static bool isShort(BuildContext context) => MediaQuery.sizeOf(context).height < _shortScreen;

  /// Where the title text starts, from the bar's padded edge: past the
  /// leading control and the title block's own inset.
  /// From the screen edge to a bar's round buttons, here and on a large
  /// title: a 40 dp circle in its 44 dp touch box paints 16 from the edge, so
  /// Back does not move between a list and the page it opens.
  static const edge = Gap.md + Gap.hair;

  static const _titleInset = kMinTap + Gap.xs + Gap.sm;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final rowHeight = isShort(context) ? shortHeight : height;
    final fg = overlay ? ds.onPhoto : ds.text;
    final quiet = overlay ? ds.onPhoto : ds.textSecondary;
    final subtitle = this.subtitle;
    final alert = subtitleAlert;
    final glyph = this.glyph;

    Widget? second = subtitleLine;
    if (second == null && (subtitle != null || alert != null)) {
      final subtitleText = subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Type.secondary.copyWith(color: quiet),
            );
      second = alert == null
          ? subtitleText
          : LayoutBuilder(
              builder: (context, box) => Row(
                children: [
                  if (subtitleText != null) Flexible(child: subtitleText),
                  if (subtitleText != null) const SizedBox(width: Gap.sm),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: box.maxWidth - (subtitleText == null ? 0 : Gap.sm)),
                    child: Text(
                      alert,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Type.secondaryStrong.copyWith(color: ds.dangerText, fontFeatures: Type.tabular),
                    ),
                  ),
                ],
              ),
            );
    }

    final titleText = Semantics(
      header: true,
      liveRegion: announceTitle,
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Type.barTitle.copyWith(color: fg),
      ),
    );

    Widget titleBlock(bool pressed) => AnimatedContainer(
      duration: Motion.pressing(pressed),
      curve: Motion.easeOut,
      constraints: BoxConstraints(minHeight: rowHeight),
      padding: const EdgeInsets.symmetric(horizontal: Gap.sm),
      decoration: BoxDecoration(
        color: pressed ? ds.pressTint : ds.pressTint.withAlpha(0),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          if (glyph != null) ...[glyph, const SizedBox(width: Gap.sm)],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (titleTrailing case final trailing?)
                  Row(
                    children: [
                      Flexible(child: titleText),
                      const SizedBox(width: Gap.xs),
                      trailing,
                    ],
                  )
                else
                  titleText,
                ?second,
              ],
            ),
          ),
        ],
      ),
    );

    final onTitleTap = this.onTitleTap;
    final titleArea = onTitleTap == null
        ? MergeSemantics(child: titleBlock(false))
        : PressBuilder(
            onTap: onTitleTap,
            minTapSize: kMinTap,
            builder: (context, pressed) => titleTapLabel == null
                ? titleBlock(pressed)
                : Semantics(label: titleTapLabel, child: titleBlock(pressed)),
          );

    final bottom = this.bottom;
    Widget bar = Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: edge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                leading ?? const AppBackButton(),
                const SizedBox(width: Gap.xs),
                Expanded(child: titleArea),
                ...actions,
              ],
            ),
            if (bottom != null)
              Padding(
                padding: const EdgeInsets.only(left: _titleInset),
                child: bottom,
              ),
          ],
        ),
      ),
    );
    bar = MediaQuery.withClampedTextScaling(maxScaleFactor: kBarTextScale, child: bar);
    if (!overlay) return bar;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [ds.photoScrim, ds.photoScrim.withAlpha(0)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(bottom: Gap.md),
        child: bar,
      ),
    );
  }
}
