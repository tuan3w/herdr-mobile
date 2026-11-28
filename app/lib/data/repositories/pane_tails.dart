import 'dart:async';
import 'dart:collection';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../models/herdr_models.dart';
import '../models/pane_preview.dart';
import '../services/herdr_api.dart' show ReadSource;
import 'agent_session.dart' show Preconnect;
import 'machine_connection.dart';

/// Rows of a pane's live tail: what the pane screen reads, and what is kept.
/// Cheap enough to read every 120 ms; a deeper read is made only while the
/// person reads back (`PaneViewModel`) and is never kept.
const paneTailRows = 300;

/// What the phone last read of a pane: the rows the pane screen paints on its
/// first frame, before its own read comes back.
@immutable
class PaneTail {
  const PaneTail({
    required this.text,
    required this.at,
    required this.unwrapped,
    this.truncated = false,
    this.preview = false,
  });

  /// The raw text (ANSI escapes included) of a [paneTailRows] read; for a
  /// [preview], the board card's rows, plain.
  final String text;

  /// When it was read (a preview: when its rows last changed). A floor on
  /// how fresh it is, never a claim that it is live.
  final DateTime at;

  /// Read as `recent_unwrapped` (the view wraps it) rather than `recent`.
  final bool unwrapped;

  /// herdr has older rows than the read returned.
  final bool truncated;

  /// Not a read of the tail but what the board's card shows of the pane: the
  /// last few rows, ANSI stripped, the agent's own input box and status bar
  /// taken off.
  final bool preview;

  /// What it costs to keep, in bytes (a Dart string is up to two per unit).
  int get bytes => text.length * 2;
}

/// A pane the board wants warm: a blocked agent's, on [machine].
typedef WarmTarget = ({MachineConnection machine, String paneId});

/// The last tail read of each of a few panes, kept in memory so that opening
/// one paints terminal text on the first frame, and the reads that make the
/// open feel instant.
///
///  * **Remembers** every successful tail read, whoever made it (the pane
///    screen's, a press, the board's warming): one entry per pane, the last
///    [maxPanes] panes and at most [maxBytes] in all, least recently read out
///    first. Dropped when its machine is removed or its pane is gone ([prune]).
///    A saved copy is never live: whoever paints it says so (`PaneViewModel`).
///  * **Adopts**: the pane screen reads through [read], which joins a read of
///    the same pane that is already on its way (a press went down ~100 ms
///    before the tap came up) instead of asking twice.
///  * **Starts at pointer-down** ([warm]): the tail's read, [warmAfter] after
///    the finger went down unless it has slid away by then (a scroll, a
///    swipe: the hold is let go, nothing is sent), and only while the app is
///    in front, the machine is live and the pane has not been read in the
///    last [touchEvery]. A press that turns into a slow scroll therefore
///    costs at most one read per card per [touchEvery]; a sent read cannot be
///    recalled, and its answer is kept either way.
///  * **Warms the likeliest next taps** ([board]): while the Agents board is
///    in front, the first [maxWarmed] blocked agents' tails are read when
///    they start to wait, when their question changes, and when the kept tail
///    is older than [staleAfter], never more than one read in flight per
///    machine for this, and never for an agent that is not blocked. Nothing is
///    read once the board is covered or the app leaves the front: the timer
///    goes and [warm] does nothing.
class PaneTails {
  PaneTails({
    required this._connection,
    required this._preview,
    this._clock = DateTime.now,
    this.maxPanes = 8,
    this.maxBytes = 1 << 20,
    this.maxWarmed = 2,
    this.touchEvery = const Duration(seconds: 5),
    this.staleAfter = const Duration(seconds: 30),
    this.warmGap = const Duration(seconds: 10),
    this.boardTick = const Duration(seconds: 15),
    this.adoptWithin = const Duration(seconds: 3),
    this.warmAfter = const Duration(milliseconds: 40),
    this.landedWithin = const Duration(milliseconds: 300),
  });

  final MachineConnection? Function(String machineId) _connection;

  /// What the board's card of a pane shows (`PanePreviews.known`).
  final PanePreview? Function(String machineId, String paneId) _preview;
  final DateTime Function() _clock;

  /// Panes kept, and the bytes of their text.
  final int maxPanes;
  final int maxBytes;

  /// Blocked agents the board warms.
  final int maxWarmed;

  /// A pane read less than this ago is not read again by a press.
  final Duration touchEvery;

  /// The kept tail of a warmed agent is read again after this long.
  final Duration staleAfter;

  /// Least time between two warming reads of one pane.
  final Duration warmGap;

  /// How often the board in front looks at who to warm.
  final Duration boardTick;

  /// A read on its way is joined by the pane screen for this long; an older
  /// one is left alone (it may be stuck behind a dying link).
  final Duration adoptWithin;

  /// A read that landed this recently is taken as the screen's first read
  /// (see [read]).
  final Duration landedWithin;

  /// How long a press waits before it reads: a scroll leaves the card's
  /// touch slop within about this long, and a tap lasts longer, so most
  /// scrolls cost nothing and a tap still has a head start.
  final Duration warmAfter;

  final LinkedHashMap<String, PaneTail> _tails = LinkedHashMap();
  int _bytes = 0;
  final Map<String, _Flight> _flights = {};
  final LinkedHashMap<String, DateTime> _started = LinkedHashMap();
  final Map<String, ({DateTime at, PromptInfo? prompt})> _warmed = {};

  bool _foreground = true;
  bool _disposed = false;
  bool _boardInFront = false;
  bool _boardWrap = false;
  List<WarmTarget> _targets = const [];
  Timer? _tick;

  /// The time of day the tails are dated by.
  DateTime Function() get clock => _clock;

  static String _key(String machineId, String paneId) => '$machineId\u0000$paneId';

  /// What to paint of [paneId] before its read comes back, or null: its kept
  /// tail when that was read the way [wrap] says, else what the board's card
  /// shows of it. Reads nothing and does not touch the least-recently-read
  /// order.
  PaneTail? seed(String machineId, String paneId, {required bool wrap}) {
    final kept = _tails[_key(machineId, paneId)];
    if (kept != null && kept.unwrapped == wrap) return kept;
    final preview = _preview(machineId, paneId);
    if (preview == null || preview.lines.isEmpty) return null;
    return PaneTail(
      text: [for (final l in preview.lines) l.text].join('\n'),
      at: preview.updatedAt,
      unwrapped: wrap,
      preview: true,
    );
  }

  /// `pane.read` of [lines] rows of [paneId] from [source], as the pane screen
  /// makes it. A read of the tail is remembered, and joins one that is
  /// already on its way for the same pane. With [first] (the screen's first
  /// read of this open) it also takes one that landed less than
  /// [landedWithin] ago, the press's own: the text is as fresh as two reads
  /// of the screen are apart, and the open costs one read, not two.
  Future<PaneRead> read(MachineConnection machine, String paneId, ReadSource source, int lines, {bool first = false}) {
    if (lines != paneTailRows || _disposed) return _fetch(machine, paneId, source, lines);
    final wrap = source == ReadSource.recentUnwrapped;
    final flight = _flights[_flightKey(machine.profile.id, paneId, wrap)];
    if (flight != null && _clock().difference(flight.at) < adoptWithin) return flight.future;
    final kept = _tails[_key(machine.profile.id, paneId)];
    if (first && kept != null && kept.unwrapped == wrap && _clock().difference(kept.at) < landedWithin) {
      return Future.value(PaneRead(text: kept.text, truncated: kept.truncated));
    }
    return _begin(machine, paneId, wrap).future;
  }

  /// A finger went down on [paneId]'s card: after [warmAfter] its tail is
  /// read, and the screen the tap opens joins that read (see the class
  /// comment for when nothing is read). The hold is cancelled when the finger
  /// leaves; handed to the screen it opens, which lets go once it has its
  /// own read.
  Preconnect warm(MachineConnection machine, String paneId, {required bool wrap}) {
    if (!_reachable(machine, paneId)) return Preconnect.none;
    return _Press(warmAfter, () => _warmNow(machine, paneId, wrap));
  }

  void _warmNow(MachineConnection machine, String paneId, bool wrap) {
    if (!_reachable(machine, paneId)) return;
    final id = machine.profile.id;
    if (_flights.containsKey(_flightKey(id, paneId, wrap))) return;
    final started = _started[_key(id, paneId)];
    if (started != null && _clock().difference(started) < touchEvery) return;
    // Two on one machine are what a finger can ask for; a third waits.
    if (_flightsOn(id) >= 2) return;
    _sink(_begin(machine, paneId, wrap));
  }

  /// The board's report: whether it is in front, and the agents that wait on
  /// the person ([targets], in board order; the first [maxWarmed] count),
  /// read as [wrap] says. Called on every build of the board, so it is cheap
  /// and idempotent.
  void board({required bool inFront, List<WarmTarget> targets = const [], bool wrap = false}) {
    if (_disposed) return;
    _boardInFront = inFront;
    _boardWrap = wrap;
    _targets = inFront ? targets.take(maxWarmed).toList() : const [];
    _syncBoard();
  }

  /// Feed the app lifecycle, as [PanePreviews.onLifecycleState] gets it.
  void onLifecycleState(AppLifecycleState state) {
    final foreground = switch (state) {
      AppLifecycleState.hidden || AppLifecycleState.paused => false,
      AppLifecycleState.resumed => true,
      _ => _foreground,
    };
    if (foreground == _foreground || _disposed) return;
    _foreground = foreground;
    _syncBoard();
  }

  /// Forgets the panes of machines that were removed and of panes herdr no
  /// longer lists (asked after the fleet changed).
  void prune() {
    for (final key in _tails.keys.toList()) {
      final (machineId, paneId) = _split(key);
      final machine = _connection(machineId);
      if (machine == null || (machine.isLive && machine.paneById(paneId) == null)) {
        _bytes -= _tails.remove(key)!.bytes;
        _warmed.remove(key);
      }
    }
    _warmed.removeWhere((key, _) {
      final (machineId, paneId) = _split(key);
      final machine = _connection(machineId);
      return machine == null || (machine.isLive && machine.paneById(paneId) == null);
    });
    _started.removeWhere((key, _) => _connection(_split(key).$1) == null);
  }

  void dispose() {
    _disposed = true;
    _tick?.cancel();
    _tick = null;
    _tails.clear();
    _flights.clear();
    _started.clear();
    _warmed.clear();
    _targets = const [];
    _bytes = 0;
  }

  /// Panes kept (tests, diagnostics).
  @visibleForTesting
  int get keptPanes => _tails.length;

  @visibleForTesting
  int get keptBytes => _bytes;

  /// Whether the board's timer is running: it is only while the board is in
  /// front, the app is too, and some blocked agent is to be warmed.
  @visibleForTesting
  bool get ticking => _tick != null;

  // ---- reads

  static (String, String) _split(String key) {
    final at = key.indexOf('\u0000');
    return (key.substring(0, at), key.substring(at + 1));
  }

  static String _flightKey(String machineId, String paneId, bool wrap) => '$machineId\u0000$paneId\u0000$wrap';

  int _flightsOn(String machineId) => _flights.values.where((f) => f.machineId == machineId).length;

  bool _reachable(MachineConnection machine, String paneId) =>
      !_disposed && _foreground && machine.isLive && machine.paneById(paneId) != null;

  Future<PaneRead> _fetch(MachineConnection machine, String paneId, ReadSource source, int lines) =>
      machine.api.readPane(paneId, source: source, lines: lines, ansi: true);

  _Flight _begin(MachineConnection machine, String paneId, bool wrap) {
    final id = machine.profile.id;
    final key = _flightKey(id, paneId, wrap);
    final flight = _Flight(id, _clock());
    _flights[key] = flight;
    _started.remove(_key(id, paneId));
    _started[_key(id, paneId)] = flight.at;
    while (_started.length > 64) {
      _started.remove(_started.keys.first);
    }
    flight.future = _fetch(machine, paneId, wrap ? ReadSource.recentUnwrapped : ReadSource.recent, paneTailRows)
        .then((read) {
          _keep(id, paneId, read, wrap);
          return read;
        })
        .whenComplete(() {
          if (identical(_flights[key], flight)) _flights.remove(key);
        });
    return flight;
  }

  /// A read nobody awaits must not report its failure as unhandled: whoever
  /// opens the pane reads again and says what went wrong.
  void _sink(_Flight flight) {
    unawaited(flight.future.then<void>((_) {}, onError: (Object _) {}));
  }

  void _keep(String machineId, String paneId, PaneRead read, bool wrap) {
    if (_disposed) return;
    final key = _key(machineId, paneId);
    final old = _tails.remove(key);
    if (old != null) _bytes -= old.bytes;
    final tail = PaneTail(text: read.text, at: _clock(), unwrapped: wrap, truncated: read.truncated);
    // A tail that alone is over the budget is not worth keeping.
    if (tail.bytes > maxBytes) return;
    _tails[key] = tail;
    _bytes += tail.bytes;
    while (_tails.length > maxPanes || _bytes > maxBytes) {
      final oldest = _tails.keys.first;
      _bytes -= _tails.remove(oldest)!.bytes;
    }
  }

  // ---- the board

  void _syncBoard() {
    final on = _foreground && _boardInFront && _targets.isNotEmpty;
    if (!on) {
      _tick?.cancel();
      _tick = null;
      return;
    }
    _tick ??= Timer.periodic(boardTick, (_) => _warmTargets());
    _warmTargets();
  }

  void _warmTargets() {
    if (_disposed || !_foreground || !_boardInFront) return;
    final now = _clock();
    _warmed.removeWhere((key, _) => !_targets.any((t) => _key(t.machine.profile.id, t.paneId) == key));
    for (final t in _targets) {
      final machine = t.machine;
      final id = machine.profile.id;
      if (!_reachable(machine, t.paneId) || machine.paneById(t.paneId)?.status != AgentStatus.blocked) continue;
      // One in flight per machine for this: speculation never queues up.
      if (_flightsOn(id) > 0) continue;
      final key = _key(id, t.paneId);
      final prompt = _preview(id, t.paneId)?.prompt;
      final before = _warmed[key];
      if (before != null && now.difference(before.at) < warmGap) continue;
      final kept = _tails[key];
      final fresh = kept != null && kept.unwrapped == _boardWrap && now.difference(kept.at) < staleAfter;
      final asksSomethingElse = before != null && before.prompt != prompt;
      if (fresh && !asksSomethingElse) continue;
      _warmed[key] = (at: now, prompt: prompt);
      final flight = _begin(machine, t.paneId, _boardWrap);
      _sink(flight);
      // The next agent on this machine, once this read is done.
      unawaited(flight.future.then<void>((_) => _warmTargets(), onError: (Object _) {}));
    }
  }
}

/// A read of a pane's tail on its way.
class _Flight {
  _Flight(this.machineId, this.at);

  final String machineId;
  final DateTime at;
  late final Future<PaneRead> future;
}

/// A finger on a card ([PaneTails.warm]): reads when [after] has passed,
/// unless it was let go first.
class _Press implements Preconnect {
  _Press(Duration after, void Function() read) {
    _timer = Timer(after, () {
      _timer = null;
      read();
    });
  }

  Timer? _timer;

  @override
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
