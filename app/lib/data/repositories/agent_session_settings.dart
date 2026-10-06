import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the new-agent-session form remembers between launches. Nothing
/// secret: a machine id, a route id and a folder path per machine.
@immutable
class AgentSessionMemory {
  const AgentSessionMemory({this.machineId, this.agents = const {}, this.folders = const {}});

  factory AgentSessionMemory.fromJson(Object? json) {
    if (json is! Map) return const AgentSessionMemory();
    Map<String, String> strings(Object? m) => {
          if (m is Map)
            for (final e in m.entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        };
    return AgentSessionMemory(
      machineId: json['machine'] is String ? json['machine'] as String : null,
      agents: strings(json['agents']),
      folders: strings(json['folders']),
    );
  }

  /// The machine used last.
  final String? machineId;

  /// Per machine id: the route id started last there.
  final Map<String, String> agents;

  /// Per machine id: the folder used last there.
  final Map<String, String> folders;

  Map<String, Object?> toJson() => {'machine': machineId, 'agents': agents, 'folders': folders};
}

/// Where [AgentSessionSettings] are kept between launches.
abstract interface class AgentSessionStore {
  Future<AgentSessionMemory> read();

  Future<void> write(AgentSessionMemory memory);
}

class PrefsAgentSessionStore implements AgentSessionStore {
  static const _key = 'agentSession.v1';

  @override
  Future<AgentSessionMemory> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const AgentSessionMemory();
    try {
      return AgentSessionMemory.fromJson(jsonDecode(raw));
    } on FormatException {
      return const AgentSessionMemory();
    }
  }

  @override
  Future<void> write(AgentSessionMemory memory) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(memory.toJson()));
  }
}

/// The machine, agent and folder the new-agent-session form starts from:
/// whatever was used last (agent and folder per machine).
class AgentSessionSettings extends ChangeNotifier {
  AgentSessionSettings(this._store);

  final AgentSessionStore _store;
  AgentSessionMemory _memory = const AgentSessionMemory();

  /// Reads what was saved. Anything unreadable starts empty.
  Future<void> load() async {
    try {
      _memory = await _store.read();
    } on Object {
      _memory = const AgentSessionMemory();
    }
    notifyListeners();
  }

  String? get lastMachineId => _memory.machineId;

  /// The route id started last on [machineId], or null.
  String? agentFor(String machineId) => _memory.agents[machineId];

  /// The folder used last on [machineId], or null.
  String? folderFor(String machineId) => _memory.folders[machineId];

  /// Records a started session.
  Future<void> remember({required String machineId, required String agent, required String folder}) {
    _memory = AgentSessionMemory(
      machineId: machineId,
      agents: {..._memory.agents, machineId: agent},
      folders: {..._memory.folders, machineId: folder},
    );
    notifyListeners();
    return _store.write(_memory).catchError((Object _) {});
  }
}
