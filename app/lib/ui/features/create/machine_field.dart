import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/repositories/machine_connection.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

/// The machine, as a field that opens a sheet of the online ones. With one
/// machine it only says where. Painted like a [LabeledField]: same label,
/// outline, text inset and helper line, so the two sit in one form as equals.
class MachineField extends StatelessWidget {
  const MachineField({
    super.key,
    required this.machine,
    required this.choices,
    required this.lost,
    required this.onSelect,
  });

  /// The machine chosen, if it is still online.
  final MachineConnection? machine;

  /// Every machine the form offers.
  final List<MachineConnection> choices;

  /// The chosen machine went offline since it was picked.
  final bool lost;
  final ValueChanged<String> onSelect;

  /// Padding inside the outline, so the text sits [Gap.lg] in from the field's
  /// edge like a [LabeledField]'s (the 1 dp outline makes up the rest).
  static const textInset = Gap.lg - 1;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final machine = this.machine;
    final canChoose = choices.length > 1;

    void choose() => showActionSheet(
      context,
      title: 'Machine',
      actions: [
        for (final c in choices)
          SheetAction(
            label: c.profile.label,
            icon: c.profile.id == machine?.profile.id ? LucideIcons.check : HerdrIcons.machines,
            onTap: () => onSelect(c.profile.id),
          ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.sm),
          child: ExcludeSemantics(
            child: Text('Machine', style: Type.label.copyWith(color: ds.textSecondary)),
          ),
        ),
        PressBuilder(
          onTap: canChoose ? choose : null,
          semanticLabel: 'Machine, ${machine?.profile.label ?? 'none chosen'}',
          button: canChoose,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: fieldMinHeight),
            padding: const EdgeInsets.symmetric(horizontal: textInset),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: pressed ? ds.fill : ds.surface,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: lost ? ds.danger : ds.controlBorder),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    machine?.profile.label ?? 'Choose a machine',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.input.copyWith(color: machine == null ? ds.textMuted : ds.text),
                  ),
                ),
                if (canChoose) ...[
                  const SizedBox(width: Gap.sm),
                  Icon(LucideIcons.chevronsUpDown, size: IconSize.row, color: ds.textTertiary),
                ],
              ],
            ),
          ),
        ),
        // Helper text starts where the field's text starts, as a
        // [LabeledField]'s does (its helper line sits under its input text).
        Padding(
          padding: const EdgeInsets.only(left: Gap.lg, top: Gap.sm, right: Gap.lg),
          child: Text(
            lost
                ? 'That machine went offline. Pick another.'
                : machine == null
                ? ' '
                : '${machine.profile.username}@${machine.profile.host}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Type.caption.copyWith(color: lost ? ds.dangerText : ds.textMuted),
          ),
        ),
      ],
    );
  }
}

/// Folders already open on the machine, one tap to reuse.
class RecentFolders extends StatelessWidget {
  const RecentFolders({super.key, required this.paths, required this.selected, required this.onPick});

  final List<String> paths;
  final String selected;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    if (paths.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.hair),
          child: Text('Open on this machine', style: Type.label.copyWith(color: context.ds.textSecondary)),
        ),
        Wrap(
          spacing: Gap.sm,
          children: [
            for (final path in paths)
              AppChip(label: shortPath(path), selected: path == selected, onTap: () => onPick(path)),
          ],
        ),
      ],
    );
  }
}

/// `…/workspace/herdr-mobile`: the last two segments, cut from the front when
/// still long, so a chip is never wider than the screen.
String shortPath(String path, {int max = 26}) {
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  final tail = parts.length <= 2 ? parts.join('/') : '…/${parts.sublist(parts.length - 2).join('/')}';
  if (tail.length <= max) return tail;
  return '…${tail.substring(tail.length - (max - 1))}';
}

/// The field's height at one line of input, matching the kit's text fields.
const fieldMinHeight = 46.0;
