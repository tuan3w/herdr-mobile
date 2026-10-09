import '../models/herdr_models.dart';
import '../models/remote_file.dart';
import '../repositories/fleet_agent.dart';
import '../repositories/machine_connection.dart';
import '../services/remote_files.dart';
import 'session_log_locator.dart';

/// Finds the log of a Codex pane.
///
/// Codex writes `~/.codex/sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl`
/// when the first prompt is sent; the date folder and the name's stamp are the
/// HOST's local time at creation, and `<id>` is a UUIDv7 whose first 48 bits are
/// the creation time in milliseconds UTC. herdr's hook reports the thread id
/// only (not the path), and only once its integration is installed and the
/// session started or resumed after that. Without a session reference the pane
/// cannot be linked: Codex keeps no map from a process to its thread.
class CodexLocator implements SessionLogLocator {
  CodexLocator();

  /// Shown verbatim.
  static const unlinkedWhy =
      'herdr does not know which session this Codex runs. Install herdr\'s hook (the terminal\'s ⋯ menu has '
      '"Read as chat…", or run "herdr integration install codex" on the machine; Codex asks you to trust it), then run "codex resume".';

  static const compressedWhy =
      'Codex compressed this session after a week idle. Resume it in Codex to read it here.';

  static const notYetWhy = 'Codex has not written this session yet.';

  static final _uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  /// The most directory listings made looking for a session by walking the
  /// date folders newest first.
  static const maxLists = 40;

  /// id -> path, per machine: a session's file never moves.
  final _found = <String, String>{};

  @override
  bool mayLocate(Pane pane) => pane.session != null && FleetAgent.kindOf(pane) == 'codex';

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) =>
      locateWith(machine.files, pane, machineId: machine.profile.id);

  Future<LogLocation> locateWith(RemoteFiles files, Pane pane, {String machineId = ''}) async {
    final session = pane.session;
    if (session == null) return const Unlinked(unlinkedWhy);
    if (session.kind == 'path' && isReadableLogPath(session.value)) return Located(session.value);
    if (session.kind == 'id') return locateById(files, session.value, machineId: machineId);
    return const Unlinked(unlinkedWhy);
  }

  /// The log of thread [id] (a main session's or a subagent's).
  Future<LogLocation> locateById(RemoteFiles files, String id, {String machineId = ''}) async {
    if (!_uuid.hasMatch(id)) return const NotYet(notYetWhy);
    final cached = _found['$machineId/$id'];
    if (cached != null) return Located(cached);
    final home = await files.home();
    final root = '$home/.codex/sessions';
    var compressed = false;

    Future<String?> inDay(String dir) async {
      final entries = await _list(files, dir);
      if (entries == null) return null;
      for (final e in entries) {
        if (!e.name.startsWith('rollout-')) continue;
        if (e.name.endsWith('-$id.jsonl')) return '$dir/${e.name}';
        if (e.name.endsWith('-$id.jsonl.zst')) compressed = true;
      }
      return null;
    }

    String? path;
    if (id[14] == '7') {
      final ms = int.parse(id.replaceAll('-', '').substring(0, 12), radix: 16);
      final made = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
      for (final shift in const [-1, 0, 1]) {
        final d = made.add(Duration(days: shift));
        path = await inDay('$root/${_pad(d.year, 4)}/${_pad(d.month)}/${_pad(d.day)}');
        if (path != null) break;
      }
    }
    // A v7 id says its day; only an id that does not is looked for by walking.
    if (id[14] != '7') path ??= await _walk(files, root, inDay);
    if (path != null && isReadableLogPath(path)) {
      _found['$machineId/$id'] = path;
      return Located(path);
    }
    return compressed ? const Unlinked(compressedWhy) : const NotYet(notYetWhy);
  }

  /// Date folders newest first, at most [maxLists] listings in all.
  Future<String?> _walk(RemoteFiles files, String root, Future<String?> Function(String dir) inDay) async {
    var lists = 1;
    final years = await _numbered(files, root);
    for (final y in years) {
      if (lists >= maxLists) return null;
      lists++;
      final months = await _numbered(files, '$root/$y');
      for (final m in months) {
        if (lists >= maxLists) return null;
        lists++;
        final days = await _numbered(files, '$root/$y/$m');
        for (final d in days) {
          if (lists >= maxLists) return null;
          lists++;
          final found = await inDay('$root/$y/$m/$d');
          if (found != null) return found;
        }
      }
    }
    return null;
  }

  /// The all-digit folder names of [dir], biggest first.
  Future<List<String>> _numbered(RemoteFiles files, String dir) async {
    final entries = await _list(files, dir);
    final names = [
      for (final e in entries ?? const <RemoteEntry>[])
        if (e.isDirectory && RegExp(r'^\d{1,4}$').hasMatch(e.name)) e.name,
    ]..sort((a, b) => b.compareTo(a));
    return names;
  }

  Future<List<RemoteEntry>?> _list(RemoteFiles files, String dir) async {
    try {
      return await files.list(dir);
    } on RemoteFileException catch (e) {
      return switch (e.kind) {
        RemoteFileErrorKind.notFound ||
        RemoteFileErrorKind.permission ||
        RemoteFileErrorKind.notADirectory => null,
        _ => throw e,
      };
    }
  }

  static String _pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
}
