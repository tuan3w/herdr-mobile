import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/herdr_models.dart';

/// One open tab: which pane of which machine. Pane ids are only unique per
/// machine, so both are the identity.
@immutable
class TabRef {
  const TabRef(this.machineId, this.paneId);

  final String machineId;
  final String paneId;

  /// Stable map/widget key.
  String get key => '$machineId|$paneId';

  @override
  bool operator ==(Object other) =>
      other is TabRef && other.machineId == machineId && other.paneId == paneId;

  @override
  int get hashCode => Object.hash(machineId, paneId);

  @override
  String toString() => 'TabRef($key)';
}

/// What is kept of the open tabs between launches: which panes, in which
/// order, which one was showing, and whether the tab screen was in front.
@immutable
class SavedTabs {
  const SavedTabs({required this.tabs, this.active, this.hostOpen = false});

  final List<TabRef> tabs;
  final String? active;
  final bool hostOpen;

  String encode() => jsonEncode({
    'v': 1,
    'tabs': [
      for (final t in tabs) [t.machineId, t.paneId],
    ],
    'active': active,
    'host': hostOpen,
  });

  /// Null for anything that is not what [encode] writes.
  static SavedTabs? decode(String? source) {
    if (source == null) return null;
    try {
      final json = jsonDecode(source);
      if (json is! Map || json['v'] != 1) return null;
      final tabs = <TabRef>[];
      for (final entry in json['tabs'] as List) {
        if (entry is! List || entry.length != 2) continue;
        final machine = entry[0];
        final pane = entry[1];
        if (machine is String && pane is String && machine.isNotEmpty && pane.isNotEmpty) {
          tabs.add(TabRef(machine, pane));
        }
      }
      final active = json['active'];
      return SavedTabs(
        tabs: tabs,
        active: active is String ? active : null,
        hostOpen: json['host'] == true,
      );
    } on Object {
      return null;
    }
  }
}

/// Where [OpenTabs] are kept between launches.
abstract interface class OpenTabsStore {
  Future<SavedTabs?> read();

  Future<void> write(SavedTabs tabs);
}

class PrefsOpenTabsStore implements OpenTabsStore {
  static const _key = 'openTabs.v1';

  @override
  Future<SavedTabs?> read() async =>
      SavedTabs.decode((await SharedPreferences.getInstance()).getString(_key));

  @override
  Future<void> write(SavedTabs tabs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, tabs.encode());
  }
}

/// The agents the user has open as browser-style tabs: one list, one active
/// tab. With a store they are kept between launches (the panes, their order,
/// the active one and whether the tab screen was open); [load] brings them
/// back before the app starts.
///
/// The order is stable while the tab screen is in front: a new tab goes right
/// after the active one and switching never re-sorts. It is sorted by recency
/// only when the screen is entered afresh (`open(..., byRecency: true)`), so
/// the agent used last is the first tab the next time.
///
/// Closing a tab forgets it here; it never touches the agent.
class OpenTabs extends ChangeNotifier {
  OpenTabs({this.maxTabs = 12, this._store});

  final OpenTabsStore? _store;
  bool _loaded = false;
  String? _saved;

  /// Open tabs beyond this evict the least recently used one (never the
  /// active tab).
  final int maxTabs;

  final List<TabRef> _tabs = [];
  String? _activeKey;

  /// Last time each tab was active, as an increasing counter.
  final Map<String, int> _used = {};
  int _clock = 0;

  /// Last status seen per tab, to find a background tab that changed.
  final Map<String, AgentStatus?> _status = {};
  final Set<String> _attention = {};

  /// A tab screen is on the navigator: opening another tab only switches.
  /// Set by the screen itself; not a notification, but it is saved.
  bool get hostAttached => _hostAttached;
  bool _hostAttached = false;
  set hostAttached(bool value) {
    if (_hostAttached == value) return;
    _hostAttached = value;
    _persist();
  }

  /// The tab screen went away. With [leaving] the person left it, and the
  /// tabs are saved as "not open"; without, the app itself is being torn down
  /// (swiped away, process ending), and what is saved stays "it was open", so
  /// the next launch puts it back.
  void detachHost({required bool leaving}) {
    if (!_hostAttached) return;
    _hostAttached = false;
    if (leaving) _persist();
  }

  /// The tab screen was open when the app was last left: the app puts it back
  /// in front once. Set by [load]; [takeResume] reads and clears it.
  bool _resume = false;

  bool takeResume() {
    final resume = _resume;
    _resume = false;
    return resume;
  }

  /// Brings back the saved tabs. Call once, before the first frame. A store
  /// that cannot be read, or holds something else, leaves no tabs.
  Future<void> load() async {
    final store = _store;
    if (store == null || _loaded) return;
    SavedTabs? saved;
    try {
      saved = await store.read();
    } on Object {
      saved = null;
    }
    _loaded = true;
    if (saved == null) return;
    for (final ref in saved.tabs) {
      if (_tabs.length < maxTabs && !contains(ref.key)) _tabs.add(ref);
    }
    // Recency follows the saved order, so the first screen entry (which sorts
    // by recency) keeps it.
    for (var i = 0; i < _tabs.length; i++) {
      _used[_tabs[i].key] = _tabs.length - i;
    }
    _clock = _tabs.length;
    final active = saved.active;
    if (active != null && contains(active)) {
      _activeKey = active;
    } else if (_tabs.isNotEmpty) {
      _activeKey = _tabs.first.key;
    }
    _resume = saved.hostOpen && _tabs.isNotEmpty;
    _saved = _snapshot().encode();
  }

  SavedTabs _snapshot() =>
      SavedTabs(tabs: List.of(_tabs), active: _activeKey, hostOpen: _hostAttached);

  void _persist() {
    final store = _store;
    if (store == null || !_loaded) return;
    final snapshot = _snapshot();
    final encoded = snapshot.encode();
    if (encoded == _saved) return;
    _saved = encoded;
    unawaited(_write(store, snapshot));
  }

  // A phone that cannot write its preferences still shows its tabs.
  Future<void> _write(OpenTabsStore store, SavedTabs snapshot) async {
    try {
      await store.write(snapshot);
    } on Object {
      // Kept in memory; the next change tries again.
      _saved = null;
    }
  }

  @override
  void notifyListeners() {
    super.notifyListeners();
    _persist();
  }

  List<TabRef> get tabs => List.unmodifiable(_tabs);
  int get length => _tabs.length;
  bool get isEmpty => _tabs.isEmpty;
  String? get activeKey => _activeKey;

  TabRef? get active {
    final key = _activeKey;
    if (key == null) return null;
    for (final t in _tabs) {
      if (t.key == key) return t;
    }
    return null;
  }

  int indexOfKey(String key) => _tabs.indexWhere((t) => t.key == key);

  bool contains(String key) => indexOfKey(key) >= 0;

  /// A background tab changed (needs you, finished) since it was last shown.
  bool hasAttention(String key) => _attention.contains(key);

  /// Open tabs that want the user.
  int get attentionCount => _attention.length;

  /// Adds the tab (right after the active one) unless it is open, and makes it
  /// the active one. With [byRecency] the tabs are first sorted most recently
  /// used first, for a tab screen being entered afresh.
  void open(String machineId, String paneId, {bool byRecency = false}) {
    final ref = TabRef(machineId, paneId);
    final before = _tabs.length;
    final changed = byRecency || !contains(ref.key) || ref.key != _activeKey;
    if (!contains(ref.key)) {
      final at = _activeKey == null ? -1 : indexOfKey(_activeKey!);
      _tabs.insert(at + 1, ref);
    }
    _activate(ref.key);
    if (byRecency) _sortByRecency();
    _evict();
    if (changed || _tabs.length != before) notifyListeners();
  }

  /// Makes an open tab the active one.
  void activate(String key) {
    if (!contains(key) || key == _activeKey) return;
    _activate(key);
    notifyListeners();
  }

  /// Activates the neighbour [delta] tabs away (clamped, no wrap-around).
  /// Returns whether the active tab changed.
  bool step(int delta) {
    final key = _activeKey;
    if (key == null) return false;
    final to = (indexOfKey(key) + delta).clamp(0, _tabs.length - 1);
    if (_tabs[to].key == key) return false;
    activate(_tabs[to].key);
    return true;
  }

  /// Closes a tab. The active one hands over to the tab that slides into its
  /// place (the right neighbour, else the left).
  void close(String key) {
    final i = indexOfKey(key);
    if (i < 0) return;
    _tabs.removeAt(i);
    _forget(key);
    if (key == _activeKey) {
      _activeKey = null;
      if (_tabs.isNotEmpty) _activate(_tabs[i.clamp(0, _tabs.length - 1)].key);
    }
    notifyListeners();
  }

  /// Closes every tab but [key], which becomes the active one.
  void closeOthers(String key) {
    if (!contains(key)) return;
    _removeWhere((t) => t.key != key);
    _activate(key);
    notifyListeners();
  }

  /// Closes the tabs after [key].
  void closeToRight(String key) {
    final i = indexOfKey(key);
    if (i < 0 || i == _tabs.length - 1) return;
    final doomed = _tabs.sublist(i + 1).map((t) => t.key).toSet();
    _removeWhere((t) => doomed.contains(t.key));
    if (!contains(_activeKey ?? '')) _activate(key);
    notifyListeners();
  }

  void closeAll() {
    if (_tabs.isEmpty) return;
    _removeWhere((_) => true);
    _activeKey = null;
    notifyListeners();
  }

  /// Reports what [key]'s pane is doing now (null: gone). A background tab
  /// that starts needing the user, finishes, or goes from working to idle gets
  /// an attention mark until it is shown.
  void noteStatus(String key, AgentStatus? status) {
    if (!contains(key)) return;
    final had = _status.containsKey(key);
    final before = _status[key];
    _status[key] = status;
    if (!had || before == status || key == _activeKey) return;
    final wantsYou =
        status == AgentStatus.blocked ||
        status == AgentStatus.done ||
        (before == AgentStatus.working && status == AgentStatus.idle);
    if (wantsYou && _attention.add(key)) notifyListeners();
  }

  void _activate(String key) {
    _activeKey = key;
    _used[key] = ++_clock;
    _attention.remove(key);
  }

  void _sortByRecency() {
    // List.sort is not stable; tabs never used (all 0) keep their order.
    final order = {for (var i = 0; i < _tabs.length; i++) _tabs[i].key: i};
    _tabs.sort((a, b) {
      final byUse = (_used[b.key] ?? 0).compareTo(_used[a.key] ?? 0);
      return byUse != 0 ? byUse : order[a.key]!.compareTo(order[b.key]!);
    });
  }

  void _evict() {
    while (_tabs.length > maxTabs) {
      TabRef? oldest;
      for (final t in _tabs) {
        if (t.key == _activeKey) continue;
        if (oldest == null || (_used[t.key] ?? 0) < (_used[oldest.key] ?? 0)) {
          oldest = t;
        }
      }
      if (oldest == null) return;
      _tabs.remove(oldest);
      _forget(oldest.key);
    }
  }

  void _removeWhere(bool Function(TabRef) test) {
    final gone = [
      for (final t in _tabs)
        if (test(t)) t.key,
    ];
    _tabs.removeWhere(test);
    gone.forEach(_forget);
  }

  void _forget(String key) {
    _used.remove(key);
    _status.remove(key);
    _attention.remove(key);
  }
}
