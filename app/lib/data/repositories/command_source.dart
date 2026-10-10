import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/slash_command.dart';
import 'agent_session.dart';
import 'slash_catalog.dart';

/// Where a composer's command and skill palette gets its list: an agent in a
/// pane reads it from the machine's files ([CatalogCommandSource]), a chat from
/// its session ([SessionCommandSource]). The palette itself is the same for
/// both.
abstract interface class CommandSource implements Listenable {
  /// The agent's lower-case label: the key of the pins and of the usage.
  String? get agent;

  /// What the agent accepts at the start of a prompt. The same list instance
  /// until it changes.
  List<SlashCommand> get commands;

  /// Starts loading when what is known is missing or stale. Never throws.
  void ensureLoaded();
}

/// A session that knows more commands than the agent advertised (an agent in a
/// terminal: what its machine's files and its log tell).
abstract interface class SessionCommands {
  /// Commands and skills; the same list instance until it changes.
  List<SlashCommand> get slashCommands;

  /// A person began a command: the list is read (again) now if it is missing or
  /// older than a couple of minutes.
  void wantCommands();
}

/// An agent in a pane: what [SlashCatalog.load] finds, read the first time a
/// command is started (not when the pane opens: most panes never need it) and
/// again when it is older than [maxAge], so a command file added on the
/// machine shows up.
class CatalogCommandSource extends ChangeNotifier implements CommandSource {
  CatalogCommandSource({
    required this._agent,
    required this._cwd,
    required this._catalog,
    this.maxAge = const Duration(minutes: 2),
    this._now = DateTime.now,
  });

  /// The agent's herdr label and working folder, read when a load starts: a
  /// pane can change agent while it is open.
  final String? Function() _agent;
  final String? Function() _cwd;
  final SlashCatalog _catalog;
  final Duration maxAge;
  final DateTime Function() _now;

  List<SlashCommand> _commands = const [];
  DateTime? _loadedAt;
  bool _loading = false;
  String? _loadedFor;
  bool _disposed = false;

  @override
  String? get agent => _agent()?.toLowerCase();

  @override
  List<SlashCommand> get commands => _commands;

  @override
  void ensureLoaded() {
    final name = agent;
    if (name == null || _loading) return;
    final at = _loadedAt;
    if (at != null && _loadedFor == name && _now().difference(at) < maxAge) return;
    unawaited(_load(name));
  }

  Future<void> _load(String name) async {
    _loading = true;
    try {
      final found = await _catalog.load(agent: name, cwd: _cwd());
      if (_disposed) return;
      _commands = found;
      _loadedAt = _now();
      _loadedFor = name;
      notifyListeners();
    } finally {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// A chat session: its [SessionCommands] when it has them, else the commands
/// the agent advertised (`state.commands`). Listens to the session and
/// notifies only when the list instance changed, so a streaming answer
/// rebuilds no palette.
class SessionCommandSource extends ChangeNotifier implements CommandSource {
  SessionCommandSource(this._session) {
    _session.addListener(_onSession);
    _commands = _read();
  }

  final AgentSessionView _session;
  late List<SlashCommand> _commands;

  // What the advertised list was mapped from, so it is mapped once.
  Object? _mappedFrom;

  @override
  String? get agent => _session.agent.toLowerCase();

  @override
  List<SlashCommand> get commands => _commands;

  @override
  void ensureLoaded() {
    if (_session case final SessionCommands s) s.wantCommands();
  }

  List<SlashCommand> _read() {
    if (_session case final SessionCommands s) return s.slashCommands;
    final advertised = _session.state.commands;
    if (identical(advertised, _mappedFrom)) return _commands;
    _mappedFrom = advertised;
    return [
      for (final c in advertised) SlashCommand(c.name, c.description, SlashSource.builtIn, hint: c.inputHint),
    ];
  }

  void _onSession() {
    final next = _read();
    if (identical(next, _commands)) return;
    _commands = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    super.dispose();
  }
}
