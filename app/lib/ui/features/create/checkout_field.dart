import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/worktrees.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'machine_field.dart' show MachineField, fieldMinHeight, shortPath;
import 'new_agent_session_view_model.dart';

/// Where in the folder's repo the session runs: the folder itself, a checkout
/// that exists, or a new worktree. A field that opens a sheet, painted like
/// [MachineField] and a [LabeledField] (same label, outline, text inset and
/// helper line) so the three sit in one form as equals.
class CheckoutField extends StatelessWidget {
  const CheckoutField({
    super.key,
    required this.folder,
    required this.checkouts,
    required this.choice,
    required this.agentsWorking,
    required this.onSelect,
  });

  /// The typed folder (trimmed).
  final String folder;

  /// Every checkout of the folder's repo.
  final List<WorktreeInfo> checkouts;
  final CheckoutChoice choice;

  /// How many agents are working in a checkout's path or below.
  final int Function(String path) agentsWorking;
  final ValueChanged<CheckoutChoice> onSelect;

  WorktreeInfo? _entry(String path) {
    for (final c in checkouts) {
      if (c.path == path) return c;
    }
    return null;
  }

  String get _text => switch (choice) {
    ThisFolder() => 'This folder',
    ExistingCheckout(:final path) => _entry(path)?.name ?? _nameOf(path),
    NewWorktree() => 'New worktree',
  };

  String get _helper {
    switch (choice) {
      case ThisFolder():
        final n = agentsWorking(folder);
        if (n > 0) return '${countOf(n, 'agent')} working here · a worktree keeps them apart';
        return _entry(folder)?.branch ?? ' ';
      case ExistingCheckout(:final path):
        final n = agentsWorking(path);
        return '${_entry(path)?.branch ?? 'detached'}${n > 0 ? ' · $n working here' : ''}';
      case NewWorktree():
        return 'Branches from the current commit of this folder';
    }
  }

  void _choose(BuildContext context) {
    final others = [
      for (final c in checkouts)
        if (c.path != folder) c,
    ];
    showAppSheet<void>(
      context,
      builder: (ctx) {
        final ds = ctx.ds;
        Widget row({
          required String title,
          required String subtitle,
          required IconData icon,
          required bool selected,
          required CheckoutChoice picks,
        }) => ListRow(
          title: title,
          subtitle: subtitle,
          leading: Icon(selected ? LucideIcons.check : icon, size: IconSize.lead, color: ds.textSecondary),
          onTap: () {
            Navigator.of(ctx).pop();
            onSelect(picks);
          },
        );

        final rows = [
          row(
            title: 'This folder',
            subtitle: shortPath(folder),
            icon: LucideIcons.folder,
            selected: choice is ThisFolder,
            picks: const ThisFolder(),
          ),
          for (final c in others)
            row(
              title: c.isLinked ? c.name : 'Main checkout',
              subtitle: [
                c.branch ?? 'detached',
                if (agentsWorking(c.path) case final n when n > 0) '$n working',
                if (c.openWorkspaceId == null) 'not open in herdr',
              ].join(' · '),
              icon: c.isLinked ? LucideIcons.gitBranch : LucideIcons.folder,
              selected: choice == ExistingCheckout(c.path),
              picks: ExistingCheckout(c.path),
            ),
          row(
            title: 'New worktree…',
            subtitle: 'A new folder and branch next to this repo',
            icon: LucideIcons.gitBranchPlus,
            selected: choice is NewWorktree,
            picks: const NewWorktree(),
          ),
        ];
        return SheetScaffold(
          title: 'Checkout',
          kind: SheetKind.list,
          // The rows bring their own gutter.
          bleed: true,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < rows.length; i++) ...[if (i > 0) Hairline(indent: ListRow.textIndent()), rows[i]],
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: ExcludeSemantics(
            child: Text('Checkout', style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        PressBuilder(
          onTap: () => _choose(context),
          semanticLabel: 'Checkout, $_text',
          button: true,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: fieldMinHeight),
            padding: const EdgeInsets.symmetric(horizontal: MachineField.textInset),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: pressed ? ds.fill : ds.surface,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: ds.controlBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.input.copyWith(color: ds.text),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Icon(LucideIcons.chevronsUpDown, size: IconSize.row, color: ds.textTertiary),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: Gap.lg, top: Gap.sm, right: Gap.lg),
          child: Text(
            _helper,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Type.caption.copyWith(color: ds.textMuted),
          ),
        ),
      ],
    );
  }
}

String _nameOf(String path) {
  final parts = path.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? '/' : parts.last;
}
