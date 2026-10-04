import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/models/slash_command.dart';
import '../../../data/repositories/slash_catalog.dart';

/// The commands the composer's first word can complete to.
///
/// Loads the catalog the first time a slash is typed (not when the pane opens:
/// most panes never need it) and again when the list is older than
/// [maxAge], so a command file added on the machine shows up.
class SlashViewModel extends ChangeNotifier {
  SlashViewModel({
    required this.agent,
    required this.cwd,
    required this._catalog,
    this.maxAge = const Duration(minutes: 2),
    this._now = DateTime.now,
  });

  /// The agent's herdr label and working folder, read when a load starts: a
  /// pane can change agent while it is open.
  final String? Function() agent;
  final String? Function() cwd;
  final Duration maxAge;

  final SlashCatalog _catalog;
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

  /// Commands that [input] (the composer's whole text) is the start of.
  ///
  /// Empty unless [input] is a lone `/word`: once there is a space the command
  /// is chosen and the rest is its arguments. Names that start with the word
  /// come first, then names that contain it, then descriptions that do; each
  /// group lists project, user, then built-in commands.
  List<SlashCommand> match(String input) {
    if (!_word.hasMatch(input) || agent() == null) return const [];
    final query = input.substring(1).toLowerCase();
    if (query.isEmpty) return _ordered(_commands);
    final starts = <SlashCommand>[];
    final inName = <SlashCommand>[];
    final inText = <SlashCommand>[];
    for (final c in _commands) {
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
    return [..._ordered(starts), ..._ordered(inName), ..._ordered(inText)];
  }

  static final _word = RegExp(r'^/\S*$');

  /// Stable by source, keeping the catalog's order within one.
  static List<SlashCommand> _ordered(List<SlashCommand> list) => [
        for (final s in SlashSource.values) ...list.where((c) => c.source == s),
      ];

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
