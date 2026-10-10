import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/chrome.dart';
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
class SettingsGroup extends StatefulWidget {
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
  State<SettingsGroup> createState() => _SettingsGroupState();
}

class _SettingsGroupState extends State<SettingsGroup> {
  Timer? _reveal;

  @override
  void didUpdateWidget(SettingsGroup old) {
    super.didUpdateWidget(old);
    if (!old.open && widget.open) _scheduleReveal();
    if (!widget.open) _reveal?.cancel();
  }

  @override
  void dispose() {
    _reveal?.cancel();
    super.dispose();
  }

  /// Once the folds have finished (this group opening, the one above it
  /// closing), so the geometry it aims at is the final one. Reduced motion
  /// folds at once and jumps.
  void _scheduleReveal() {
    _reveal?.cancel();
    if (Motion.reduced(context)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollIntoView(jump: true));
    } else {
      _reveal = Timer(Motion.expand + const Duration(milliseconds: 30), () => _scrollIntoView(jump: false));
    }
  }

  /// Brings the open group between the pinned bar and the tab bar: the least
  /// movement when it fits (often none), and its row at the top when it is
  /// taller than the space, so the first control is never under the tab bar.
  /// Why: at a large text size the rows below the first sit at the bottom of
  /// the screen, and a tap that only turns a caret reads as nothing happening.
  void _scrollIntoView({required bool jump}) {
    if (!mounted || !widget.open) return;
    final scrollable = Scrollable.maybeOf(context);
    final box = context.findRenderObject();
    if (scrollable == null || box is! RenderBox || !box.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final position = scrollable.position;
    final atTop = viewport.getOffsetToReveal(box, 0).offset - SliverLargeTitle.collapsedExtent(context);
    final atEnd = viewport.getOffsetToReveal(box, 1).offset + FloatingBar.clearance(context);
    final target = (atEnd <= atTop ? position.pixels.clamp(atEnd, atTop) : atTop)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return;
    if (jump) {
      position.jumpTo(target);
    } else {
      unawaited(position.animateTo(target, duration: Motion.standard, curve: Motion.easeOut));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final w = widget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          expanded: w.open,
          liveRegion: w.announce,
          child: ListRow(
            leading: IconTile(icon: w.icon, size: 32, color: w.tint),
            leadingOnTitle: false,
            title: w.title,
            subtitle: w.summary,
            subtitleMaxLines: 2,
            divider: w.divider && !w.open && w.footer == null,
            onTap: w.onToggle,
            // The app's fold caret: right when closed, down when open (as in
            // `FormSectionHeader`), not a third meaning for a chevron.
            trailing: ExcludeSemantics(
              child: AnimatedRotation(
                turns: w.open ? 0.25 : 0,
                duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
                curve: Motion.easeOut,
                child: Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
              ),
            ),
          ),
        ),
        ?w.footer,
        Collapse(
          open: w.open,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...w.children, const SizedBox(height: Gap.sm)],
          ),
        ),
        if (w.divider && (w.open || w.footer != null)) const Hairline(indent: Gap.gutter + 32 + 12),
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
