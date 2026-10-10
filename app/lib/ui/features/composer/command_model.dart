import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../data/models/slash_command.dart';
import '../../../data/repositories/command_source.dart';
import '../../../data/repositories/slash_usage.dart';

/// The commands and skills the composer's first word can complete to: the one
/// model behind the pane's palette and the chat's.
///
/// With a [SlashUsage] the person's pins and sent commands rank the list, and
/// they are listed even for an agent whose [source] has none. A command is
/// remembered under its `usageKey`: `review` for `/review`, `$review` for
/// Codex's `$review`.
class CommandPaletteModel extends ChangeNotifier {
  CommandPaletteModel({required this.source, this._usage}) {
    source.addListener(notifyListeners);
    _usage?.addListener(notifyListeners);
  }

  final CommandSource source;
  final SlashUsage? _usage;

  /// How many recently sent commands follow the pinned ones on a bare `/`.
  static const recentShown = 5;

  /// A `/` or `$` at the start of the composer is the cue to learn the commands.
  void ensureLoaded() => source.ensureLoaded();

  /// Whether [command] is pinned for the current agent.
  bool isPinned(SlashCommand command) {
    final name = source.agent;
    return name != null && (_usage?.isPinned(name, command.usageKey) ?? false);
  }

  /// Pins [command] for the current agent, or unpins it.
  void togglePin(SlashCommand command) {
    final name = source.agent;
    if (name != null) unawaited(_usage?.togglePin(name, command.usageKey));
  }

  /// Notes the command a composer [line] starts with, once it was sent. A line
  /// that does not begin with `/name` or `$name` (a path, plain text) is not a
  /// command.
  void recordSent(String line) {
    final name = source.agent;
    final m = _sentCommand.firstMatch(line);
    if (name == null || m == null) return;
    unawaited(_usage?.record(name, m[1] == '/' ? m[2]! : '\$${m[2]}'));
  }

  static final _sentCommand = RegExp(r'^([/$])(\w[\w:.\-]{0,63})(?:\s|$)');

  static final _word = RegExp(r'^[/$]\S*$');

  /// Commands that [input] (the composer's whole text) is the start of.
  ///
  /// Empty unless [input] is a lone `/word` (or `$word`): once there is a space
  /// the command is chosen and the rest is its arguments. Only commands of the
  /// typed trigger count: `/` lists commands, `$` lists Codex's skills.
  ///
  /// A bare trigger lists the pinned commands, then the most recently sent,
  /// then the rest (project, user, then the agent's own).
  ///
  /// A word lists names that start with it first, then names that contain it,
  /// then descriptions that do; within a group the project, user, then
  /// built-in commands, and those sent more often first inside each of those.
  /// Names the person pinned or sent that the source lacks are candidates too.
  List<SlashCommand> match(String input) {
    final agentName = source.agent;
    if (!_word.hasMatch(input) || agentName == null) return const [];
    final trigger = input[0];
    final usage = _usage;
    final commands = [
      for (final c in source.commands)
        if (c.trigger == trigger) c,
    ];
    final known = {for (final c in commands) c.usageKey: c};
    // Remembered names the source does not know (an agent without a table, a
    // command it dropped) still complete.
    final extras = <SlashCommand>[
      if (usage != null)
        for (final key in {...usage.pinned(agentName), ...usage.used(agentName)})
          if (!known.containsKey(key) && _triggerOf(key) == trigger)
            SlashCommand(key.startsWith(r'$') ? key.substring(1) : key, '', SlashSource.builtIn, trigger: trigger),
    ];
    final query = input.substring(1).toLowerCase();
    if (query.isEmpty) return _bare(agentName, commands, known, extras);

    final starts = <SlashCommand>[];
    final inName = <SlashCommand>[];
    final inText = <SlashCommand>[];
    for (final c in [...commands, ...extras]) {
      final name = c.name.toLowerCase();
      if (name.startsWith(query)) {
        starts.add(c);
      } else if (name.contains(query)) {
        inName.add(c);
      } else if (c.description.toLowerCase().contains(query)) {
        inText.add(c);
      }
    }
    // A command typed in full and nothing else left to choose: nothing to show.
    if (starts.length == 1 && starts.single.name.toLowerCase() == query && inName.isEmpty) {
      return const [];
    }
    int uses(SlashCommand c) => usage?.count(agentName, c.usageKey) ?? 0;
    return [
      ..._ordered(starts, uses),
      ..._ordered(inName, uses),
      ..._ordered(inText, uses),
    ];
  }

  static String _triggerOf(String key) => key.startsWith(r'$') ? r'$' : '/';

  List<SlashCommand> _bare(
    String agentName,
    List<SlashCommand> commands,
    Map<String, SlashCommand> known,
    List<SlashCommand> extras,
  ) {
    final usage = _usage;
    final all = {...known, for (final c in extras) c.usageKey: c};
    final pinned = [
      for (final key in usage?.pinned(agentName) ?? const <String>[]) ?all[key],
    ];
    final shown = {for (final c in pinned) c.usageKey};
    final recent = [
      for (final key in usage?.recent(agentName, limit: recentShown, exclude: shown) ?? const <String>[]) ?all[key],
    ];
    shown.addAll(recent.map((c) => c.usageKey));
    return [
      ...pinned,
      ...recent,
      ..._ordered([
        for (final c in commands)
          if (!shown.contains(c.usageKey)) c,
      ]),
    ];
  }

  /// By source (project, user, built-in), then by [uses] (most first), keeping
  /// the source's order among equals.
  static List<SlashCommand> _ordered(List<SlashCommand> list, [int Function(SlashCommand)? uses]) {
    final indexed = list.indexed.toList()
      ..sort((a, b) {
        final bySource = a.$2.source.index - b.$2.source.index;
        if (bySource != 0) return bySource;
        final byUse = (uses?.call(b.$2) ?? 0) - (uses?.call(a.$2) ?? 0);
        return byUse != 0 ? byUse : a.$1 - b.$1;
      });
    return [for (final (_, c) in indexed) c];
  }

  @override
  void dispose() {
    source.removeListener(notifyListeners);
    _usage?.removeListener(notifyListeners);
    super.dispose();
  }
}

/// Puts the chosen command into the composer, ready for its arguments, and
/// keeps the keyboard up.
void fillCommand(TextEditingController input, FocusNode focus, SlashCommand command) {
  final text = '${command.text} ';
  input.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
  focus.requestFocus();
}
