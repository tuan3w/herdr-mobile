import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the new-session form remembers between launches. Nothing secret: a
/// machine id, agent kind names and the command lines the person typed.
@immutable
class NewSessionMemory {
  const NewSessionMemory({
    this.machineId,
    this.kinds = const {},
    this.commands = const {},
  });

  factory NewSessionMemory.fromJson(Object? json) {
    if (json is! Map) return const NewSessionMemory();
    Map<String, String> strings(Object? m) => {
          if (m is Map)
            for (final e in m.entries)
              if (e.key is String && e.value is String) e.key as String: e.value as String,
        };
    final commands = <String, String>{};
    if (json['commands'] case final Map byMachine) {
      for (final machine in byMachine.entries) {
        for (final kind in strings(machine.value).entries) {
          commands[commandKey('${machine.key}', kind.key)] = kind.value;
        }
      }
    }
    return NewSessionMemory(
      machineId: json['machine'] is String ? json['machine'] as String : null,
      kinds: strings(json['kinds']),
      commands: commands,
    );
  }

  /// The machine used last.
  final String? machineId;

  /// Per machine id: the agent kind launched last (empty = a plain shell).
  final Map<String, String> kinds;

  /// Edited launch commands, by [commandKey].
  final Map<String, String> commands;

  static String commandKey(String machineId, String kind) => '$machineId\n$kind';

  Map<String, Object?> toJson() {
    final byMachine = <String, Map<String, String>>{};
    for (final e in commands.entries) {
      final at = e.key.indexOf('\n');
      byMachine.putIfAbsent(e.key.substring(0, at), () => {})[e.key.substring(at + 1)] = e.value;
    }
    return {'machine': machineId, 'kinds': kinds, 'commands': byMachine};
  }
}

/// Where [NewSessionSettings] are kept between launches.
abstract interface class NewSessionStore {
  Future<NewSessionMemory> read();

  Future<void> write(NewSessionMemory memory);
}

class PrefsNewSessionStore implements NewSessionStore {
  static const _key = 'newSession.v1';

  @override
  Future<NewSessionMemory> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const NewSessionMemory();
    try {
      return NewSessionMemory.fromJson(jsonDecode(raw));
    } on FormatException {
      return const NewSessionMemory();
    }
  }

  @override
  Future<void> write(NewSessionMemory memory) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(memory.toJson()));
  }
}

/// The machine, agent and command the new-session form starts from: whatever
/// was used last, per machine.
class NewSessionSettings extends ChangeNotifier {
  NewSessionSettings(this._store);

  final NewSessionStore _store;
  NewSessionMemory _memory = const NewSessionMemory();

  /// Reads what was saved. Anything unreadable starts empty.
  Future<void> load() async {
    try {
      _memory = await _store.read();
    } on Object {
      _memory = const NewSessionMemory();
    }
    notifyListeners();
  }

  String? get lastMachineId => _memory.machineId;

  /// The kind launched last on [machineId]: null when never launched there,
  /// empty for a plain shell.
  String? kindFor(String machineId) => _memory.kinds[machineId];

  /// The edited command for [kind] on [machineId], if the person changed it.
  String? commandFor(String machineId, String kind) =>
      _memory.commands[NewSessionMemory.commandKey(machineId, kind)];

  /// Records a launch. [kind] is empty for a plain shell. A [command] equal to
  /// the default (the kind's own name) is not stored, so the default can
  /// change without a stale override.
  Future<void> remember({
    required String machineId,
    required String kind,
    String? command,
  }) {
    final commands = Map.of(_memory.commands);
    if (kind.isNotEmpty) {
      final key = NewSessionMemory.commandKey(machineId, kind);
      if (command == null || command.isEmpty || command == kind) {
        commands.remove(key);
      } else {
        commands[key] = command;
      }
    }
    _memory = NewSessionMemory(
      machineId: machineId,
      kinds: {..._memory.kinds, machineId: kind},
      commands: commands,
    );
    notifyListeners();
    return _store.write(_memory).catchError((Object _) {});
  }
}
