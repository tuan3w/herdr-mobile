import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_file.dart';
import '../services/remote_files.dart';
import 'machine_connection.dart';

/// Where a phone file lands on the host:
/// `<home>/.herdr-mobile/inbox/<12 hex of sha1(session key)>/<yyyyMMdd-HHmmss>-<safe name>`. Outside every
/// repository, owner-only (folders 0700, files 0600). The agent is handed this
/// path as a `resource_link`, so it can read it (and so can anything running as
/// the same user): nothing secret should be sent this way.
///
/// The target is derived ONLY from the fixed base and [inboxSafeName], never
/// from a path the phone or the agent supplied, so a hostile file name cannot
/// leave the inbox.
const inboxFolder = '.herdr-mobile/inbox';

/// Files in the inbox older than this are deleted by [HostInbox.cleanup].
const inboxMaxAge = Duration(days: 14);

/// The most files one cleanup deletes.
const inboxCleanupCap = 200;

/// How many characters (code points) and bytes a safe name may have; file
/// systems allow 255 bytes, and the date prefix and a `-99` suffix need room.
const _maxNameChars = 100;
const _maxNameBytes = 200;

/// Reserves the absolute path on [machine] where the phone file [fileName] for
/// the session [sessionKey] is to be uploaded, creating the folders (0700) as
/// needed. The name is made safe and unique: see [inboxSafeName]. Throws
/// [RemoteFileException] (unsupported, permission, network).
Future<String> reserveInboxPath(
  MachineConnection machine, {
  required String sessionKey,
  required String fileName,
}) => HostInbox.of(machine.files).reserve(sessionKey: sessionKey, fileName: fileName);

/// A file name that is safe to create on the host: the last path segment of
/// [raw] with every character that is not a letter (any script, Vietnamese
/// included), a digit, `.`, `-` or `_` replaced by `_`, leading dots removed
/// (never a dotfile), at most 100 characters and 200 bytes with the extension
/// kept, and never empty.
String inboxSafeName(String raw) {
  final segments = raw.split(RegExp(r'[\\/]')).where((s) => s.trim().isNotEmpty);
  var name = segments.isEmpty ? '' : segments.last.trim();
  name = name.replaceAll(_unsafe, '_').replaceFirst(RegExp(r'^\.+'), '');
  final dot = name.lastIndexOf('.');
  var stem = name;
  var ext = '';
  if (dot > 0 && dot < name.length - 1 && name.length - dot <= 13) {
    stem = name.substring(0, dot);
    ext = name.substring(dot);
  }
  if (!_hasLetterOrDigit.hasMatch(stem)) stem = 'file';
  final room = _maxNameChars - ext.runes.length;
  final bytes = _maxNameBytes - utf8.encode(ext).length;
  final kept = StringBuffer();
  var chars = 0;
  var used = 0;
  for (final rune in stem.runes) {
    final piece = String.fromCharCode(rune);
    final size = utf8.encode(piece).length;
    if (chars + 1 > room || used + size > bytes) break;
    kept.write(piece);
    chars++;
    used += size;
  }
  return '$kept$ext';
}

final _unsafe = RegExp(r'[^\p{L}\p{M}\p{N}.\-_]', unicode: true);
final _hasLetterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// The inbox of one machine: reserves upload paths and sweeps old files.
/// One per [RemoteFiles] (see [of]); its memory of what exists lasts as long
/// as the machine's connection object.
class HostInbox {
  HostInbox(this._files, {this._now = DateTime.now});

  static final _instances = Expando<HostInbox>('HostInbox');

  static HostInbox of(RemoteFiles files) => _instances[files] ??= HostInbox(files);

  final RemoteFiles _files;
  final DateTime Function() _now;

  /// Session folders created or seen in this run: no second `makeDirs`.
  final _known = <String>{};

  /// Names handed out in this run, so two files reserved in the same second
  /// cannot pick the same one before either exists on the host.
  final _taken = <String>{};

  /// `<12 hex>` folder name of [sessionKey].
  static String sessionFolder(String sessionKey) =>
      sha1.convert(utf8.encode(sessionKey)).toString().substring(0, 12);

  Future<String> reserve({required String sessionKey, required String fileName}) async {
    final home = await _files.home();
    final dir = RemotePath.join(
        RemotePath.join(RemotePath.join(home, '.herdr-mobile'), 'inbox'), sessionFolder(sessionKey));
    final safe = inboxSafeName(fileName);
    final stamp = _stamp(_now());
    // One makeDirs for the session folder, started with the first name check
    // (a name in a folder that does not exist yet is free by definition).
    final made = _known.contains(dir)
        ? null
        : _files.makeDirs(dir).then((_) {
            _known.add(dir);
          });
    // Observed from the start: if the name check fails first, a failed
    // makeDirs must not surface later as an unhandled error.
    made?.then((_) {}, onError: (Object _) {});
    for (var n = 1;; n++) {
      final path = RemotePath.join(dir, _numbered(stamp, safe, n));
      if (!_taken.add(path)) continue;
      if (_taken.length > 2000) _taken.removeWhere((p) => p != path);
      if (await _isFree(path)) {
        await made;
        return path;
      }
    }
  }

  static String _numbered(String stamp, String safe, int n) {
    if (n == 1) return '$stamp-$safe';
    final dot = safe.lastIndexOf('.');
    return dot > 0 && dot < safe.length - 1
        ? '$stamp-${safe.substring(0, dot)}-$n${safe.substring(dot)}'
        : '$stamp-$safe-$n';
  }

  Future<bool> _isFree(String path) async {
    try {
      await _files.stat(path);
      return false;
    } on RemoteFileException catch (e) {
      if (e.kind == RemoteFileErrorKind.notFound) return true;
      rethrow;
    }
  }

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}-'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  /// Deletes regular files older than [maxAge] directly inside the session
  /// folders of the inbox (`<12 hex>`), at most [cap] of them, over SFTP.
  /// Nothing outside `<home>/.herdr-mobile/inbox/<12 hex>/` is listed or
  /// removed; links and folders are skipped, failures end the sweep quietly.
  /// Returns how many files went.
  Future<int> cleanup({Duration maxAge = inboxMaxAge, int cap = inboxCleanupCap}) async {
    var deleted = 0;
    try {
      final home = await _files.home();
      final base = RemotePath.join(RemotePath.join(home, '.herdr-mobile'), 'inbox');
      final cutoff = _now().toUtc().subtract(maxAge);
      final List<RemoteEntry> folders;
      try {
        folders = await _files.list(base);
      } on RemoteFileException {
        return 0; // no inbox yet, or unreadable
      }
      for (final folder in folders) {
        if (deleted >= cap) break;
        if (folder.kind != RemoteEntryKind.dir || !_sessionFolder.hasMatch(folder.name)) continue;
        final dir = RemotePath.join(base, folder.name);
        final List<RemoteEntry> files;
        try {
          files = await _files.list(dir);
        } on RemoteFileException {
          continue;
        }
        for (final file in files) {
          if (deleted >= cap) break;
          final modified = file.modified;
          if (file.kind != RemoteEntryKind.file ||
              modified == null ||
              !modified.isBefore(cutoff) ||
              file.name.contains('/') ||
              file.name == '.' ||
              file.name == '..') {
            continue;
          }
          try {
            await _files.remove(RemotePath.join(dir, file.name));
            deleted++;
          } on RemoteFileException {
            // not ours to remove, or already gone
          }
        }
      }
    } on RemoteFileException {
      // best effort
    }
    return deleted;
  }

  static final _sessionFolder = RegExp(r'^[0-9a-f]{12}$');
}

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
  /// the first screens for the SFTP channel.
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
  /// files deleted, or null when skipped.
  Future<int?> run(MachineConnection machine) async {
    final id = machine.profile.id;
    try {
      final last = await _log.lastRun(id);
      if (last != null && _now().difference(last) < every) return null;
      if (!machine.files.supported) return null;
      final deleted = await HostInbox.of(machine.files).cleanup();
      await _log.record(id, _now());
      return deleted;
    } on Object {
      return null; // best effort; tried again next launch
    }
  }
}
