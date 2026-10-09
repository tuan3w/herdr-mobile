import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart' show AgentStatus;
import '../models/pane_name.dart';
import '../models/remote_file.dart';
import '../observed/omp_session_name.dart';
import '../observed/session_log_locator.dart' show isReadableLogPath;
import '../services/herdr_transport.dart' show HerdrTransportException;
import 'fleet_agent.dart' show FleetAgent;
import 'machine_connection.dart';

/// The head and the tail of a session log, as read from the host, and when the
/// file was last written (null when the host does not say). Empty slices when
/// the text was not asked for.
typedef SessionSlices = ({Uint8List head, Uint8List tail, bool tailStartsMidLine, DateTime? modified});

/// Reads [path] on [machine]'s host: its modification time always, its text
/// only when [text] (a pane that needs a name).
typedef SessionReader = Future<SessionSlices> Function(MachineConnection machine, String path, {required bool text});

/// What the session log of an omp agent tells the board, for panes herdr says
/// write one (`FleetAgent.sessionLogPath`):
///
///  * **A name**, for a pane whose terminal title says nothing (omp titles its
///    terminal `π > <folder>` until it has a title for the session): the
///    session's title, else the last thing the person said.
///  * **When it was last active**, for an idle pane: the file's modification
///    time, the moment its last turn ended. herdr gives no status timestamps, so
///    an agent that was already idle when the app first looked has no time of its
///    own, and the Idle section could not be put in order.
///
/// How it reads:
///
///  * **Only where needed.** A pane whose title already names its work and that
///    is not idle is never read; one the person named (herdr's label) is not
///    read for a name. An idle pane with a good title costs one `stat`.
///  * **Only what herdr names.** The log is the one the pane reports; a pane that
///    reports none, as when herdr's omp integration is not installed on the host,
///    is not guessed at from its folder, since several agents share one.
///  * **Read over SFTP**, never through a shell, so the path is not a command.
///    It is still checked: absolute, a `.jsonl`, nothing odd in it.
///  * **Cheap and bounded.** A `stat`, and for a name two slices of the file (16
///    KB at the head, 64 KB at the tail), not the log. Once when a pane first
///    needs it and once more each time its status changes (a turn that ends is
///    when a title, a last message and a new time appear), at most
///    [maxConcurrent] at once, none while the app is in the background or the
///    machine is down. A failed read is tried again after [retryAfter]. Nothing
///    is polled.
///  * **Quiet.** Listeners hear only when a name or a time really changed.
///
/// Everything lives in memory: after a restart the board shows the terminal
/// titles, and the order it can observe, until the reads land.
class PaneSessionNames extends ChangeNotifier {
  PaneSessionNames({
    required this._agents,
    required this._canRead,
    SessionReader? reader,
    this.maxConcurrent = 2,
    this.retryAfter = const Duration(minutes: 5),
    this._clock = DateTime.now,
  }) : _reader = reader ?? readSessionSlices;

  /// Bytes read from the start and the end of a log.
  static const headBytes = 16 * 1024;
  static const tailBytes = 64 * 1024;

  final Iterable<FleetAgent> Function() _agents;
  final bool Function() _canRead;
  final SessionReader _reader;
  final DateTime Function() _clock;

  /// Reads in flight at once, over all machines.
  final int maxConcurrent;

  /// A failed read is not repeated before this.
  final Duration retryAfter;

  final Map<String, _Entry> _entries = {};
  final Map<String, _Job> _wanted = {};
  final List<String> _queue = [];
  final Set<String> _running = {};
  bool _disposed = false;

  static String _key(String machineId, String paneId) => '$machineId/$paneId';

  /// The name read for [paneId], or null when there is none (or it was read
  /// from another log than [path]).
  PaneName? nameFor(String machineId, String paneId, String? path) {
    final e = _entries[_key(machineId, paneId)];
    return e != null && e.path == path ? e.name : null;
  }

  /// When [paneId]'s session file was last written (read for an idle pane), or
  /// null when that is not known (or it was read from another log than [path]).
  DateTime? lastActiveFor(String machineId, String paneId, String? path) {
    final e = _entries[_key(machineId, paneId)];
    return e != null && e.path == path ? e.modified : null;
  }

  /// Looks at the fleet: queues a read for every pane that needs one and forgets
  /// the panes that are gone. Cheap; call it whenever the fleet changed.
  void sync() {
    if (_disposed) return;
    final seen = <String>{};
    for (final a in _agents()) {
      final key = _key(a.machine.profile.id, a.pane.id);
      seen.add(key);
      final path = a.sessionLogPath;
      if (!_wants(a, path)) {
        _wanted.remove(key);
        continue;
      }
      final entry = _entries[key];
      final fresh = entry != null &&
          entry.path == path &&
          entry.status == a.pane.status &&
          (!entry.failed || _clock().difference(entry.at) < retryAfter);
      if (fresh || _running.contains(key)) continue;
      _wanted[key] = _Job(a.machine, a.pane.id, path!, a.pane.status, a);
      if (!_queue.contains(key)) _queue.add(key);
    }
    _entries.removeWhere((k, _) => !seen.contains(k));
    _wanted.removeWhere((k, _) => !seen.contains(k));
    _queue.removeWhere((k) => !_wanted.containsKey(k));
    _pump();
  }

  static bool _wants(FleetAgent a, String? path) =>
      path != null &&
      a.agentKind == 'omp' &&
      a.machine.isLive &&
      (a.hasGenericTitle || a.pane.status == AgentStatus.idle) &&
      isReadableLogPath(path);

  void _pump() {
    while (!_disposed && _running.length < maxConcurrent && _queue.isNotEmpty && _canRead()) {
      final key = _queue.removeAt(0);
      final job = _wanted[key];
      if (job == null) continue;
      _running.add(key);
      unawaited(_load(key, job));
    }
  }

  Future<void> _load(String key, _Job job) async {
    PaneName? name;
    DateTime? modified;
    var failed = false;
    try {
      final needsName = job.agent.hasGenericTitle;
      final s = await _reader(job.machine, job.path, text: needsName);
      modified = s.modified;
      if (needsName) {
        final parsed = parseOmpSessionName(
          head: utf8.decode(s.head, allowMalformed: true),
          tail: utf8.decode(s.tail, allowMalformed: true),
          tailStartsMidLine: s.tailStartsMidLine,
        );
        final title = parsed.title;
        if (title != null && !job.agent.isGenericTitle(title)) {
          name = PaneName.title(title);
        } else if (parsed.lastPrompt != null) {
          name = PaneName.prompt(parsed.lastPrompt!);
        }
      }
    } on RemoteFileException {
      failed = true;
    } on HerdrTransportException {
      failed = true;
    }
    _running.remove(key);
    if (_disposed) return;
    final before = _entries[key];
    _entries[key] = _Entry(job.path, job.status, name, modified, failed, _clock());
    _wanted.remove(key);
    if (before?.name != name || before?.modified != modified) notifyListeners();
    sync(); // the pane may have changed again meanwhile; also starts the next read
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _Entry {
  const _Entry(this.path, this.status, this.name, this.modified, this.failed, this.at);

  final String path;
  final AgentStatus status;
  final PaneName? name;
  final DateTime? modified;
  final bool failed;
  final DateTime at;
}

class _Job {
  const _Job(this.machine, this.paneId, this.path, this.status, this.agent);

  final MachineConnection machine;
  final String paneId;
  final String path;
  final AgentStatus status;
  final FleetAgent agent;
}

/// The default [SessionReader]: SFTP over the machine's connection.
Future<SessionSlices> readSessionSlices(MachineConnection machine, String path, {required bool text}) async {
  final files = machine.files;
  final stat = await files.stat(path);
  final modified = stat.modified;
  final size = stat.size ?? 0;
  final none = Uint8List(0);
  if (!text || size <= 0) return (head: none, tail: none, tailStartsMidLine: false, modified: modified);
  final head = await files.read(path, length: math.min(size, PaneSessionNames.headBytes));
  final tailStart = math.max(0, size - PaneSessionNames.tailBytes);
  final tail = tailStart == 0 && size <= PaneSessionNames.headBytes
      ? head
      : await files.read(path, offset: tailStart, length: size - tailStart);
  return (head: head, tail: tail, tailStartsMidLine: tailStart > 0, modified: modified);
}
