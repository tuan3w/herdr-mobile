import 'package:flutter/foundation.dart';

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

/// The agents the user has open as browser-style tabs: one list, one active
/// tab, in memory only.
///
/// The order is stable while the tab screen is in front: a new tab goes right
/// after the active one and switching never re-sorts. It is sorted by recency
/// only when the screen is entered afresh (`open(..., byRecency: true)`), so
/// the agent used last is the first tab the next time.
///
/// Closing a tab forgets it here; it never touches the agent.
class OpenTabs extends ChangeNotifier {
  OpenTabs({this.maxTabs = 12});

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
  /// Set by the screen itself; not a notification.
  bool hostAttached = false;

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
