import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/slash_command.dart';
import '../../../data/repositories/slash_catalog.dart';
import '../../../data/repositories/slash_usage.dart';

/// The commands the composer's first word can complete to.
///
/// Loads the catalog the first time a slash is typed (not when the pane opens:
/// most panes never need it) and again when the list is older than
/// [maxAge], so a command file added on the machine shows up.
///
/// With a [SlashUsage] the person's pins and sent commands rank the list, and
/// they are listed even for an agent whose catalog is empty.
class SlashViewModel extends ChangeNotifier {
  SlashViewModel({
    required this.agent,
    required this.cwd,
    required this._catalog,
    this._usage,
    this.maxAge = const Duration(minutes: 2),
    this._now = DateTime.now,
  }) {
    _usage?.addListener(notifyListeners);
  }

  /// The agent's herdr label and working folder, read when a load starts: a
  /// pane can change agent while it is open.
  final String? Function() agent;
  final String? Function() cwd;
  final Duration maxAge;

  final SlashCatalog _catalog;
  final SlashUsage? _usage;
  final DateTime Function() _now;

  List<SlashCommand> _commands = const [];
  DateTime? _loadedAt;
  bool _loading = false;
  String? _loadedFor;
  bool _disposed = false;

  List<SlashCommand> get commands => _commands;

  /// Starts a load unless a fresh one is there or under way.
  void ensureLoaded() {
    final name = agent();
    if (name == null || _loading) return;
    final at = _loadedAt;
    if (at != null && _loadedFor == name && _now().difference(at) < maxAge) return;
    unawaited(_load(name));
  }

  Future<void> _load(String name) async {
    _loading = true;
    try {
      final found = await _catalog.load(agent: name, cwd: cwd());
      if (_disposed) return;
      _commands = found;
      _loadedAt = _now();
      _loadedFor = name;
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  /// How many recently sent commands follow the pinned ones on a bare `/`.
  static const recentShown = 5;

  /// Whether [command] is pinned for the current agent.
  bool isPinned(SlashCommand command) {
    final name = agent();
    return name != null && (_usage?.isPinned(name, command.name) ?? false);
  }

  /// Pins [command] for the current agent, or unpins it.
  void togglePin(SlashCommand command) {
    final name = agent();
    if (name != null) unawaited(_usage?.togglePin(name, command.name));
  }

  /// Notes the command a composer [line] starts with, once it was sent. A line
  /// that does not begin with `/name` (a path, plain text) is not a command.
  void recordSent(String line) {
    final name = agent();
    final command = _sentCommand.firstMatch(line)?[1];
    if (name != null && command != null) unawaited(_usage?.record(name, command));
  }

  static final _sentCommand = RegExp(r'^/(\w[\w:.\-]{0,63})(?:\s|$)');

  /// Commands that [input] (the composer's whole text) is the start of.
  ///
  /// Empty unless [input] is a lone `/word`: once there is a space the command
  /// is chosen and the rest is its arguments.
  ///
  /// A bare `/` lists the pinned commands, then the most recently sent, then
  /// the rest of the catalog (project, user, then built-in commands).
  ///
  /// A word lists names that start with it first, then names that contain it,
  /// then descriptions that do; within a group the project, user, then
  /// built-in commands, and those sent more often first inside each of those.
  /// Names the person pinned or sent that the catalog lacks are candidates too.
  List<SlashCommand> match(String input) {
    final agentName = agent();
    if (!_word.hasMatch(input) || agentName == null) return const [];
    final usage = _usage;
    final known = {for (final c in _commands) c.name: c};
    // Remembered names the catalog does not know (an agent without a table, a
    // command it dropped) still complete.
    final extras = <SlashCommand>[
      if (usage != null)
        for (final name in {...usage.pinned(agentName), ...usage.used(agentName)})
          if (!known.containsKey(name)) SlashCommand(name, '', SlashSource.builtIn),
    ];
    final query = input.substring(1).toLowerCase();
    if (query.isEmpty) return _bare(agentName, known, extras);

    final pool = [..._commands, ...extras];
    final starts = <SlashCommand>[];
    final inName = <SlashCommand>[];
    final inText = <SlashCommand>[];
    for (final c in pool) {
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
    int uses(SlashCommand c) => usage?.count(agentName, c.name) ?? 0;
    return [
      ..._ordered(starts, uses),
      ..._ordered(inName, uses),
      ..._ordered(inText, uses),
    ];
  }

  List<SlashCommand> _bare(
    String agentName,
    Map<String, SlashCommand> known,
    List<SlashCommand> extras,
  ) {
    final usage = _usage;
    final all = {...known, for (final c in extras) c.name: c};
    final pinned = [
      for (final name in usage?.pinned(agentName) ?? const <String>[]) ?all[name],
    ];
    final shown = {for (final c in pinned) c.name};
    final recent = [
      for (final name
          in usage?.recent(agentName, limit: recentShown, exclude: shown) ?? const <String>[])
        ?all[name],
    ];
    shown.addAll(recent.map((c) => c.name));
    return [
      ...pinned,
      ...recent,
      ..._ordered([
        for (final c in _commands)
          if (!shown.contains(c.name)) c,
      ]),
    ];
  }

  static final _word = RegExp(r'^/\S*$');

  /// By source (project, user, built-in), then by [uses] (most first), keeping
  /// the catalog's order among equals.
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
    _disposed = true;
    _usage?.removeListener(notifyListeners);
    super.dispose();
  }
}
