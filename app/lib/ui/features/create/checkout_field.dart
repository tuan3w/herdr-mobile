import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/worktrees.dart';

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

  String _text(BuildContext context) => switch (choice) {
    ThisFolder() => context.l10n.uiThisFolder,
    ExistingCheckout(:final path) => _entry(path)?.name ?? _nameOf(path),
    NewWorktree() => context.l10n.uiNewWorktreeValue,
  };

  String _helper(BuildContext context) {
    final l10n = context.l10n;
    switch (choice) {
      case ThisFolder():
        final n = agentsWorking(folder);
        if (n > 0) return l10n.messageAgentsWorkingHereAWorktreeKeepsThemApart(n);
        return _entry(folder)?.branch ?? ' ';
      case ExistingCheckout(:final path):
        final n = agentsWorking(path);
        return '${_entry(path)?.branch ?? l10n.uiDetached}${n > 0 ? ' · ${l10n.messageWorkingHereCount(n)}' : ''}';
      case NewWorktree():
        return l10n.messageBranchesFromCurrentCommit;
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
            title: context.l10n.uiThisFolder,
            subtitle: shortPath(folder),
            icon: LucideIcons.folder,
            selected: choice is ThisFolder,
            picks: const ThisFolder(),
          ),
          for (final c in others)
            row(
              title: c.isLinked ? c.name : context.l10n.uiMainCheckout,
              subtitle: [
                c.branch ?? context.l10n.uiDetached,
                if (agentsWorking(c.path) case final n when n > 0) context.l10n.messageWorking('$n'),
                if (c.openWorkspaceId == null) context.l10n.uiNotOpenInHerdr,
              ].join(' · '),
              icon: c.isLinked ? LucideIcons.gitBranch : LucideIcons.folder,
              selected: choice == ExistingCheckout(c.path),
              picks: ExistingCheckout(c.path),
            ),
          row(
            title: context.l10n.uiNewWorktree,
            subtitle: context.l10n.uiANewFolderAndBranchNextToThisRepo,
            icon: LucideIcons.gitBranchPlus,
            selected: choice is NewWorktree,
            picks: const NewWorktree(),
          ),
        ];
        return SheetScaffold(
          title: context.l10n.uiCheckout,
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
    final text = _text(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: ExcludeSemantics(
            child: Text(context.l10n.uiCheckout, style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        PressBuilder(
          onTap: () => _choose(context),
          semanticLabel: context.l10n.messageCheckout(text),
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
                    text,
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
            _helper(context),
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
