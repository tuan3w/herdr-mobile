import 'dart:async';
import 'dart:collection';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../decision/plain_text.dart' as plain show stripAnsi;
import '../models/herdr_models.dart';
import '../models/pane_preview.dart';
import '../services/herdr_api.dart';
import '../services/herdr_transport.dart' show HerdrApiException;
import 'machine_connection.dart';
import 'prompt_detector.dart';

/// A claim on one pane's live preview. [release] it exactly when the card or
/// tab showing it goes away; reads stop with the last release.
abstract interface class PreviewHandle {
  /// Null until the first read lands (or the machine is unreachable and
  /// nothing was ever read).
  ValueListenable<PanePreview?> get preview;

  void release();
}

/// Live previews (the last few terminal rows, plus the question a blocked
/// agent is waiting on) for the panes currently on screen.
///
///  * **Ref-counted**: reads exist only while at least one [PreviewHandle]
///    for the pane is open; nothing is read for offline or off-screen agents.
///  * **Event driven**: one read when the first watcher appears, then one per
///    `pane_updated` for the pane, **throttled** (never debounced; busy
///    agents emit continuously) to one read per [minInterval]. A pane whose
///    last reads showed no change backs off further. A slow [safetyPoll] per
///    machine catches a missed event.
///  * **Staggered**: per machine at most [maxConcurrentReads] reads in
///    flight, started [startGap] apart, so 20 cards appearing at once do not
///    fire 20 requests at once.
///  * **Paused** while the app is in the background or the machine is not
///    online, and resumed with an immediate refresh.
///  * **Quiet**: listeners are notified only when the rows or the prompt
///    really changed.
///  * **Bounded**: previews of released panes live on in a small LRU so a
///    card scrolled back into view is not blank.
class PanePreviews {
  PanePreviews({
    required this._changes,
    required this._connection,
    this.minInterval = const Duration(milliseconds: 1500),
    this.safetyPoll = const Duration(seconds: 20),
    this.startGap = const Duration(milliseconds: 40),
    this.maxConcurrentReads = 2,
    this.readLines = 24,
    this.keepRows = 8,
    this.maxLineLength = 160,
    this.retainReleased = 24,
    this._clock = DateTime.now,
  }) {
    _changes.addListener(_onChanges);
  }

  final Listenable _changes;
  final MachineConnection? Function(String machineId) _connection;
  final DateTime Function() _clock;

  /// Minimum time between two reads of the same pane.
  final Duration minInterval;

  /// Re-read every watched pane of a machine this often, events or not.
  final Duration safetyPoll;

  /// Spacing of read starts on one machine.
  final Duration startGap;

  /// Reads in flight at once on one machine.
  final int maxConcurrentReads;

  /// Terminal rows requested per read (blank rows are dropped afterwards).
  final int readLines;

  /// Rows kept in a [PanePreview].
  final int keepRows;

  /// Longer rows are cut (memory bound; the UI ellipsizes anyway).
  final int maxLineLength;

  /// Previews of released panes kept for a quick return.
  final int retainReleased;

  final Map<String, _MachineWatch> _machines = {};
  final LinkedHashMap<String, _Retained> _retained = LinkedHashMap();
  bool _foreground = true;
  bool _disposed = false;

  /// Starts (or joins) watching [paneId] on [machineId].
  PreviewHandle watch(String machineId, String paneId) {
    assert(!_disposed, 'PanePreviews used after dispose');
    final machine = _machines[machineId] ??= _MachineWatch(this, machineId);
    return machine.watch(paneId);
  }

  /// The question [paneId] asks right now, read from its screen on [machine]'s
  /// connection past the throttle (one round trip): what an answer is checked
  /// against just before it is sent. The read is also shown to whoever watches
  /// the pane, so a question that changed is on screen at once. Null when the
  /// machine does not report the pane as blocked or the screen shows no
  /// question the app understands; throws what the read throws.
  Future<PromptInfo?> recheck(MachineConnection machine, String paneId) async {
    final watch = _machines[machine.profile.id]?.panes[paneId];
    final seq = watch?.startRead();
    final read = await machine.api.readPane(paneId, lines: readLines);
    final rows = previewRows(read.text, maxLength: maxLineLength, keep: readLines);
    if (watch != null && !watch.disposed) watch.offer(rows, seq!);
    if (machine.paneById(paneId)?.status != AgentStatus.blocked) return null;
    return detectPrompt(rows);
  }

  /// Feed the app lifecycle: `hidden`/`paused` stop all reads, `resumed`
  /// refreshes everything watched. `inactive` (a shade pulled down) is
  /// transient and ignored, as in the fleet.
  void onLifecycleState(AppLifecycleState state) {
    final foreground = switch (state) {
      AppLifecycleState.hidden || AppLifecycleState.paused => false,
      AppLifecycleState.resumed => true,
      _ => _foreground,
    };
    if (foreground == _foreground || _disposed) return;
    _foreground = foreground;
    for (final m in _machines.values.toList()) {
      m.sync();
    }
  }

  /// Panes with an open handle (tests, diagnostics).
  @visibleForTesting
  int get watchedPanes => _machines.values.fold(0, (n, m) => n + m.panes.length);

  @visibleForTesting
  int get retainedPanes => _retained.length;

  void _onChanges() {
    for (final m in _machines.values.toList()) {
      m.sync();
    }
  }

  void dispose() {
    _disposed = true;
    _changes.removeListener(_onChanges);
    for (final m in _machines.values.toList()) {
      m.close();
    }
    _machines.clear();
    _retained.clear();
  }

  void _retain(String key, PanePreview? preview, DateTime lastRead) {
    _retained.remove(key);
    _retained[key] = _Retained(preview, lastRead);
    while (_retained.length > retainReleased) {
      _retained.remove(_retained.keys.first);
    }
  }
}

class _Retained {
  const _Retained(this.preview, this.lastRead);
  final PanePreview? preview;
  final DateTime lastRead;
}

/// Everything watched on one machine: the read queue, the event
/// subscription and the safety poll.
class _MachineWatch {
  _MachineWatch(this.owner, this.id);

  final PanePreviews owner;
  final String id;
  final Map<String, _PaneWatch> panes = {};

  MachineConnection? _conn;
  StreamSubscription<String>? _activitySub;
  Timer? _poll;
  Timer? _gap;
  final Queue<_PaneWatch> _queue = Queue();
  int _running = 0;
  bool _active = false;
  bool _closed = false;

  PreviewHandle watch(String paneId) {
    final w = panes[paneId] ??= _PaneWatch(this, paneId);
    w.refs++;
    if (w.refs == 1) {
      final kept = owner._retained.remove('$id\u0000$paneId');
      if (kept != null) {
        w.notifier.value = kept.preview;
        // A pane scrolled out and straight back in must not defeat the
        // throttle: its previous read still counts.
        final since = owner._clock().difference(kept.lastRead);
        if (since < owner.minInterval) w.holdFloor(owner.minInterval - since);
      }
      sync();
      if (!w.requested) w.request(urgent: true);
    }
    return _Handle(w);
  }

  void release(_PaneWatch w) {
    if (--w.refs > 0) return;
    w.dispose();
    panes.remove(w.paneId);
    owner._retain('$id\u0000${w.paneId}', w.notifier.value, w.lastReadAt);
    w.notifier.dispose();
    if (panes.isEmpty) {
      close();
      if (identical(owner._machines[id], this)) owner._machines.remove(id);
    }
  }

  /// Reconciles with the world: connection identity, link state, app
  /// lifecycle, and the status of each watched pane.
  void sync() {
    if (_closed) return;
    final conn = owner._connection(id);
    if (!identical(conn, _conn)) {
      unawaited(_activitySub?.cancel());
      _activitySub = conn?.paneActivity.listen(_onActivity);
      _conn = conn;
    }
    final active = conn != null && conn.isLive && owner._foreground;
    final statuses = <String, AgentStatus>{
      if (conn != null)
        for (final p in conn.snapshot.panes) p.id: p.status,
    };
    final resumed = active && !_active;
    _active = active;
    if (!active) {
      _poll?.cancel();
      _poll = null;
      _gap?.cancel();
      _gap = null;
      for (final w in _queue) {
        w.queued = false;
      }
      _queue.clear();
    } else {
      _poll ??= Timer.periodic(owner.safetyPoll, (_) {
        for (final w in panes.values.toList()) {
          w.request();
        }
      });
    }
    for (final w in panes.values.toList()) {
      w.onSnapshot(statuses[w.paneId]);
      if (resumed) w.request(urgent: true);
    }
  }

  void _onActivity(String paneId) => panes[paneId]?.request();

  // ---- read queue (staggered, bounded concurrency)

  void enqueue(_PaneWatch w) {
    if (w.queued) return;
    w.queued = true;
    _queue.add(w);
    _kick();
  }

  void _kick() {
    if (!_active || _gap != null || _running >= owner.maxConcurrentReads) return;
    _PaneWatch? next;
    while (_queue.isNotEmpty) {
      final w = _queue.removeFirst();
      if (w.queued && !w.disposed) {
        next = w;
        break;
      }
    }
    if (next == null) return;
    _running++;
    // A microtask later, so every request made in this turn (a new watcher
    // asks for a read in several ways) collapses into this one read.
    final w = next;
    unawaited(Future<void>.microtask(w.read).whenComplete(() {
      _running--;
      _kick();
    }));
    // Space out the starts; a lone watcher pays nothing for this.
    _gap = Timer(owner.startGap, () {
      _gap = null;
      _kick();
    });
  }

  void close() {
    _closed = true;
    _poll?.cancel();
    _gap?.cancel();
    unawaited(_activitySub?.cancel());
    for (final w in panes.values.toList()) {
      w.dispose();
      w.notifier.dispose();
    }
    panes.clear();
    _queue.clear();
  }
}

class _PaneWatch {
  _PaneWatch(this.machine, this.paneId);

  final _MachineWatch machine;
  final String paneId;
  final ValueNotifier<PanePreview?> notifier = ValueNotifier(null);

  int refs = 0;
  bool disposed = false;

  // Scheduling state.
  bool dirty = false;

  /// A read was ever asked for (the initial one included).
  bool requested = false;
  bool urgent = false;
  bool queued = false;
  bool inFlight = false;
  bool gone = false;
  Timer? _floor;
  Timer? _extra;
  int unchangedStreak = 0;
  DateTime lastReadAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Content state.
  AgentStatus? status;
  List<String> rows = const [];
  bool hasRows = false;

  /// Reads started ([startRead]) and the newest one shown: a read that lands
  /// after a newer one is older news and is dropped.
  int _started = 0;
  int _shown = 0;

  PanePreviews get _owner => machine.owner;

  /// Asks for a read as soon as the throttle allows. [urgent] also skips the
  /// quiet-pane backoff (never the [PanePreviews.minInterval] floor).
  void request({bool urgent = false}) {
    if (disposed) return;
    dirty = true;
    requested = true;
    if (urgent) this.urgent = true;
    _pump();
  }

  void _pump() {
    if (disposed || !dirty || queued || inFlight || gone || !machine._active) return;
    if (_floor != null) return;
    if (_extra != null && !urgent) return;
    machine.enqueue(this);
  }

  void holdFloor(Duration d) {
    _floor?.cancel();
    _floor = Timer(d, () {
      _floor = null;
      _pump();
    });
  }

  /// Numbers a read, so its result can be ordered against the others.
  int startRead() => ++_started;

  Future<void> read() async {
    if (disposed) return;
    queued = false;
    dirty = false;
    urgent = false;
    inFlight = true;
    lastReadAt = _owner._clock();
    holdFloor(_owner.minInterval);
    _extra?.cancel();
    _extra = null;
    final conn = machine._conn;
    final seq = startRead();
    try {
      if (conn == null) return;
      final result = await conn.api.readPane(paneId, lines: _owner.readLines);
      if (disposed) return;
      _apply(result.text, seq);
      gone = false;
    } on HerdrApiException catch (e) {
      if (e.isNotFound) gone = true;
      _quiet();
    } on Object {
      // Transport trouble: keep what we have; the link state / next event
      // drives the retry.
      _quiet();
    } finally {
      inFlight = false;
      if (!disposed) _pump();
    }
  }

  /// Back off when the last reads showed nothing new: a pane that emits
  /// events (title churn, cursor) without changing text needs fewer reads.
  void _quiet() {
    unchangedStreak++;
    if (disposed) return;
    // 3 s between reads after one unchanged read, 6 s after more.
    final extra = unchangedStreak == 1
        ? _owner.minInterval * 2
        : _owner.minInterval * 4;
    _extra?.cancel();
    _extra = Timer(extra, () {
      _extra = null;
      _pump();
    });
  }

  void _apply(String text, int seq) {
    if (seq < _shown) return;
    _shown = seq;
    rows = previewRows(text, maxLength: _owner.maxLineLength, keep: _owner.readLines);
    hasRows = true;
    if (_publish()) {
      unchangedStreak = 0;
    } else {
      _quiet();
    }
  }

  /// Rows read outside the schedule ([PanePreviews.recheck]), numbered by
  /// [startRead]: shown unless a newer read already is.
  void offer(List<String> fresh, int seq) {
    if (seq < _shown) return;
    _shown = seq;
    rows = fresh;
    hasRows = true;
    if (_publish()) unchangedStreak = 0;
  }

  /// A status change: a new prompt may be on screen (read now), or the one
  /// we show may be answered (drop it without waiting for a read).
  void onSnapshot(AgentStatus? now) {
    if (now == null) return; // pane closed, or the machine has no data yet
    final before = status;
    if (now == before) {
      if (gone) {
        gone = false;
        request(urgent: true);
      }
      return;
    }
    status = now;
    if (before != null || notifier.value == null) request(urgent: true);
    if (hasRows) _publish();
  }

  /// Rebuilds the preview from [rows] and [status]; false if nothing
  /// visible changed.
  bool _publish() {
    // The card shows what the agent has been doing, not its own input box and
    // status bar; the prompt is still read from every row.
    final content = withoutAgentChrome(rows, blocked: status == AgentStatus.blocked);
    final shown = content.length > _owner.keepRows
        ? content.sublist(content.length - _owner.keepRows)
        : content;
    final next = PanePreview(
      lines: [for (final r in shown) PreviewLine(r)],
      prompt: status == AgentStatus.blocked ? detectPrompt(rows) : null,
      updatedAt: _owner._clock(),
    );
    final old = notifier.value;
    if (old != null && old.sameContent(next)) return false;
    notifier.value = next;
    return true;
  }

  void dispose() {
    disposed = true;
    queued = false;
    _floor?.cancel();
    _extra?.cancel();
    _floor = _extra = null;
  }
}

class _Handle implements PreviewHandle {
  _Handle(this._watch);

  final _PaneWatch _watch;
  bool _released = false;

  @override
  ValueListenable<PanePreview?> get preview => _watch.notifier;

  @override
  void release() {
    if (_released) return;
    _released = true;
    if (!_watch.disposed) _watch.machine.release(_watch);
  }
}

// ------------------------------------------------------------------ parsing

final _control = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

/// Removes escape sequences ([plain.stripAnsi], the one stripper) and the
/// control characters it leaves (the ESC of a sequence that did not complete).
String stripAnsi(String s) {
  final t = plain.stripAnsi(s);
  return t.contains(_control) ? t.replaceAll(_control, '') : t;
}

/// The rows of a `pane.read` shown in a preview: ANSI stripped, carriage
/// returns resolved (a progress bar shows its last state), box side bars and
/// rule-only rows dropped, trailing spaces trimmed, blank rows removed, rows
/// cut at [maxLength] characters. At most [keep] rows, oldest first.
List<String> previewRows(String text, {int maxLength = 160, int keep = 12}) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    var line = stripAnsi(raw).replaceAll('\t', '    ');
    final cr = line.trimRight().lastIndexOf('\r');
    if (cr >= 0) line = line.substring(cr + 1);
    final cleaned = cleanPreviewRow(line);
    if (cleaned == null) continue;
    out.add(cleaned.length > maxLength ? _cut(cleaned, maxLength) : cleaned);
  }
  return out.length > keep ? out.sublist(out.length - keep) : out;
}

/// Most rows [withoutAgentChrome] takes off the bottom: an input box with
/// its borders, a status bar, a hint line.
const _maxChromeRows = 8;

// An empty prompt: `>`, `❯`, `›`, `$`.
final _bareInput = RegExp(r'^\s*[>❯›»$%#]\s*$');

// A prompt with the text the person is typing, or the box's placeholder
// (`> Try "fix lint errors"`). A numbered row is a menu, not an input.
final _draftInput = RegExp(r'^\s*[>❯›»]\s+\S');
final _numberedRow = RegExp(r'^\s*[>❯›▶▸➤→]?\s*\d{1,2}[.)]\s');

// The status bars and hints the agent CLIs draw under their input box.
final _statusChrome = RegExp(
  r'(\besc(?:ape)? to\b|\benter to\b|\? for shortcuts|\bctrl\+\w|shift\+tab|\btab to\b|'
  r'bypass permissions|accept edits|plan mode|auto-?compact|\bcontext (?:left|window)\b|'
  r'\b\d+(?:\.\d+)?%\s+(?:context|left|used|full)|\b\d+(?:\.\d+)?[kKmM]?\s+tokens\b|'
  r'📁|⎇|\b(?:Opus|Sonnet|Haiku|GPT-?\d|gpt-?\d|Gemini)\b.*[>·|│]|'
  r'^\s*[·•]?\s*\d+[smh]\b.*[>·|│])',
  caseSensitive: false,
);

/// [rows] without the agent's own chrome at the bottom: the input box, the
/// status bar and hint lines that every agent CLI keeps drawing under its
/// output, so a preview ends with what the agent said or did. A draft or
/// placeholder in the input is dropped too, except for a [blocked] agent,
/// whose last rows may be the menu it waits on. Rows are only taken off the
/// end; when nothing else is left they are all kept.
@visibleForTesting
List<String> withoutAgentChrome(List<String> rows, {required bool blocked}) {
  var end = rows.length;
  while (end > 0 && rows.length - end < _maxChromeRows) {
    final row = rows[end - 1];
    final chrome =
        _bareInput.hasMatch(row) ||
        _statusChrome.hasMatch(row) ||
        (!blocked && _draftInput.hasMatch(row) && !_numberedRow.hasMatch(row));
    if (!chrome) break;
    end--;
  }
  return end == 0 ? rows : rows.sublist(0, end);
}

/// [s] cut to [max] UTF-16 units without leaving half a surrogate pair.
String _cut(String s, int max) {
  var end = max;
  if (end > 0 && (s.codeUnitAt(end - 1) & 0xFC00) == 0xD800) end--;
  return s.substring(0, end).trimRight();
}
