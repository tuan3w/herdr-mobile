import 'dart:collection';
import 'dart:convert';

import 'acp_client.dart';
import 'acp_models.dart';
import 'session_state.dart';

/// The method every line of a transcript log is.
const _updateMethod = 'session/update';

/// What the transcript cache writes for one session: the newest window of the
/// `session/update` lines the client received (what the keeper replays), as
/// they arrived, plus the answer to the `session/load` that came with them.
class TranscriptSnapshot {
  const TranscriptSnapshot({
    required this.sessionId,
    required this.asOf,
    required this.lines,
    this.setup,
    this.partial = false,
  });

  final String sessionId;

  /// When the client last knew this to be what the session looked like.
  final DateTime asOf;

  /// Raw JSON-RPC notification lines, oldest first.
  final List<String> lines;

  /// The result of `session/new`, `session/load` or `session/resume`, decoded.
  final Object? setup;

  /// Lines were left out (older ones past the caps, or one too large to keep).
  final bool partial;
}

/// What the transcript cache reads back: the same lines, decoded off the UI
/// thread ([updates] are the `params` of each notification).
class CachedTranscript {
  const CachedTranscript({
    required this.sessionId,
    required this.asOf,
    required this.updates,
    this.setup,
    this.partial = false,
  });

  final String sessionId;
  final DateTime asOf;
  final List<Map<Object?, Object?>> updates;
  final Object? setup;
  final bool partial;
}

/// The state a cached transcript shows before the keeper has answered: the
/// lines folded by the very reducer a `session/load` replay goes through
/// ([applyUpdateParams]; history carries no times), closed off like a
/// connection that dropped. Nothing in it waits for the person: requests are
/// not part of a log, they come from the keeper with a live attach.
AgentSessionState replayCachedTranscript(CachedTranscript cached) {
  var state = AgentSessionState(cached.sessionId, replaying: true);
  for (final params in cached.updates) {
    if (params['sessionId'] != cached.sessionId) continue;
    try {
      state = applyUpdateParams(state, params);
    } on Object {
      // One update the reducer cannot read costs that update, as in a replay.
    }
  }
  return state.withSetup(AcpSessionSetup.parse(cached.setup)).withDisconnected();
}

/// The lines of [cached] as the recorder holds them (the notifications they
/// were decoded from).
List<String> cachedLines(CachedTranscript cached) => [
  for (final params in cached.updates) jsonEncode({'jsonrpc': '2.0', 'method': _updateMethod, 'params': params}),
];

/// The lines of [lines] (the notifications of [sessionId] a transcript was
/// built from) that built [items], the first items of that transcript: every
/// line before the one that adds the item after them, so a late update of an
/// older call is in. Null when the lines do not give those items (the
/// transcript had more than the lines hold, or they were cut): then nothing
/// of them can be kept for the items.
List<String>? linesBefore(List<String> lines, String sessionId, List<TranscriptItem> items) {
  var state = AgentSessionState(sessionId, replaying: true);
  var end = lines.length;
  for (var i = 0; i < lines.length; i++) {
    final Object? decoded;
    try {
      decoded = jsonDecode(lines[i]);
    } on Object {
      continue;
    }
    final params = decoded is Map ? decoded['params'] : null;
    if (params is! Map || params['sessionId'] != sessionId) continue;
    try {
      state = applyUpdateParams(state, params);
    } on Object {
      continue;
    }
    if (state.items.length > items.length) {
      end = i;
      break;
    }
  }
  final got = AgentSessionState.signaturesOf(state.items.take(items.length));
  final want = AgentSessionState.signaturesOf(items);
  if (got.length != want.length) return null;
  for (var i = 0; i < got.length; i++) {
    if (got[i] != want[i]) return null;
  }
  return lines.sublist(0, end);
}

/// Keeps the newest window of a session's `session/update` lines while it is
/// attached, for the transcript cache.
///
/// The lines are stored verbatim (no encoding of the transcript, no editing of
/// a line): bounded by [maxLines] and [maxChars] (oldest first out), and a line
/// longer than [maxLineChars] is left out instead of cut, which marks the log
/// [partial]. The user's own messages never come back as an update on the
/// connection that sent them, so [addLocalUser] writes them the way the
/// keeper's log has them (`user_message_chunk`).
class TranscriptRecorder {
  TranscriptRecorder({this.maxLines = 4000, this.maxChars = 1 << 20, this.maxLineChars = 128 << 10});

  final int maxLines;

  /// Estimated by the length of the lines in UTF-16 code units; the cache
  /// itself measures bytes when it writes.
  final int maxChars;
  final int maxLineChars;

  final _lines = ListQueue<String>();
  var _chars = 0;
  var _partial = false;

  /// The lines of the last message [addLocalUser] wrote, for [takeBackLocalUser].
  var _localLines = <String>[];
  var _localCount = 0;

  /// The answer to the last `session/load`, `session/new` or `session/resume`.
  Object? setup;

  /// Bumps with every change: a saver compares it with the one it saved.
  int revision = 0;

  bool get partial => _partial;
  int get length => _lines.length;
  bool get isEmpty => _lines.isEmpty;

  /// A copy of the lines, oldest first.
  List<String> get lines => List<String>.of(_lines);

  /// A new attach replays the whole log again: start over.
  void reset() {
    _lines.clear();
    _chars = 0;
    _partial = false;
    _localLines = [];
    setup = null;
    revision++;
  }

  /// [older] go in front of what the recorder holds (a transcript that kept
  /// turns the host no longer replays); the caps drop the oldest lines first,
  /// as for any line.
  void prepend(List<String> older) {
    if (older.isEmpty) return;
    revision++;
    final keep = [
      for (final line in older)
        if (line.length <= maxLineChars) line,
    ];
    if (keep.length != older.length) _partial = true;
    final mine = _lines.toList();
    _lines
      ..clear()
      ..addAll(keep)
      ..addAll(mine);
    _chars = _lines.fold<int>(0, (n, l) => n + l.length);
    while (_lines.length > maxLines || (_chars > maxChars && _lines.length > 1)) {
      _chars -= _lines.removeFirst().length;
      _partial = true;
    }
  }

  void add(String line) {
    _push(line);
  }

  /// Whether the line was kept.
  bool _push(String line) {
    revision++;
    if (line.length > maxLineChars) {
      _partial = true;
      return false;
    }
    _lines.add(line);
    _chars += line.length;
    while (_lines.length > maxLines || (_chars > maxChars && _lines.length > 1)) {
      _chars -= _lines.removeFirst().length;
      _partial = true;
    }
    return true;
  }

  /// The user sent [blocks] from this phone.
  void addLocalUser(String sessionId, List<ContentBlock> blocks) {
    final id = 'local-${_localCount++}';
    final kept = <String>[];
    for (final block in blocks) {
      final line = jsonEncode({
        'jsonrpc': '2.0',
        'method': _updateMethod,
        'params': {
          'sessionId': sessionId,
          'update': {'sessionUpdate': 'user_message_chunk', 'messageId': id, 'content': block.toJson()},
        },
      });
      if (_push(line)) kept.add(line);
    }
    _localLines = kept;
  }

  /// The message [addLocalUser] last wrote was taken back (the agent refused
  /// it as busy): its lines go, wherever the agent's own lines have got since.
  void takeBackLocalUser() {
    for (final line in _localLines) {
      if (_lines.remove(line)) _chars -= line.length;
    }
    _localLines = [];
    revision++;
  }
}
