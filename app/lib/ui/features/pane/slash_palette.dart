import 'package:flutter/material.dart';

import '../../../data/models/slash_command.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'slash_view_model.dart';

const slashRowHeight = 48.0;

/// How many rows show before the list scrolls; the half row says it scrolls.
const _visibleRows = 4.5;

/// The commands [input] is the start of, above the key row. It is empty (no
/// space at all) unless the composer holds a lone `/word` that something
/// completes. A tap puts the whole command into the composer; the keyboard
/// stays up for its arguments.
class SlashPalette extends StatelessWidget {
  const SlashPalette({
    super.key,
    required this.input,
    required this.model,
    required this.onPick,
  });

  final TextEditingController input;
  final SlashViewModel model;
  final ValueChanged<SlashCommand> onPick;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([input, model]),
        builder: (context, _) {
          final matches = model.match(input.text);
          if (matches.isEmpty) return const SizedBox.shrink();
          final ds = context.ds;
          return Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: ds.surface,
                borderRadius: BorderRadius.circular(Radii.panel),
                border: Border.all(color: ds.hairline),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.panel),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: slashRowHeight * _visibleRows),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemExtent: slashRowHeight,
                    itemCount: matches.length,
                    itemBuilder: (_, i) => _Row(command: matches[i], onTap: onPick),
                  ),
                ),
              ),
            ),
          );
        },
      );
}

class _Row extends StatelessWidget {
  const _Row({required this.command, required this.onTap});

  final SlashCommand command;
  final ValueChanged<SlashCommand> onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final tag = switch (command.source) {
      SlashSource.project => 'project',
      SlashSource.user => 'user',
      SlashSource.builtIn => null,
    };
    return PressBuilder(
      onTap: () {
        tapFeedback();
        onTap(command);
      },
      builder: (context, pressed) => ColoredBox(
        color: pressed ? ds.fillPressed : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      command.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: monoFamily,
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w500,
                        color: ds.text,
                      ),
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
                Text(tag, maxLines: 1, style: Type.caption.copyWith(color: ds.accentText)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
