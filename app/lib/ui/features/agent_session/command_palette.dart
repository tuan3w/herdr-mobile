import 'package:flutter/material.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/repositories/agent_session.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'session_select.dart';

const commandRowHeight = 52.0;

/// How many rows show before the list scrolls; the half row says it scrolls.
const _visibleRows = 4.5;

final _word = RegExp(r'^/\S*$');

/// The commands [input] (the composer's whole text) is the start of.
///
/// Empty unless [input] is a lone `/word`: once there is a space the command
/// is chosen and the rest is its arguments. A bare `/` lists every command in
/// the agent's order; a word lists the names that start with it, then those
/// that contain it, then those whose description does. A command typed in full
/// with nothing else to choose shows nothing.
List<AcpCommand> matchCommands(List<AcpCommand> commands, String input) {
  if (!_word.hasMatch(input)) return const [];
  final query = input.substring(1).toLowerCase();
  if (query.isEmpty) return commands;
  final starts = <AcpCommand>[];
  final inName = <AcpCommand>[];
  final inText = <AcpCommand>[];
  for (final c in commands) {
    final name = c.name.toLowerCase();
    if (name.startsWith(query)) {
      starts.add(c);
    } else if (name.contains(query)) {
      inName.add(c);
    } else if (c.description.toLowerCase().contains(query)) {
      inText.add(c);
    }
  }
  if (starts.length == 1 && starts.single.name.toLowerCase() == query && inName.isEmpty) return const [];
  return [...starts, ...inName, ...inText];
}

/// The agent's slash commands that [input] is the start of, above the
/// composer: name, what the input is for (the hint) and the description. A tap
/// puts `/name ` into the composer; the keyboard stays up for the arguments.
/// Takes no room unless something completes.
class CommandPalette extends StatelessWidget {
  const CommandPalette({super.key, required this.session, required this.input, required this.onPick});

  final AgentSessionView session;
  final TextEditingController input;
  final ValueChanged<AcpCommand> onPick;

  @override
  Widget build(BuildContext context) => SessionSelect<List<AcpCommand>>(
    session: session,
    select: (s) => s.state.commands,
    same: identical,
    builder: (context, commands) => ListenableBuilder(
      listenable: input,
      builder: (context, _) {
        final matches = matchCommands(commands, input.text);
        if (matches.isEmpty) return const SizedBox.shrink();
        final ds = context.ds;
        final rows = matches.length < _visibleRows ? matches.length.toDouble() : _visibleRows;
        // Two lines of text: the row grows with the text size.
        final rowHeight = MediaQuery.textScalerOf(context).scale(commandRowHeight);
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
              child: SizedBox(
                height: rows * rowHeight,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  itemExtent: rowHeight,
                  itemCount: matches.length,
                  itemBuilder: (_, i) => _Row(command: matches[i], onTap: onPick),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.command, required this.onTap});

  final AcpCommand command;
  final ValueChanged<AcpCommand> onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final hint = command.inputHint;
    return PressBuilder(
      onTap: () {
        Haptics.tick();
        onTap(command);
      },
      builder: (context, pressed) => ColoredBox(
        color: pressed ? ds.fillPressed : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  text: '/${command.name}',
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontSize: 13,
                    height: 1.25,
                    fontWeight: FontWeight.w500,
                    color: ds.text,
                  ),
                  children: [
                    if (hint != null && hint.isNotEmpty)
                      TextSpan(
                        text: '  $hint',
                        style: TextStyle(
                          fontFamily: monoFamily,
                          fontSize: 12,
                          fontWeight: FontWeight.w400,
                          color: ds.textMuted,
                        ),
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
      ),
    );
  }
}
