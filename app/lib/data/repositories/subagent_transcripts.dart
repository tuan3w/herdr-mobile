import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../acp/session_state.dart';
import '../acp/subagents/subagent_log_path.dart';
import '../acp/subagents/subagent_overlay.dart';
import '../acp/subagents/subagent_run.dart';
import '../models/remote_file.dart';
import '../observed/omp_log_mapper.dart';
import '../services/remote_files.dart';

/// Best effort: the conversation of an omp subagent, read from the log omp
/// keeps of it on the host, so the drill-in can show it the way it shows a
/// Claude subagent's. omp's ACP stream carries only a summary.
///
/// What it relies on (verified on omp 18.4.12, docs/AGENT_SESSIONS.md): the
/// ACP session id is omp's session id; the parent's session file is
/// `<sessions>/<project dir>/<time>_<session id>.jsonl`; a `task` subagent
/// writes `<parent file without .jsonl>/<id>.jsonl`, the same entry format as
/// the parent's (header `session` entry with `version: 3` and the parent's
/// path), so [OmpLogMapper] maps it. Everything here gives up silently when
/// any of that does not hold: the run stays the summary it always was.

// ---------------------------------------------------------------------------
// finding the artifact directory

/// Finds the folder of a session's artifacts on the host, over SFTP only.
///
/// omp names the project folder after the session's working directory
/// (`session-paths.ts`): `-tmp-<rest>` below the temp dir, `-<rest>` below
/// the home directory, else `--<path>--`, with `/`, `\` and `:` turned into
/// `-`. The sessions root is `~/.omp/agent/sessions`, or
/// `~/.local/share/omp/sessions` once omp was moved to XDG paths. The
/// working directory the app knows can differ from what omp used (a symlink,
/// another temp dir), so the exact names are tried first and then the
/// folders whose name contains the directory's own name. A custom
/// `PI_CODING_AGENT_DIR` is not guessable: nothing is found.
class OmpSessionLocator {
  OmpSessionLocator(this._files, {this.maxFolders = 10});

  final RemoteFiles _files;

  /// The most project folders listed while looking for the session file.
  final int maxFolders;

  static final _sessionId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{5,100}$');

  /// The artifact directory of session [sessionId] that ran in [cwd] (no
  /// trailing slash), or null when no session file was found. Throws
  /// [RemoteFileException] when the host cannot be read (no SFTP, link down).
  Future<String?> artifactDir({required String sessionId, required String cwd}) async {
    if (!_sessionId.hasMatch(sessionId) || !RemotePath.isAbsolute(cwd)) return null;
    final home = await _files.home();
    var canonical = cwd;
    try {
      canonical = await _files.realpath(cwd);
    } on RemoteFileException catch (e) {
      if (!_missing(e)) rethrow;
    }
    final exact = projectFolderNames(canonical, home: home);
    final base = _safeSegment(RemotePath.basename(canonical));
    for (final root in ['$home/.omp/agent/sessions', '$home/.local/share/omp/sessions']) {
      final List<RemoteEntry> folders;
      try {
        folders = await _files.list(root);
      } on RemoteFileException catch (e) {
        if (_missing(e)) continue;
        rethrow;
      }
      final names = {for (final f in folders) if (f.isDirectory) f.name};
      final tries = [
        for (final n in exact)
          if (names.contains(n)) n,
        if (base.isNotEmpty)
          for (final n in names)
            if (!exact.contains(n) && n.contains(base)) n,
      ].take(maxFolders);
      for (final name in tries) {
        final found = await _sessionFile('$root/$name', sessionId);
        if (found != null) return found.substring(0, found.length - '.jsonl'.length);
      }
    }
    return null;
  }

  Future<String?> _sessionFile(String folder, String sessionId) async {
    final List<RemoteEntry> entries;
    try {
      entries = await _files.list(folder);
    } on RemoteFileException catch (e) {
      if (_missing(e)) return null;
      rethrow;
    }
    final suffix = '_$sessionId.jsonl';
    for (final e in entries) {
      if (e.isFile && e.name.endsWith(suffix)) return e.path;
    }
    return null;
  }

  static bool _missing(RemoteFileException e) =>
      e.kind == RemoteFileErrorKind.notFound ||
      e.kind == RemoteFileErrorKind.permission ||
      e.kind == RemoteFileErrorKind.notADirectory;

  static String _safeSegment(String s) => s.replaceAll(RegExp(r'[/\\:]'), '-');

  /// The names omp may have given the project folder of [cwd], in its order
  /// of preference (a temp directory first, then home, then the absolute
  /// form). [tmp] is where the host keeps temporary files.
  static List<String> projectFolderNames(String cwd, {required String home, String tmp = '/tmp'}) {
    String? within(String root) {
      final r = root.endsWith('/') && root.length > 1 ? root.substring(0, root.length - 1) : root;
      if (cwd == r) return '';
      final prefix = r == '/' ? '/' : '$r/';
      return cwd.startsWith(prefix) ? cwd.substring(prefix.length) : null;
    }

    String encode(String prefix, String relative) {
      final e = _safeSegment(relative);
      if (e.isEmpty) return prefix;
      return prefix.endsWith('-') ? '$prefix$e' : '$prefix-$e';
    }

    final out = <String>[];
    final inTmp = within(tmp);
    final inHome = within(home);
    if (inTmp != null) out.add(encode('-tmp', inTmp));
    if (inHome != null) out.add(encode('-', inHome));
    out.add('--${_safeSegment(cwd.replaceFirst(RegExp(r'^[/\\]'), ''))}--');
    return out;
  }
}

// ---------------------------------------------------------------------------
// reading one log

/// What a [SubagentLogReader.poll] found.
enum LogPoll {
  /// Nothing new.
  unchanged,

  /// The transcript changed ([SubagentLogReader.state]).
  updated,

  /// The file is there but is not a log this app can show (a format it does
  /// not know, another parent, nothing that maps).
  unusable,
}

/// Reads one subagent log incrementally and keeps its transcript. Not safe to
/// call [poll] twice at once.
///
/// The first read takes the newest [maxReadBytes] (from a line boundary) and
/// the newest [maxLines] lines of that; later reads take what was appended
/// since. A file that shrank, or grew by more than [maxReadBytes] since the
/// last read, starts over. A line longer than [maxLineBytes] is skipped
/// (counted in [skippedLines]). Everything cut off the start is
/// [earlierNotShown].
class SubagentLogReader {
  SubagentLogReader(
    this._files,
    this.path, {
    this.expectedParent,
    this.maxReadBytes = 1024 * 1024,
    this.maxLines = 4000,
    this.maxLineBytes = 256 * 1024,
    this.sliceLines = 150,
  });

  final RemoteFiles _files;
  final String path;

  /// The artifact folder's name (the parent's session file without
  /// `.jsonl`); the log's header must name that file as its parent, when it
  /// names one.
  final String? expectedParent;
  final int maxReadBytes;
  final int maxLines;
  final int maxLineBytes;
  final int sliceLines;

  /// The only format version read. omp 18.4.12 writes 3 on every entry log.
  static const knownVersion = 3;

  final OmpLogMapper _mapper = OmpLogMapper();
  AgentSessionState state = const AgentSessionState('subagent-log');

  bool earlierNotShown = false;
  int skippedLines = 0;

  /// Items cut from the start of [state] to stay under [SubagentRun.maxItems].
  int droppedItems = 0;

  /// Stop mapping at the next slice: nobody wants the result any more.
  bool cancelled = false;

  bool _started = false;
  int _offset = 0;
  int _seenSize = -1;
  bool _discarding = false;

  SubagentLogInfo get info => SubagentLogInfo(earlierNotShown: earlierNotShown, skippedLines: skippedLines);

  void _reset() {
    _mapper.reset();
    state = const AgentSessionState('subagent-log');
    earlierNotShown = false;
    skippedLines = 0;
    droppedItems = 0;
    _started = false;
    _offset = 0;
    _seenSize = -1;
    _discarding = false;
  }

  /// Reads what is new. Throws [RemoteFileException] for a file problem
  /// (including a missing file); never for a line it cannot read.
  Future<LogPoll> poll() async {
    final stat = await _files.stat(path);
    final size = stat.size;
    if (!stat.isFile || size == null) return LogPoll.unusable;
    if (_started && size < _offset) _reset();
    if (_started && size - _offset > maxReadBytes) _reset();
    if (size == _seenSize) return _started ? LogPoll.unchanged : LogPoll.unusable;
    if (size == 0) return LogPoll.unusable;

    final first = !_started;
    var from = _offset;
    var aligned = true;
    if (first) {
      from = size > maxReadBytes ? size - maxReadBytes : 0;
      if (from > 0) {
        earlierNotShown = true;
        // One byte before: when it is the newline, the first line is whole.
        from -= 1;
        aligned = false;
      }
    }
    final head = first && from > 0 ? await _readRange(0, headBytes) : null;
    final data = await _readRange(from, size - from);
    if (data.isEmpty) return LogPoll.unchanged;
    if (first && !_headerOk(head ?? data)) {
      // A different file: leave it for good unless it changes under us.
      _seenSize = size;
      return LogPoll.unusable;
    }

    var start = 0;
    if (!aligned) {
      // `data` begins one byte before the tail: whole first line iff that
      // byte ends a line; otherwise skip the partial one.
      if (data[0] == 0x0A) {
        start = 1;
      } else {
        final nl = data.indexOf(0x0A);
        if (nl < 0) {
          _seenSize = size;
          return LogPoll.unusable;
        }
        start = nl + 1;
      }
    }

    final lines = <Uint8List>[];
    var consumed = start;
    var at = start;
    while (at < data.length) {
      final nl = data.indexOf(0x0A, at);
      if (nl < 0) break;
      if (_discarding) {
        _discarding = false;
      } else if (nl - at > maxLineBytes) {
        skippedLines++;
      } else if (nl > at) {
        lines.add(Uint8List.sublistView(data, at, nl));
      }
      at = nl + 1;
      consumed = at;
    }
    // A last line that is still being written stays for the next read, unless
    // it is already over the limit: then skip it, and the rest of it when it
    // ends.
    if (data.length - consumed > maxLineBytes) {
      if (!_discarding) skippedLines++;
      _discarding = true;
      consumed = data.length;
    }

    var use = lines;
    if (use.length > maxLines) {
      use = use.sublist(use.length - maxLines);
      earlierNotShown = true;
    }
    _started = true;
    _offset = (from + consumed);
    _seenSize = size;

    var next = state;
    var n = 0;
    for (final raw in use) {
      for (final u in _mapper.map(utf8.decode(raw, allowMalformed: true))) {
        next = next.apply(u);
      }
      if (++n % sliceLines == 0) {
        await Future<void>.delayed(Duration.zero);
        if (cancelled) return LogPoll.unchanged;
      }
    }
    final trimmed = next.keepingNewest(SubagentRun.maxItems);
    droppedItems += next.items.length - trimmed.items.length;
    final changed = !identical(trimmed, state);
    state = trimmed;
    if (first && state.items.isEmpty) {
      // Nothing in it maps to a message or a tool call: not a conversation.
      return LogPoll.unusable;
    }
    return changed ? LogPoll.updated : LogPoll.unchanged;
  }

  static const headBytes = 8192;

  /// Whether the header names a format and a parent this reader can show.
  /// [bytes] starts at the beginning of the file.
  bool _headerOk(Uint8List bytes) {
    var at = 0;
    for (var i = 0; i < 8; i++) {
      final nl = bytes.indexOf(0x0A, at);
      if (nl < 0) return false;
      final Object? entry;
      try {
        entry = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, at, nl), allowMalformed: true));
      } on Object {
        return false;
      }
      at = nl + 1;
      if (entry is! Map || entry['type'] != 'session') continue;
      if (entry['version'] != knownVersion) return false;
      final parent = entry['parentSession'];
      final want = expectedParent;
      if (parent is String && want != null) {
        return RemotePath.basename(parent) == '$want.jsonl';
      }
      return true;
    }
    return false;
  }

  /// [length] bytes from [offset], or fewer at the end of the file.
  Future<Uint8List> _readRange(int offset, int length) async {
    final out = BytesBuilder(copy: false);
    var got = 0;
    while (got < length) {
      final piece = await _files.read(path, offset: offset + got, length: length - got);
      if (piece.isEmpty) break;
      out.add(piece);
      got += piece.length;
    }
    return out.takeBytes();
  }
}

// ---------------------------------------------------------------------------
// the session's side

/// Reads the logs of the omp subagents a session started, for the runs a
/// screen asks about, and lays the transcripts over the runs ([overlay]).
///
/// Reads happen only for a run that is [watch]ed (its drill-in is open): once
/// when the screen opens, then every [interval] while the run is active, and
/// once more after it ended. A watch that ends cancels the timer; with nothing
/// watched there is no timer and no read. Every failure ends in "no
/// transcript" ([status]); a connection failure additionally says "failed" so
/// the screen can offer a retry.
class SubagentTranscripts {
  SubagentTranscripts({
    required RemoteFiles files,
    required this.sessionId,
    required this.cwd,
    required this.runOf,
    required this.onChange,
    this.reachable = _always,
    this.interval = const Duration(seconds: 3),
    this.readerFor,
  }) : _files = files,
       _locator = OmpSessionLocator(files);

  final RemoteFiles _files;
  final OmpSessionLocator _locator;

  /// The ACP session id (omp's session id); null before the session exists.
  final String? Function() sessionId;
  final String cwd;

  /// The run the reducer made, without a transcript laid over it.
  final SubagentRun? Function(String runId) runOf;

  /// Something to tell the session's listeners about.
  final void Function() onChange;

  /// The machine can be reached now (nothing is read otherwise).
  final bool Function() reachable;

  /// The time between two reads of a running subagent's log.
  final Duration interval;

  /// Tests: a reader with other limits.
  final SubagentLogReader Function(String path, String? expectedParent)? readerFor;

  static bool _always() => true;

  final overlay = SubagentOverlay();
  final _entries = <String, _Entry>{};
  Timer? _timer;
  bool _disposed = false;
  bool _noSftp = false;
  Future<String?>? _lookup;
  String? _found;
  String? _foundFor;
  int? _missingTicks;

  /// Reading is under way or was done for [runId], as the screen needs it.
  SubagentLogStatus status(String runId) => _entries[runId]?.status ?? SubagentLogStatus.idle;

  /// A screen shows (true) or stops showing (false) the run [runId]. Counted:
  /// one call per screen.
  void watch(String runId, bool on) {
    if (_disposed) return;
    if (on) {
      final e = _entries.putIfAbsent(runId, _Entry.new);
      if (e.watchers++ == 0) {
        e.settled = false;
        _missingTicks = null; // look again for a folder that was not found
        unawaited(_read(runId, e));
        _timer ??= Timer.periodic(interval, (_) => _tick());
      }
    } else {
      final e = _entries[runId];
      if (e == null || e.watchers == 0) return;
      e.watchers--;
      if (_entries.values.every((e) => e.watchers == 0)) {
        _timer?.cancel();
        _timer = null;
      }
    }
  }

  /// Reads [runId] again now (the retry of a failed read).
  void retry(String runId) {
    final e = _entries[runId];
    if (_disposed || e == null || e.watchers == 0) return;
    e.settled = false;
    _missingTicks = null;
    if (e.status == SubagentLogStatus.failed) e.status = SubagentLogStatus.idle;
    unawaited(_read(runId, e));
  }

  void _tick() {
    if (_disposed) return;
    final missed = _missingTicks;
    if (missed != null) _missingTicks = missed + 1 >= missingTicks ? null : missed + 1;
    for (final MapEntry(:key, :value) in _entries.entries.toList()) {
      if (value.watchers > 0) unawaited(_read(key, value));
    }
  }

  Future<void> _read(String runId, _Entry e) async {
    if (_disposed || e.inFlight || _noSftp) return;
    final run = runOf(runId);
    if (run == null || run.route != SubagentRoute.omp) return;
    // A call that has no progress yet knows no id to look for.
    if (run.status == SubagentStatus.waiting) return;
    if (run.isActive) e.settled = false;
    if (e.settled || !reachable()) return;
    final wasActive = run.isActive;
    e.inFlight = true;
    var notify = false;
    void become(SubagentLogStatus next) {
      if (e.status == next) return;
      e.status = next;
      notify = true;
    }

    if (e.status == SubagentLogStatus.idle) become(SubagentLogStatus.loading);
    if (notify) onChange();
    notify = false;
    var conclusive = true;
    try {
      final outcome = await _readOnce(runId, e, run);
      if (_disposed) return;
      final r = e.reader;
      if (outcome == LogPoll.updated && r != null && r.state.items.isNotEmpty) {
        overlay.attach(runId, LoggedTranscript(r.state, r.info, droppedItems: r.droppedItems));
        become(SubagentLogStatus.shown);
        notify = true;
      } else if (e.status != SubagentLogStatus.shown) {
        become(SubagentLogStatus.unavailable);
      }
    } on RemoteFileException catch (ex) {
      if (_disposed) return;
      var next = SubagentLogStatus.unavailable;
      switch (ex.kind) {
        case RemoteFileErrorKind.network || RemoteFileErrorKind.failed:
          conclusive = false;
          next = SubagentLogStatus.failed;
        case RemoteFileErrorKind.unsupported:
          _noSftp = true;
        default:
          // Not there (yet), not allowed, not a file: the summary stays. A
          // log that has not been created yet is looked for again while the
          // run is active.
          break;
      }
      if (e.status != SubagentLogStatus.shown) become(next);
    } on Object {
      if (_disposed) return;
      if (e.status != SubagentLogStatus.shown) become(SubagentLogStatus.unavailable);
    } finally {
      e.inFlight = false;
    }
    if (!wasActive && conclusive) e.settled = true;
    if (notify) onChange();
  }

  Future<LogPoll> _readOnce(String runId, _Entry e, SubagentRun run) async {
    final name = validSubagentName(run.name);
    final sid = sessionId();
    if (name == null || sid == null || sid.isEmpty) return LogPoll.unusable;
    final dir = await _artifactDir(sid);
    if (dir == null) return LogPoll.unusable;
    final path = subagentLogPath(dir, name);
    if (path == null) return LogPoll.unusable;
    var reader = e.reader;
    if (reader == null || reader.path != path) {
      reader?.cancelled = true;
      final parent = RemotePath.basename(dir);
      reader = e.reader = readerFor?.call(path, parent) ?? SubagentLogReader(_files, path, expectedParent: parent);
      overlay.detach(runId);
    }
    return reader.poll();
  }

  /// The artifact folder of [sessionId]. Found once and kept; not finding it
  /// is remembered for [missingTicks] ticks (the session file is created
  /// with the first answer), a failed lookup (a dropped link) not at all.
  Future<String?> _artifactDir(String sessionId) async {
    if (_foundFor == sessionId && _found != null) return _found;
    if (_missingTicks != null) return null;
    final ask = _lookup ??= _locator.artifactDir(sessionId: sessionId, cwd: cwd).whenComplete(() => _lookup = null);
    final dir = await ask;
    if (dir != null) {
      _found = dir;
      _foundFor = sessionId;
    } else {
      _missingTicks = 0;
    }
    return dir;
  }

  /// How many ticks "no such session folder" is believed.
  static const missingTicks = 5;

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    for (final e in _entries.values) {
      e.reader?.cancelled = true;
    }
  }
}

class _Entry {
  int watchers = 0;
  bool inFlight = false;

  /// A read after the run ended found nothing more to wait for.
  bool settled = false;
  SubagentLogStatus status = SubagentLogStatus.idle;
  SubagentLogReader? reader;
}
