import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../acp/acp_models.dart';
import '../acp/session_state.dart';

/// Where in a session's transcript the person last was.
class SeenMarker {
  const SeenMarker(this.at, this.itemCount);

  /// When (the phone's clock). Shown as "since 14:02"; never used to order
  /// items, because replayed items carry no reliable time.
  final DateTime at;

  /// How many transcript items there were: everything at an index below this
  /// has been seen.
  final int itemCount;
}

/// What happened in a session while the person was away, for the header line
/// "6 steps since 14:02 · 1 needs you" and the unread divider.
class SinceLeft {
  const SinceLeft({
    required this.since,
    required this.steps,
    required this.tools,
    required this.messages,
    required this.stops,
    required this.notes,
    required this.needsYou,
    required this.firstUnseenKey,
  });

  /// When the person last saw the session.
  final DateTime since;

  /// What is new and counts as a step: [tools] + [messages] + [stops] +
  /// [notes]. The person's own messages and the agent's thoughts are news
  /// but not steps.
  final int steps;

  /// New tool calls.
  final int tools;

  /// New messages from the agent (not thoughts).
  final int messages;

  /// New quiet stop rows (refusal, limit).
  final int stops;

  /// New notes the app wrote (the agent changed the mode on its own).
  final int notes;

  /// Requests waiting for the person now (permissions and questions),
  /// whether or not they arrived while away.
  final int needsYou;

  /// [TranscriptItem.key] of the first item the person has not seen: the
  /// unread divider goes above it. Null when nothing new was appended (only
  /// a request that was already on screen is waiting).
  final String? firstUnseenKey;
}

/// Where [LastSeen] is kept between launches.
abstract interface class LastSeenStore {
  /// Null when nothing usable is stored.
  Future<Map<String, SeenMarker>?> read();

  Future<void> write(Map<String, SeenMarker> markers);
}

class PrefsLastSeenStore implements LastSeenStore {
  static const _key = 'lastSeen.v1';

  @override
  Future<Map<String, SeenMarker>?> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final out = <String, SeenMarker>{};
      for (final MapEntry(key: key, value: value) in json.entries) {
        if (key is! String || value is! Map) continue;
        final at = value['at'];
        final n = value['n'];
        if (at is! int || n is! int || n < 0) continue;
        out[key] = SeenMarker(DateTime.fromMillisecondsSinceEpoch(at), n);
      }
      return out;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(Map<String, SeenMarker> markers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        for (final MapEntry(:key, :value) in markers.entries)
          key: {'at': value.at.millisecondsSinceEpoch, 'n': value.itemCount},
      }),
    );
  }
}

/// A per-session "last seen" marker, kept between launches.
///
/// `ReviewedState` answers "did the person look at this finish" per pane.
/// This answers a different question, per agent session: where in the
/// transcript were they, so the next visit can say what happened since.
///
/// **Position is an item count, not a time.** The transcript only grows at
/// its end, so "everything at an index at or above [SeenMarker.itemCount] is
/// new" holds whatever the clock says; a history the agent replays on
/// `session/load` has no usable time per item but rebuilds the same items in
/// the same order. Consequences:
/// - No marker (the first visit) means no divider: [sinceLeft] is null.
/// - A transcript shorter than the marker is one still being replayed (or
///   rebuilt differently): [sinceLeft] is null, never "news". Ask once the
///   replay has settled (the session is attached and its first load is done);
///   asking mid-replay under-counts, because the items past the marker have
///   not arrived yet.
/// - Replayed history up to the marker is not news; the items past it are
///   (they happened while the person was away).
///
/// The key is any stable string for one agent session (the app uses
/// machine, pane and session id). At most [maxSessions] are kept, the most
/// recently marked; marking again moves a session to the front.
class LastSeen {
  LastSeen([this._store]);

  /// Sessions kept.
  static const maxSessions = 200;

  final LastSeenStore? _store;

  // Oldest first: the first entry is the one to drop.
  final LinkedHashMap<String, SeenMarker> _markers = LinkedHashMap();
  Future<void>? _loading;
  bool _loaded = false;
  bool _dirty = false;

  /// Brings back what was saved. Call once, before the first frame (it is
  /// safe to call again, and [sinceLeft] waits for it). A store that cannot
  /// be read leaves nothing marked; markers set before the load finished win
  /// over saved ones.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    final store = _store;
    if (store == null) {
      _loaded = true;
      return;
    }
    Map<String, SeenMarker>? saved;
    try {
      saved = await store.read();
    } on Object {
      saved = null;
    }
    _loaded = true;
    if (saved != null) {
      final mine = Map<String, SeenMarker>.of(_markers);
      _markers.clear();
      final byAge = saved.entries.toList()..sort((a, b) => a.value.at.compareTo(b.value.at));
      for (final e in byAge) {
        _markers[e.key] = e.value;
      }
      for (final e in mine.entries) {
        _markers.remove(e.key);
        _markers[e.key] = e.value;
      }
      _trim();
    }
    if (_dirty) _save();
  }

  /// The person has seen [itemCount] items of the session [key] as of [at].
  /// Call when they leave the screen (or the app goes to the background),
  /// with `state.items.length`.
  void markSeen(String key, DateTime at, int itemCount) {
    if (key.isEmpty) return;
    _markers.remove(key);
    _markers[key] = SeenMarker(at, itemCount < 0 ? 0 : itemCount);
    _trim();
    _dirty = true;
    _save();
  }

  /// The marker of [key], or null (never marked).
  SeenMarker? markerOf(String key) => _markers[key];

  /// Forgets the session (it was closed or deleted).
  void forget(String key) {
    if (_markers.remove(key) != null) {
      _dirty = true;
      _save();
    }
  }

  /// What is new in [state] since the person last saw session [key], or null
  /// when there is no marker, when the history is still being replayed
  /// ([AgentSessionState.replaying]) or the transcript is shorter than the
  /// marker (a replay in progress, or rebuilt differently), or when nothing
  /// is new and nothing waits.
  Future<SinceLeft?> sinceLeft(String key, AgentSessionState state) async {
    await load();
    final marker = _markers[key];
    if (marker == null || state.replaying) return null;
    final items = state.items;
    if (items.length < marker.itemCount) return null;

    var tools = 0, messages = 0, stops = 0, notes = 0;
    for (var i = marker.itemCount; i < items.length; i++) {
      switch (items[i]) {
        case TranscriptTool():
          tools++;
        case TranscriptMessage(:final role):
          if (role == MessageRole.agent) messages++;
        case TranscriptStop():
          stops++;
        case TranscriptNote():
          notes++;
      }
    }
    final steps = tools + messages + stops + notes;
    final needsYou = state.pending.length;
    if (steps == 0 && needsYou == 0) return null;
    return SinceLeft(
      since: marker.at,
      steps: steps,
      tools: tools,
      messages: messages,
      stops: stops,
      notes: notes,
      needsYou: needsYou,
      firstUnseenKey: marker.itemCount < items.length ? items[marker.itemCount].key : null,
    );
  }

  /// How many sessions are kept (tests, and a bound worth asserting).
  int get length => _markers.length;

  void _trim() {
    while (_markers.length > maxSessions) {
      _markers.remove(_markers.keys.first);
    }
  }

  // A phone that cannot write its preferences still remembers for this launch.
  void _save() {
    final store = _store;
    if (store == null || !_loaded) return;
    _dirty = false;
    final copy = Map<String, SeenMarker>.of(_markers);
    unawaited(() async {
      try {
        await store.write(copy);
      } on Object {
        // The next change writes again.
      }
    }());
  }
}
