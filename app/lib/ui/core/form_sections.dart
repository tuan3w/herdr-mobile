import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'controls.dart';
import 'motion.dart';
import 'rows.dart';
import 'toast.dart';
import 'tokens.dart';

/// A section title over a [FormPanel] of fields. Titles are `barTitle` in the
/// text colour so they read as headers, not as one more field label.
class FormSection extends StatelessWidget {
  const FormSection({
    super.key,
    required this.label,
    required this.children,
    this.endsWithField = true,
  });

  final String label;
  final List<Widget> children;

  /// The last child is a field, whose reserved message line already gives the
  /// panel its bottom breathing room.
  final bool endsWithField;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FormSectionHeader(label: label),
          FormPanel(endsWithField: endsWithField, children: children),
        ],
      );
}

class FormSectionHeader extends StatelessWidget {
  const FormSectionHeader({super.key, required this.label, this.expanded, this.onTap});

  final String label;

  /// Null = not collapsible (no chevron).
  final bool? expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      header: true,
      expanded: expanded,
      child: PressBuilder(
        onTap: onTap,
        haptic: true,
        builder: (context, pressed) => Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, 0),
          alignment: Alignment.bottomLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Type.barTitle.copyWith(color: pressed ? ds.textSecondary : ds.text),
                ),
              ),
              if (expanded != null) ...[
                const SizedBox(width: Gap.sm),
                AnimatedRotation(
                  turns: expanded! ? 0.25 : 0,
                  duration: Motion.reduced(context) ? Duration.zero : Motion.standard,
                  curve: Motion.easeOut,
                  child: Icon(LucideIcons.chevronRight, size: 16, color: ds.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Fields grouped on a surface with a hairline: the grouping reads as one unit.
class FormPanel extends StatelessWidget {
  const FormPanel({super.key, required this.children, this.endsWithField = true});

  final List<Widget> children;
  final bool endsWithField;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: ds.surface,
          borderRadius: BorderRadius.circular(Radii.panel),
          border: Border.all(color: ds.hairline),
        ),
        child: Padding(
          padding: EdgeInsets.fromLTRB(Gap.lg, Gap.lg, Gap.lg, endsWithField ? 0 : Gap.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: Gap.sm),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The primary actions of a form, pinned under it so they are never a scroll
/// away. Place it under the form's scroll view in a column: it sits above the
/// keyboard (the Scaffold body shrinks), and the form scrolls independently, so
/// a focused field is never covered by it.
///
/// Buttons are chrome: like the tab bar they stop growing at 1.3x so labels
/// stay whole; the form above scales freely.
class FormActionBar extends StatelessWidget {
  const FormActionBar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ToastShelf(aboveKeyboard: true, child: _bar(context));

  Widget _bar(BuildContext context) {
    final ds = context.ds;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: DecoratedBox(
        decoration: BoxDecoration(color: ds.bg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Hairline(),
            Padding(
              padding: EdgeInsets.fromLTRB(
                Gap.gutter,
                Gap.md,
                Gap.gutter,
                Gap.md + MediaQuery.paddingOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [child],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
