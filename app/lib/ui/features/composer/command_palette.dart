import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/slash_command.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'command_model.dart';

/// Two lines of text: the row grows with the text size.
const _commandRowHeight = 52.0;

/// How many rows show before the list scrolls; the half row says it scrolls.
const _visibleRows = 4.5;

/// The commands and skills [input] is the start of, above the composer: name,
/// what the command's input is for (its hint), the description, where it comes
/// from (project, user) and whether it is pinned. The pane's composer and the
/// chat's show this one. It is empty (no space at all) unless the composer holds
/// a lone `/word` or `$word` that something completes. A tap puts the whole
/// command into the composer; the keyboard stays up for its arguments. A long
/// press pins it.
class CommandPalette extends StatelessWidget {
  const CommandPalette({super.key, required this.input, required this.model, required this.onPick});

  final TextEditingController input;
  final CommandPaletteModel model;
  final ValueChanged<SlashCommand> onPick;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([input, model]),
    builder: (context, _) {
      final matches = model.match(input.text);
      if (matches.isEmpty) return const SizedBox.shrink();
      final ds = context.ds;
      final rows = matches.length < _visibleRows ? matches.length.toDouble() : _visibleRows;
      final rowHeight = MediaQuery.textScalerOf(context).scale(_commandRowHeight);
      return Padding(
        padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.sm),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ds.surface,
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: ds.hairline),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.md),
            child: SizedBox(
              height: rows * rowHeight,
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemExtent: rowHeight,
                itemCount: matches.length,
                itemBuilder: (_, i) => _Row(
                  command: matches[i],
                  pinned: model.isPinned(matches[i]),
                  onTap: onPick,
                  onLongPress: model.togglePin,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Takes [child] out of the layout while the palette above the composer lists
/// something. The rows that sit between the palette and the field (the
/// settings chips, what waits in the queue, the background strip) are not
/// what the person is acting on then, and the keyboard leaves little room: the
/// palette used to be laid over them, its rows drawn on top of theirs.
class HideWhileCommanding extends StatelessWidget {
  const HideWhileCommanding({super.key, required this.input, required this.model, required this.child});

  final TextEditingController input;
  final CommandPaletteModel? model;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final model = this.model;
    if (model == null) return child;
    return ListenableBuilder(
      listenable: Listenable.merge([input, model]),
      builder: (context, child) => model.match(input.text).isEmpty ? child! : const SizedBox.shrink(),
      child: child,
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.command, required this.pinned, required this.onTap, required this.onLongPress});

  final SlashCommand command;
  final bool pinned;
  final ValueChanged<SlashCommand> onTap;

  /// Pins or unpins the row. Always set: a row that took a long press as a
  /// tap would pick a command the person was only holding.
  final ValueChanged<SlashCommand> onLongPress;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final hint = command.hint;
    final tag = switch (command.source) {
      SlashSource.project => 'project',
      SlashSource.user => 'user',
      SlashSource.builtIn => null,
    };
    return PressRow(
      onTap: () {
        Haptics.tick();
        onTap(command);
      },
      onLongPress: () => onLongPress(command),
      // The list's itemExtent sets the height.
      minHeight: 0,
      padding: const EdgeInsets.symmetric(horizontal: Gap.lg - PressRow.inset),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: command.text,
                    style: Mono.input.copyWith(color: ds.text),
                    children: [
                      if (hint != null && hint.isNotEmpty)
                        TextSpan(
                          text: '  $hint',
                          style: Mono.base.copyWith(color: ds.textMuted),
                        ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (command.description.isNotEmpty)
                  Text(
                    command.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Type.caption.copyWith(color: ds.textMuted),
                  ),
              ],
            ),
          ),
          if (tag != null) ...[
            const SizedBox(width: Gap.sm),
            Text(tag, maxLines: 1, style: Type.caption.copyWith(color: ds.textMuted)),
          ],
          if (pinned) ...[
            const SizedBox(width: Gap.sm),
            Icon(LucideIcons.pin, size: IconSize.inline, color: ds.textTertiary, semanticLabel: context.l10n.uiPinned),
          ],
        ],
      ),
    );
  }
}
