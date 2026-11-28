import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'machine_connection.dart';

// Where a phone file lands on the host (`<home>/.herdr-mobile/inbox/<12 hex of
// sha1(session key)>/<UTC time>-<safe name>`, folders 0700, files 0600), how its
// name is made safe and unique, and which old files go, is decided by the
// agent helper's `transfer` service (`RemoteFiles.reserveInboxFile`,
// `sweepInbox`): one rule on the host, tested there, never a copy here. This
// file only decides WHEN the phone asks for a sweep.

/// When the last inbox sweep of each machine ran.
abstract interface class InboxCleanupLog {
  Future<DateTime?> lastRun(String machineId);
  Future<void> record(String machineId, DateTime at);
}

class PrefsInboxCleanupLog implements InboxCleanupLog {
  static String _key(String machineId) => 'inboxCleanup.v1.$machineId';

  @override
  Future<DateTime?> lastRun(String machineId) async {
    final ms = (await SharedPreferences.getInstance()).getInt(_key(machineId));
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  @override
  Future<void> record(String machineId, DateTime at) async {
    await (await SharedPreferences.getInstance()).setInt(_key(machineId), at.millisecondsSinceEpoch);
  }
}

/// Sweeps the inbox of each machine once per [every] (24 h), in the background,
/// the first time the machine is online in a run of the app.
class InboxJanitor {
  InboxJanitor(
    this._log, {
    this.every = const Duration(hours: 24),
    this.startDelay = const Duration(seconds: 20),
    this._now = DateTime.now,
  });

  final InboxCleanupLog _log;
  final Duration every;

  /// Wait after the machine comes online, so the sweep does not compete with
  /// the first screens for the machine's link.
  final Duration startDelay;
  final DateTime Function() _now;
  final _seen = <String>{};

  /// Runs the sweep for [machine] when it first goes online.
  void watch(MachineConnection machine) {
    void check() {
      if (machine.state != LinkState.online || !_seen.add(machine.profile.id)) return;
      machine.removeListener(check);
      Timer(startDelay, () => unawaited(run(machine)));
    }

    machine.addListener(check);
    check();
  }

  /// The sweep itself, unless one ran within [every]. Returns the number of
  /// files deleted, or null when skipped or when the machine could not do it
  /// (no agent helper: nothing was ever uploaded there either).
  Future<int?> run(MachineConnection machine) async {
    final id = machine.profile.id;
    try {
      final last = await _log.lastRun(id);
      if (last != null && _now().difference(last) < every) return null;
      if (!machine.files.supported) return null;
      final deleted = await machine.files.sweepInbox();
      await _log.record(id, _now());
      return deleted;
    } on Object {
      return null; // best effort; tried again next launch
    }
  }
}
