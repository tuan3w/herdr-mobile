import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What was reviewed, as `machine id -> pane id -> completion key`: the one
/// finished-work state of that pane the person has looked at.
typedef ReviewedMap = Map<String, Map<String, String>>;

/// Where [ReviewedState] is kept between launches.
abstract interface class ReviewedStore {
  /// Null when nothing usable is stored.
  Future<ReviewedMap?> read();

  Future<void> write(ReviewedMap reviewed);
}

class PrefsReviewedStore implements ReviewedStore {
  static const _key = 'reviewed.v1';

  @override
  Future<ReviewedMap?> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final out = <String, Map<String, String>>{};
      for (final MapEntry(key: machine, value: panes) in json.entries) {
        if (machine is! String || panes is! Map) continue;
        final kept = <String, String>{
          for (final MapEntry(key: pane, value: completion) in panes.entries)
            if (pane is String && completion is String) pane: completion,
        };
        if (kept.isNotEmpty) out[machine] = kept;
      }
      return out;
    } on Object {
      return null;
    }
  }

  @override
  Future<void> write(ReviewedMap reviewed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(reviewed));
  }
}

/// The agents that finished and that this phone's person has since looked at.
///
/// herdr clears `done` only when a pane is focused, and focusing moves the
/// desktop's view, so the phone never does. It remembers instead: a finished
/// agent is reviewed when the person opens it or answers it, and then shows as
/// idle on the phone (`MachineConnection` applies this to what it shows) while
/// herdr's own seen state stays untouched.
///
/// A review is keyed by machine, pane and a completion key that names that one
/// finished state (herdr's `completion_seq`, else when the state was observed
/// to begin), so the next time the agent finishes it asks for attention
/// again. One key per pane is kept; [prune] drops the panes herdr no longer
/// has, which keeps the stored map as small as the fleet.
class ReviewedState extends ChangeNotifier {
  ReviewedState([this._store]);

  final ReviewedStore? _store;
  final ReviewedMap _reviewed = {};
  bool _loaded = false;

  /// Brings back what was saved. Call once, before the first frame. A store
  /// that cannot be read leaves nothing reviewed.
  Future<void> load() async {
    final store = _store;
    if (store == null || _loaded) return;
    ReviewedMap? saved;
    try {
      saved = await store.read();
    } on Object {
      saved = null;
    }
    _loaded = true;
    if (saved == null) return;
    for (final MapEntry(:key, :value) in saved.entries) {
      _reviewed.putIfAbsent(key, () => {}).addAll(value);
    }
    notifyListeners();
  }

  bool isReviewed(String machineId, String paneId, String completionKey) =>
      _reviewed[machineId]?[paneId] == completionKey;

  /// Marks the finished state [completionKey] of the pane as looked at.
  /// Returns whether that was news.
  bool review(String machineId, String paneId, String completionKey) {
    final panes = _reviewed.putIfAbsent(machineId, () => {});
    if (panes[paneId] == completionKey) return false;
    panes[paneId] = completionKey;
    _save();
    notifyListeners();
    return true;
  }

  /// Forgets reviews of panes of [machineId] that are not in [livePaneIds]
  /// (herdr no longer has them). Changes nothing that is shown, so nobody is
  /// notified.
  void prune(String machineId, Set<String> livePaneIds) {
    final panes = _reviewed[machineId];
    if (panes == null) return;
    final before = panes.length;
    panes.removeWhere((pane, _) => !livePaneIds.contains(pane));
    if (panes.isEmpty) _reviewed.remove(machineId);
    if (panes.length != before) _save();
  }

  /// Forgets the review of one pane: it has left the finished state that was
  /// reviewed. Nothing shown changes (only a pane that is done is shown as
  /// reviewed), so nobody is notified.
  void unmark(String machineId, String paneId) {
    final panes = _reviewed[machineId];
    if (panes == null || panes.remove(paneId) == null) return;
    if (panes.isEmpty) _reviewed.remove(machineId);
    _save();
  }

  /// The machine was removed.
  void forgetMachine(String machineId) {
    if (_reviewed.remove(machineId) != null) _save();
  }

  /// How many reviews are kept (tests, and a bound worth asserting).
  int get length => _reviewed.values.fold(0, (n, panes) => n + panes.length);

  // A phone that cannot write its preferences still remembers for this launch.
  void _save() {
    final store = _store;
    if (store == null || !_loaded) return;
    final copy = {
      for (final MapEntry(:key, :value) in _reviewed.entries) key: Map.of(value),
    };
    unawaited(() async {
      try {
        await store.write(copy);
      } on Object {
        // The next change writes again.
      }
    }());
  }
}
