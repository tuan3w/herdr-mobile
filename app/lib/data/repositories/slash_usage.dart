import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How often and when a slash command was last sent.
@immutable
class SlashUse {
  const SlashUse(this.count, this.lastUsed);

  final int count;
  final DateTime lastUsed;

  @override
  bool operator ==(Object other) =>
      other is SlashUse && other.count == count && other.lastUsed == lastUsed;

  @override
  int get hashCode => Object.hash(count, lastUsed);
}

/// What the palette remembers, per agent label (lower case): the commands the
/// person sent and the ones they pinned. Nothing secret: command names only.
@immutable
class SlashUsageMemory {
  const SlashUsageMemory({this.uses = const {}, this.pinned = const {}});

  /// Tolerant: anything that does not fit is dropped, never thrown on.
  factory SlashUsageMemory.fromJson(Object? json) {
    if (json is! Map) return const SlashUsageMemory();
    final uses = <String, Map<String, SlashUse>>{};
    final rawUses = json['uses'];
    if (rawUses is Map) {
      for (final MapEntry(key: agent, value: byName) in rawUses.entries) {
        if (agent is! String || byName is! Map) continue;
        final parsed = <String, SlashUse>{};
        for (final MapEntry(key: name, value: use) in byName.entries) {
          if (name is! String || use is! List || use.length != 2) continue;
          final [count, at] = use;
          if (count is! int || count < 1 || at is! int) continue;
          parsed[name] = SlashUse(count, DateTime.fromMillisecondsSinceEpoch(at));
        }
        if (parsed.isNotEmpty) uses[agent] = parsed;
      }
    }
    final pinned = <String, Set<String>>{};
    final rawPinned = json['pinned'];
    if (rawPinned is Map) {
      for (final MapEntry(key: agent, value: names) in rawPinned.entries) {
        if (agent is! String || names is! List) continue;
        final parsed = {for (final n in names) if (n is String) n};
        if (parsed.isNotEmpty) pinned[agent] = parsed;
      }
    }
    return SlashUsageMemory(uses: uses, pinned: pinned);
  }

  /// Per agent, per command name (no slash).
  final Map<String, Map<String, SlashUse>> uses;

  /// Per agent, in the order they were pinned.
  final Map<String, Set<String>> pinned;

  Map<String, Object?> toJson() => {
        'uses': {
          for (final MapEntry(key: agent, value: byName) in uses.entries)
            agent: {
              for (final MapEntry(key: name, value: use) in byName.entries)
                name: [use.count, use.lastUsed.millisecondsSinceEpoch],
            },
        },
        'pinned': {
          for (final MapEntry(key: agent, value: names) in pinned.entries) agent: names.toList(),
        },
      };
}

/// Where [SlashUsage] is kept between launches.
abstract interface class SlashUsageStore {
  Future<SlashUsageMemory> read();

  Future<void> write(SlashUsageMemory memory);
}

class PrefsSlashUsageStore implements SlashUsageStore {
  static const _key = 'slashUsage.v1';

  @override
  Future<SlashUsageMemory> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const SlashUsageMemory();
    try {
      return SlashUsageMemory.fromJson(jsonDecode(raw));
    } on FormatException {
      return const SlashUsageMemory();
    }
  }

  @override
  Future<void> write(SlashUsageMemory memory) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(memory.toJson()));
  }
}

/// The slash commands each agent was sent, and the ones pinned, kept on this
/// phone. Works for any agent label, with or without a built-in table: the
/// palette ranks what it knows by this and lists these names even when the
/// agent's table does not.
class SlashUsage extends ChangeNotifier {
  SlashUsage(this._store, {this._now = DateTime.now});

  /// Most commands remembered per agent.
  static const maxPerAgent = 40;

  /// The most recent commands are never pushed out by older, busier ones, or
  /// the palette's recents would forget what was just sent.
  static const keepRecent = 5;

  final SlashUsageStore _store;
  final DateTime Function() _now;
  SlashUsageMemory _memory = const SlashUsageMemory();

  /// Reads what was saved. Anything unreadable starts empty.
  Future<void> load() async {
    try {
      _memory = await _store.read();
    } on Object {
      _memory = const SlashUsageMemory();
    }
    notifyListeners();
  }

  /// How the memory names an agent: herdr's label, lower case, like the
  /// catalog.
  static String _agent(String label) => label.trim().toLowerCase();

  /// Pinned command names of [agent], in the order they were pinned.
  List<String> pinned(String agent) =>
      List.unmodifiable(_memory.pinned[_agent(agent)] ?? const <String>{});

  bool isPinned(String agent, String name) =>
      _memory.pinned[_agent(agent)]?.contains(name) ?? false;

  /// How many times [name] was sent to [agent].
  int count(String agent, String name) => _memory.uses[_agent(agent)]?[name]?.count ?? 0;

  /// Every command name remembered for [agent] (sent at least once), most
  /// recent first.
  List<String> used(String agent) {
    final uses = _memory.uses[_agent(agent)];
    if (uses == null) return const [];
    return _byRecency(uses);
  }

  /// Up to [limit] command names sent to [agent], newest first, without the
  /// ones in [exclude].
  List<String> recent(String agent, {int limit = 5, Set<String> exclude = const {}}) => [
        for (final name in used(agent))
          if (!exclude.contains(name)) name,
      ].take(limit).toList();

  /// Notes that [name] (no slash) was sent to [agent].
  Future<void> record(String agent, String name) {
    final key = _agent(agent);
    if (key.isEmpty || name.isEmpty) return Future.value();
    final byName = Map.of(_memory.uses[key] ?? const <String, SlashUse>{});
    byName[name] = SlashUse((byName[name]?.count ?? 0) + 1, _now());
    return _set(uses: {..._memory.uses, key: _prune(byName)});
  }

  /// Pins [name] for [agent], or unpins it when it was pinned.
  Future<void> togglePin(String agent, String name) {
    final key = _agent(agent);
    if (key.isEmpty || name.isEmpty) return Future.value();
    final names = {...?_memory.pinned[key]};
    if (!names.remove(name)) names.add(name);
    final pinned = {..._memory.pinned};
    if (names.isEmpty) {
      pinned.remove(key);
    } else {
      pinned[key] = names;
    }
    return _set(pinned: pinned);
  }

  Future<void> _set({
    Map<String, Map<String, SlashUse>>? uses,
    Map<String, Set<String>>? pinned,
  }) {
    _memory = SlashUsageMemory(
      uses: uses ?? _memory.uses,
      pinned: pinned ?? _memory.pinned,
    );
    notifyListeners();
    return _store.write(_memory).catchError((Object _) {});
  }

  static List<String> _byRecency(Map<String, SlashUse> uses) {
    final names = uses.keys.toList()
      ..sort((a, b) {
        final byTime = uses[b]!.lastUsed.compareTo(uses[a]!.lastUsed);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    return names;
  }

  /// Keeps the [keepRecent] newest, then the busiest of the rest (ties:
  /// newest first), up to [maxPerAgent].
  static Map<String, SlashUse> _prune(Map<String, SlashUse> uses) {
    if (uses.length <= maxPerAgent) return uses;
    final newest = _byRecency(uses);
    final kept = newest.take(keepRecent).toList();
    final rest = newest.skip(keepRecent).toList()
      ..sort((a, b) {
        final byCount = uses[b]!.count.compareTo(uses[a]!.count);
        if (byCount != 0) return byCount;
        final byTime = uses[b]!.lastUsed.compareTo(uses[a]!.lastUsed);
        return byTime != 0 ? byTime : a.compareTo(b);
      });
    kept.addAll(rest.take(maxPerAgent - keepRecent));
    return {for (final name in kept) name: uses[name]!};
  }
}
