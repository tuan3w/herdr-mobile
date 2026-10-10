import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';

/// One group of Settings: a row that says what the group is set to now, and
/// opens in place to show its controls. The page keeps one group open, so it
/// stays four or five rows long however many settings a group grows to.
///
/// The row shows values, not setting names ("Light · Auto · 11.5 pt"): the
/// person sees what is set without opening anything. [tint] colours the tile
/// for the two things that need a look (notifications Android is blocking, a
/// newer version); nothing else is coloured.
///
/// A closed group is not built, so a hidden control costs nothing; it stays
/// mounted while it folds away ([Collapse]).
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({
    super.key,
    required this.icon,
    required this.title,
    required this.summary,
    required this.open,
    required this.onToggle,
    required this.children,
    this.tint,
    this.divider = true,
    this.footer,
    this.announce = false,
  });

  final IconData icon;
  final String title;

  /// What the group is set to: a line, wrapping to a second at large text sizes
  /// rather than hiding the value.
  final String summary;
  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;
  final Color? tint;

  /// A hairline under the group, inset to the text. Not under the last one.
  final bool divider;

  /// Under the row, whether the group is open or not: a download's progress.
  final Widget? footer;

  /// The summary is news a screen reader announces when it changes (a download
  /// that finished or failed), even with the group closed.
  final bool announce;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: open,
          liveRegion: announce,
          child: ListRow(
            leading: IconTile(icon: icon, size: 32, color: tint),
            leadingOnTitle: false,
            title: title,
            subtitle: summary,
            subtitleMaxLines: 2,
            divider: divider && !open && footer == null,
            onTap: onToggle,
            // The app's fold caret: right when closed, down when open (as in
            // `FormSectionHeader`), not a third meaning for a chevron.
            trailing: ExcludeSemantics(
              child: AnimatedRotation(
                turns: open ? 0.25 : 0,
                duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
                curve: Motion.easeOut,
                child: Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
              ),
            ),
          ),
        ),
        ?footer,
        Collapse(
          open: open,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...children, const SizedBox(height: Gap.sm)],
          ),
        ),
        if (divider && (open || footer != null)) const Hairline(indent: Gap.gutter + 32 + 12),
      ],
    );
  }
}

/// A control's title over the control and an optional line saying what it
/// does, inset to the page gutter: a group's body.
class SettingsField extends StatelessWidget {
  const SettingsField({super.key, required this.title, required this.child, this.hint});

  final String title;
  final Widget child;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, Gap.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Type.row.copyWith(color: ds.text)),
          const SizedBox(height: Gap.sm),
          child,
          if (hint != null) ...[
            const SizedBox(height: Gap.sm),
            Text(hint!, style: Type.secondary.copyWith(color: ds.textSecondary)),
          ],
        ],
      ),
    );
  }
}
