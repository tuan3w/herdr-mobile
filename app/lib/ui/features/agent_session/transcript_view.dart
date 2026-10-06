import 'dart:math' as math;

import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/turns/turns.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/app_settings.dart';
import '../../../data/repositories/last_seen.dart' show SinceLeft;
import '../../core/markdown/markdown.dart';
import '../../core/motion.dart';
import '../../core/theme.dart';
import 'agent_md_scope.dart';
import 'content_copy.dart' show ContentSelectionArea;
import 'changed_card.dart';
import 'jump_to_latest.dart';
import 'live_message_model.dart';
import 'live_message_row.dart';
import 'plan_header.dart' show planDoneNote;
import 'plan_warmup.dart';
import 'session_select.dart' show notifyRegionBuilt;
import 'since_divider.dart';
import 'status_line.dart';
import 'subagent_card.dart' show toolOrSubagentRow;
import 'subagent_format.dart' show attentionToolIds;
import 'transcript_plan.dart';
import 'transcript_rows.dart';
import 'work_log_rows.dart';

/// Rows in the newer slivers when the view opens, or opens again at the
/// tail. Past three times this, a view that follows the end starts them over.
const _window = 40;

/// How far from the end the list may be and still count as "at the end".
const _atEnd = 8.0;

/// Farther than this from the end shows the "Jump to latest" button.
const _awayFrom = 120.0;

/// The conversation as turns: a lazily built list of rows that follows the end
/// while the agent writes and leaves the reader alone once they scroll up.
///
/// **A turn** runs from one message of the person to the next
/// ([TranscriptPlan]): the message; the work log (reads, searches, thoughts,
/// narration, commands); the Changed card; the answer; and what breaks out of
/// the fold. A finished turn shows its log as one line (`Worked 42s · 3 files
/// · 1 failed`) that opens in place; the turn that runs shows it open, with the
/// status line ([StatusLine]) after the last row. The answer, the card and the
/// exceptions (a failed or cancelled call, a call that waits for the person, a
/// stop, a note) are never folded. The toggles (a fold, a group, the card's
/// full list, a tool's body) live here, in [_open], so they survive a row
/// scrolling out of the list and back.
///
/// **What rebuilds when.** The list is planned and rebuilt when `state.items`
/// is a new list, the turn starts or ends, or a call starts to wait for the
/// person: planned from the first turn that changed. The message that is
/// streaming in right now is not part of that churn: its text grows in a
/// `LiveText`, and its one row ([LiveMessageRow]) listens to it alone, so a
/// chunk rebuilds that row and nothing else, however many rows are above. The
/// keyboard moving only re-lays out the viewport. The rows are cached per key
/// and reused while their content is equal.
///
/// **Follow.** The end stays in view while the reader has not left it
/// ([_StickyPosition]); never while a finger is down; no animation. Away from
/// the end a button leads back, and says how many rows were finished since the
/// reader left (`N new`).
///
/// **Since you left** ([sinceLeft]). A hairline with `N new` stands above the
/// first thing the person has not seen. It is taken once, when it first
/// arrives, and never moves: later values are ignored, so it does not jump
/// under the reader. The view opens with it in sight: at the end when
/// everything after it fits on the screen, else with the divider near the top
/// and the reader away from the end (the button leads back). A divider that
/// arrives after the screen is open is placed, but the view does not move.
///
/// A fold that opens reveals its rows over `Motion.expand` (opacity and a few
/// pixels of slide, nothing else); one that closes just goes. The list
/// anchors to the rows in view, so a fold above them changing does not move
/// what the reader is looking at.
class TranscriptView extends StatefulWidget {
  const TranscriptView({super.key, required this.session, this.sinceLeft});

  final AgentSessionView session;

  /// What happened while the person was away; null shows no divider.
  final SinceLeft? sinceLeft;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _Built {
  const _Built(this.row, this.open, this.all, this.signature, this.widget);

  final PlanRow row;
  final bool open;
  final bool all;

  /// The live row only: which "Show all" toggles of the message are on.
  final int signature;
  final Widget widget;
}

bool _sameBlock(Object? a, Object? b) {
  if (identical(a, b)) return true;
  return a is MdBlock && b is MdBlock && mdBlocksEqual(a, b);
}

bool _sameList(List<Object?> a, List<Object?> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!identical(a[i], b[i])) return false;
  }
  return true;
}

/// Whether two rows of the same key draw the same thing.
bool _samePayload(PlanRow a, PlanRow b) {
  if (a.kind != b.kind || a.live != b.live || a.quiet != b.quiet || a.nested != b.nested) return false;
  if (a.first != b.first || a.last != b.last || a.count != b.count || a.label != b.label) return false;
  switch (a.kind) {
    case RowKind.text || RowKind.content:
      if (a.live) return identical(a.item, b.item);
      return _sameBlock(a.part, b.part);
    case RowKind.fold || RowKind.changedHead || RowKind.changedMore:
      return identical(a.turn, b.turn);
    case RowKind.changedFile:
      return identical(a.turn, b.turn) && identical(a.file, b.file);
    case RowKind.thinking:
      return _sameList(a.thoughts, b.thoughts);
    case RowKind.group:
      return _sameList(a.group!.tools, b.group!.tools);
    case RowKind.divider:
      return true;
    case RowKind.user || RowKind.tool || RowKind.stop || RowKind.note:
      return identical(a.item, b.item);
  }
}

/// The number of blocks of the live message that are frozen, for the "N new"
/// button. [set] does not notify (the owner is being built).
class _Count extends ChangeNotifier {
  int value = 0;

  void set(int next) => value = next;

  void report(int next) {
    if (next == value) return;
    value = next;
    notifyListeners();
  }
}

/// Toggles that change which rows exist.
bool _shapesPlan(String id) => id.endsWith(':log') || id.endsWith(':changed:all') || id.endsWith(':group');

class _TranscriptViewState extends State<TranscriptView> with TickerProviderStateMixin, WidgetsBindingObserver {
  late _StickyController _scroll;
  final _away = ValueNotifier<bool>(false);
  final _frozen = _Count();
  final _open = <String>{};
  final _notes = <String, String>{};
  final _built = <String, _Built>{};
  late List<TranscriptItem> _items = widget.session.state.items;
  late bool _live = widget.session.state.turnActive;
  late Set<String> _waiting = attentionToolIds(widget.session);
  late TranscriptPlan _plan = TranscriptPlan(open: _open, notes: _notes);

  /// The plan covers every item. A long transcript is planned from its last
  /// turns only at first (the first frame is the tail), and whole once the
  /// older turns are ready ([_warmup]) and the route has stopped moving.
  late bool _whole = _short(_items) || widget.sinceLeft != null;
  late final PlanWarmup _warmup = PlanWarmup(open: _open, notes: _notes);
  final _centerKey = const ValueKey('newer');
  int _center = 0;
  AppSettings? _settings;

  /// The since-left divider: taken once.
  String? _dividerKey;
  String _dividerLabel = 'New';

  /// The view opened with the divider at the top; it checks, after the first
  /// layout, that there is enough below it to fill the screen.
  bool _checkDividerOpen = false;

  /// The plan when the turn that runs began; null when the screen opened in
  /// the middle of it.
  List<PlanEntry>? _planBaseline;

  /// Rows that appear because a fold was opened: they are revealed once.
  final _entering = <String>{};

  /// What the screen shows of the message that is streaming in now; null
  /// when none is. Owned here, not by its row: the row is built lazily and
  /// goes when the reader scrolls away, the text keeps coming.
  LiveMessageModel? _model;
  bool _visible = true;
  bool _reducedMotion = false;

  /// Fingers on the transcript.
  int _fingers = 0;

  /// How many blocks were complete when the reader left the end.
  int _base = 0;

  List<PlanRow> get _rows => _plan.rows;

  @override
  void initState() {
    super.initState();
    _adoptDivider(widget.sinceLeft);
    _replan();
    _center = _tailStart();
    var follow = true;
    if (_plan.dividerRow >= 0) {
      _center = math.max(0, _plan.dividerRow - 1);
      follow = false;
      _checkDividerOpen = true;
    }
    _scroll = _StickyController(follow: follow);
    WidgetsBinding.instance.addObserver(this);
    widget.session.addListener(_onSession);
    _scroll.addListener(_updateAway);
    _syncLive();
    if (_checkDividerOpen) WidgetsBinding.instance.addPostFrameCallback((_) => _checkDividerFits());
    _planTheRest();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = context.read<AppSettings?>();
    if (!identical(settings, _settings)) {
      _settings?.removeListener(_applyPacing);
      _settings = settings;
      settings?.addListener(_applyPacing);
    }
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _visible = TickerMode.valuesOf(context).enabled;
    _applyPacing();
  }

  @override
  void didUpdateWidget(TranscriptView old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _built.clear();
      _open.clear();
      _notes.clear();
      _entering.clear();
      _dividerKey = null;
      _planBaseline = null;
      _items = widget.session.state.items;
      _live = widget.session.state.turnActive;
      _waiting = attentionToolIds(widget.session);
      _plan = TranscriptPlan(open: _open, notes: _notes);
      _warmup.cancel();
      _whole = _short(_items) || widget.sinceLeft != null;
      _adoptDivider(widget.sinceLeft);
      _replan();
      _syncLive();
      _center = _tailStart();
      _planTheRest();
    } else if (_dividerKey == null && _adoptDivider(widget.sinceLeft)) {
      // The divider arrived after the screen opened: it is placed, nothing moves.
      // Its turn must be planned: when it is older than the tail that was
      // planned for the first frame, the plan becomes whole now.
      if (!_whole && _indexOf(_items, _dividerKey!) < tailStart(_items, firstFrameTurns)) _makeWhole();
      _replan();
      _syncLive();
      _center = math.min(_center, _rows.length);
    }
  }

  @override
  void dispose() {
    _warmup.cancel();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    WidgetsBinding.instance.removeObserver(this);
    widget.session.removeListener(_onSession);
    _settings?.removeListener(_applyPacing);
    _model?.dispose();
    _scroll
      ..removeListener(_updateAway)
      ..dispose();
    _away.dispose();
    _frozen.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _model?.snap();
  }

  /// Takes the divider of [sinceLeft] when there is one and none was taken.
  bool _adoptDivider(SinceLeft? sinceLeft) {
    final key = sinceLeft?.firstUnseenKey;
    if (_dividerKey != null || sinceLeft == null || key == null) return false;
    _dividerKey = key;
    _dividerLabel = sinceLeft.steps > 0 ? '${sinceLeft.steps} new' : 'New';
    return true;
  }

  static bool _short(List<TranscriptItem> items) => items.length <= planWholeUpTo;

  static int _indexOf(List<TranscriptItem> items, String key) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].key == key) return i;
    }
    return -1;
  }

  /// The items the plan covers: all of them, or, until the older turns are
  /// ready, the last [firstFrameTurns] turns.
  List<TranscriptItem> get _planned {
    if (_whole) return _items;
    final from = tailStart(_items, firstFrameTurns);
    return from == 0 ? _items : _items.sublist(from);
  }

  Animation<double>? _routeAnimation;

  /// A long transcript was planned from its tail for the first frame: once
  /// the route has stopped moving, the turns before it are made ready a few
  /// milliseconds at a time ([PlanWarmup]), then the whole plan is made, which
  /// is cheap by then.
  void _planTheRest() {
    if (_whole) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _whole) return;
      final animation = _routeAnimation = ModalRoute.of(context)?.animation;
      if (animation == null || animation.status == AnimationStatus.completed) {
        _prepareOlder();
      } else {
        animation.addStatusListener(_onRouteStatus);
      }
    });
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed && status != AnimationStatus.dismissed) return;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    if (status == AnimationStatus.completed && mounted && !_whole) _prepareOlder();
  }

  void _prepareOlder() {
    final items = _items;
    _warmup.start(items, tailStart(items, firstFrameTurns), _waiting, () {
      // The history was replaced meanwhile: that preparation was for other
      // turns, and a new one has started.
      if (!mounted || _whole || items.isEmpty || _items.isEmpty || !identical(items.first, _items.first)) return;
      setState(_makeWhole);
    });
  }

  /// The plan covers every item from now on.
  void _makeWhole() {
    _warmup.cancel();
    _whole = true;
    _replan();
    _syncLive();
    if (_center > _rows.length) _center = _rows.length;
  }

  /// Plans the current items; forgets the cached rows that went.
  ///
  /// The newer slivers start at a row ([_center] is its index). Rows planned
  /// above it move that index, so it is looked up again by key: the list then
  /// keeps the same row at the same place, however many rows come or go above
  /// what the reader is looking at. (If the row itself went, the first of the
  /// next ones that is still there takes its place.)
  void _replan() {
    final heads = _center < _rows.length
        ? [for (var i = _center; i < math.min(_rows.length, _center + 24); i++) _rows[i].key]
        : const <String>[];
    for (final key in _plan.update(
      _planned,
      live: _live,
      waiting: _waiting,
      dividerKey: _dividerKey,
      dividerLabel: _dividerLabel,
    )) {
      _built.remove(key);
    }
    for (final key in heads) {
      final at = _plan.index[key];
      if (at != null) {
        _center = at;
        break;
      }
    }
    if (_center > _rows.length) _center = _rows.length;
  }

  /// Smooth text off, a hidden transcript (its tickers are muted: nothing
  /// would ever reveal a backlog) and reduced motion decide how the live
  /// message is paced.
  void _applyPacing() {
    final model = _model;
    if (model == null) return;
    final smooth = _visible && (_settings?.smoothText ?? true);
    model.reducedMotion = _reducedMotion;
    final was = model.smooth;
    model.smooth = smooth;
    if (was && !smooth) model.snap();
  }

  /// Makes the model follow the live message of the plan: one per live
  /// message, made when it first shows up (the text already there is history)
  /// and dropped when it ends.
  void _syncLive() {
    final i = _plan.liveRow;
    final live = i < 0 ? null : (_rows[i].item as TranscriptMessage).live;
    if (identical(live, _model?.live)) return;
    _model?.dispose();
    final model = _model = live == null ? null : LiveMessageModel(live: live, vsync: this, onFrozen: _frozen.report);
    _frozen.set(model?.frozenBlocks ?? 0);
    _applyPacing();
  }

  /// The plan the agent made folds into the summary of the turn it finished:
  /// remember where it stood when the turn began, and when the turn ends with
  /// every step done and the plan changed meanwhile, note it on that turn.
  void _trackPlan(AgentSessionState state) {
    if (state.turnActive) {
      _planBaseline = state.plan;
      return;
    }
    final baseline = _planBaseline;
    _planBaseline = null;
    if (baseline == null || identical(baseline, state.plan)) return;
    final note = planDoneNote(state.plan);
    final turns = turnsOf(state.items);
    if (note != null && turns.isNotEmpty) _notes[turns.last.key] = note;
  }

  /// The session notifies once per frame, text or not. Only a new item list,
  /// a turn that starts or ends and a call that starts waiting are work here:
  /// a chunk of the live message leaves them as they are.
  void _onSession() {
    final state = widget.session.state;
    final items = state.items;
    final live = state.turnActive;
    final waiting = attentionToolIds(widget.session);
    if (live != _live) _trackPlan(state);
    if (identical(items, _items) && live == _live && waiting.length == _waiting.length && waiting.containsAll(_waiting)) {
      return;
    }
    // The history itself was replaced by another copy of it (the replay took
    // over from a saved transcript): its older turns are new objects, and a
    // plan of all of them would cost this frame what it cost the first one. A
    // reader at the end sees only the tail, so that is planned, and the rest is
    // prepared in the background again. Items that only came at the end leave
    // the preparation as it is.
    final replaced = _items.isEmpty || items.isEmpty || !identical(items.first, _items.first);
    final demote = replaced && _whole && !_short(items) && _followingEnd;
    _items = items;
    _live = live;
    _waiting = waiting;
    if (demote) {
      _whole = false;
    }
    if (replaced && !_whole) {
      _warmup.cancel();
      _planTheRest();
    }
    _replan();
    _syncLive();
    setState(() {
      // Following the end while the newer slivers have grown long (a replay
      // arrived, or hours of output): start them again at the tail. The view
      // stays at the end, so nothing visibly moves.
      if (_rows.length - _center > _window * 3 && _followingEnd) _center = _tailStart();
      if (_center > _rows.length) _center = _rows.length;
    });
  }

  /// Blocks that can no longer change: every row but the live one, and the
  /// frozen blocks of that.
  int _completed() {
    final live = _plan.liveRow >= 0;
    return _rows.length - (live ? 1 : 0) + (live ? _frozen.value : 0);
  }

  int _newBlocks() => _completed() > _base ? _completed() - _base : 0;

  void _updateAway() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    final away = position.extentAfter > _awayFrom;
    if (away && !_away.value) _base = _completed();
    _away.value = away;
  }

  _StickyPosition? get _sticky {
    if (!_scroll.hasClients) return null;
    final position = _scroll.position;
    return position is _StickyPosition ? position : null;
  }

  /// The view opened with the divider at its top: when what follows the
  /// divider does not fill the screen, show the end instead (the divider is
  /// in sight there too).
  void _checkDividerFits() {
    _checkDividerOpen = false;
    final sticky = _sticky;
    if (!mounted || sticky == null || !sticky.hasContentDimensions) return;
    if (sticky.maxScrollExtent > 0.5) return;
    setState(() => _center = _tailStart());
    sticky.resumeFollow();
  }

  /// A finger went down: pending text is shown whole now, and the view does
  /// not move under it until the last finger is up.
  void _fingerDown(PointerDownEvent _) {
    _fingers++;
    _sticky?.holdFollow(true);
    _model?.snap();
  }

  void _fingerUp(PointerEvent _) {
    if (_fingers > 0 && --_fingers == 0) _sticky?.holdFollow(false);
  }

  void _toggle(String id) {
    // The person is looking at this row: keep it where it is instead of
    // following the end while it opens.
    _sticky?.pauseFollow();
    final opening = !_open.contains(id);
    if (!_shapesPlan(id)) {
      setState(() {
        if (!_open.remove(id)) _open.add(id);
      });
      return;
    }
    final before = opening ? Set<String>.of(_plan.index.keys) : const <String>{};
    _plan.refresh(id);
    if (!_open.remove(id)) _open.add(id);
    _replan();
    if (opening) {
      // The rows this fold brought are revealed; the others stay as they are.
      _entering
        ..clear()
        ..addAll(_plan.index.keys.where((k) => !before.contains(k)));
      for (final key in _entering) {
        _built.remove(key);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final key in _entering) {
          _built.remove(key);
        }
        _entering.clear();
      });
    }
    setState(() {
      if (_center > _rows.length) _center = _rows.length;
    });
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    if (_rows.length - _center > _window * 2) {
      // Far from the end of a long transcript: start the newer slivers at the
      // tail first, so the jump lays out a screenful, not every row between.
      setState(() => _center = _tailStart());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.position.jumpTo(_scroll.position.maxScrollExtent);
      });
      return;
    }
    _scroll.position.jumpTo(_scroll.position.maxScrollExtent);
  }

  /// Which "Show all" toggles of the message [messageKey] are on, as one
  /// number: the live row builds its frozen blocks once and needs to know
  /// when one of them changes.
  int _openSignature(String messageKey) {
    final prefix = '$messageKey#';
    var signature = 0;
    for (final id in _open) {
      if (id.startsWith(prefix)) signature ^= id.hashCode;
    }
    return signature;
  }

  Widget _make(PlanRow row, bool open, bool all) {
    final key = ValueKey(row.key);
    final item = row.item;
    if (row.live) {
      final message = item as TranscriptMessage;
      return LiveMessageRow(
        key: key,
        messageKey: message.key,
        model: _model!,
        gap: row.gap,
        before: row.before,
        firstBlock: row.firstBlock,
        open: _open,
        openSignature: _openSignature(message.key),
        onToggle: _toggle,
      );
    }
    final Widget child = switch (row.kind) {
      RowKind.user => UserRow(
        rowKey: row.key,
        message: item as TranscriptMessage,
        gap: row.gap,
        open: open,
        onToggle: _toggle,
        all: all,
      ),
      RowKind.fold => FoldRow(
        rowKey: row.key,
        turn: row.turn!,
        gap: row.gap,
        open: open,
        onToggle: _toggle,
        note: row.label,
      ),
      RowKind.thinking => ThinkingRow(
        rowKey: row.key,
        thoughts: row.thoughts,
        gap: row.gap,
        open: open,
        onToggle: _toggle,
      ),
      RowKind.tool => toolOrSubagentRow(
        session: widget.session,
        rowKey: row.key,
        item: item as TranscriptTool,
        gap: row.gap,
        open: open,
        all: all,
        onToggle: _toggle,
        nested: row.nested,
      ),
      RowKind.group => GroupRow(rowKey: row.key, group: row.group!, gap: row.gap, open: open, onToggle: _toggle),
      RowKind.text => AgentTextRow(
        rowKey: row.key,
        block: row.part as MdBlock,
        gap: row.gap,
        expanded: all,
        quiet: row.quiet,
        message: item as TranscriptMessage,
        onToggle: _toggle,
      ),
      RowKind.content => ContentRow(
        rowKey: row.key,
        block: row.part as ContentBlock,
        gap: row.gap,
        expanded: all,
        onToggle: _toggle,
      ),
      RowKind.changedHead => ChangedHeadRow(rowKey: row.key, turn: row.turn!, gap: row.gap),
      RowKind.changedFile => ChangedFileRow(
        rowKey: row.key,
        file: row.file!,
        last: row.last,
        open: open,
        all: all,
        onToggle: _toggle,
      ),
      RowKind.changedMore => ChangedMoreRow(rowKey: row.key, count: row.count, all: open, onToggle: _toggle),
      RowKind.divider => SinceDivider(rowKey: row.key, label: row.label ?? 'New', gap: row.gap),
      RowKind.stop => StopNoteRow(
        rowKey: row.key,
        reason: (item as TranscriptStop).reason,
        gap: row.gap,
      ),
      RowKind.note => NoteRow(rowKey: row.key, text: (item as TranscriptNote).text, gap: row.gap),
    };
    return _Reveal(key: key, animate: _entering.contains(row.key), reduced: _reducedMotion, child: child);
  }

  Widget _row(BuildContext context, int i) {
    final row = _rows[i];
    final open = _open.contains(row.key);
    final all = _open.contains(allKey(row.key));
    final signature = row.live ? _openSignature(row.item!.key) : 0;
    final have = _built[row.key];
    if (have != null &&
        have.open == open &&
        have.all == all &&
        have.signature == signature &&
        have.row.gap == row.gap &&
        _samePayload(have.row, row)) {
      return have.widget;
    }
    final widget = _make(row, open, all);
    _built[row.key] = _Built(row, open, all, signature, widget);
    return widget;
  }

  /// The first row of the newer slivers: the last [_window] rows, so that
  /// reaching the end lays out few rows however long the transcript is.
  int _tailStart() => _rows.length > _window ? _rows.length - _window : 0;

  /// Whether the view sits at the end (or is not on screen yet).
  bool get _followingEnd {
    if (!_scroll.hasClients) return true;
    final position = _scroll.position;
    return position is! _StickyPosition || position.following;
  }

  @override
  Widget build(BuildContext context) {
    notifyRegionBuilt('transcript');
    if (_rows.isEmpty) return const _EmptyTranscript();
    final center = _center;
    final index = _plan.index;
    return Stack(
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            _updateAway();
            return false;
          },
          child: AgentMdScope(
            session: widget.session,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _fingerDown,
              onPointerUp: _fingerUp,
              onPointerCancel: _fingerUp,
              child: ContentSelectionArea(
                // The rows from [_center] on grow downward from the origin; the
                // older ones grow upward from it, and are built only as they
                // scroll into view. The view starts at the end of the newer ones,
                // so opening a long transcript lays out a screenful, not all of it.
                child: CustomScrollView(
                  controller: _scroll,
                  center: _centerKey,
                  slivers: [
                    if (center > 0)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
                        sliver: SliverList(
                          delegate: SliverChildBuilderDelegate(
                            (context, j) => _row(context, center - 1 - j),
                            childCount: center,
                            findChildIndexCallback: (key) {
                              final at = key is ValueKey<String> ? index[key.value] : null;
                              return at == null || at >= center ? null : center - 1 - at;
                            },
                            addAutomaticKeepAlives: false,
                            addSemanticIndexes: false,
                          ),
                        ),
                      ),
                    SliverPadding(
                      key: _centerKey,
                      padding: EdgeInsets.fromLTRB(Gap.lg, center == 0 ? Gap.sm : 0, Gap.lg, 0),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, j) => _row(context, center + j),
                          childCount: _rows.length - center,
                          findChildIndexCallback: (key) {
                            final at = key is ValueKey<String> ? index[key.value] : null;
                            return at == null || at < center ? null : at - center;
                          },
                          addAutomaticKeepAlives: false,
                          addSemanticIndexes: false,
                        ),
                      ),
                    ),
                    // What the agent is doing right now, after the last row.
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
                      sliver: SliverToBoxAdapter(child: StatusLine(session: widget.session)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: Gap.md,
          bottom: Gap.md,
          child: ListenableBuilder(
            listenable: Listenable.merge([_away, _frozen]),
            builder: (context, _) => _away.value
                ? JumpToLatest(newBlocks: _newBlocks(), onPressed: _jumpToLatest)
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// Reveals the rows a fold brought: opacity from 0 and a slide of a few
/// pixels down into place over [Motion.expand] (transform and opacity, never
/// layout). A row that does not [animate], or under reduced motion, is drawn
/// at once, through the same widgets, so a row keeps its state when the flag
/// changes.
class _Reveal extends StatefulWidget {
  const _Reveal({super.key, required this.animate, required this.reduced, required this.child});

  final bool animate;
  final bool reduced;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double> _fade = const AlwaysStoppedAnimation(1);
  Animation<Offset> _slide = const AlwaysStoppedAnimation(Offset.zero);

  @override
  void initState() {
    super.initState();
    if (widget.animate && !widget.reduced) {
      final controller = _controller = AnimationController(vsync: this, duration: Motion.expand);
      final curve = CurvedAnimation(parent: controller, curve: Motion.easeOut);
      _fade = curve;
      _slide = Tween(begin: const Offset(0, -0.12), end: Offset.zero).animate(curve);
      controller.forward().whenComplete(() {
        if (!mounted) return;
        _controller?.dispose();
        _controller = null;
        setState(() {
          _fade = const AlwaysStoppedAnimation(1);
          _slide = const AlwaysStoppedAnimation(Offset.zero);
        });
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _fade, child: SlideTransition(position: _slide, child: widget.child));
}

class _EmptyTranscript extends StatelessWidget {
  const _EmptyTranscript();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.messageSquare, size: 28, color: ds.textTertiary),
            const SizedBox(height: Gap.md),
            Semantics(
              header: true,
              child: Text('Nothing said yet', style: Type.row.copyWith(color: ds.text)),
            ),
            const SizedBox(height: Gap.xs),
            Text(
              'Tell the agent what to do.',
              textAlign: TextAlign.center,
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ],
        ),
      ),
    ));
  }
}

/// A scroll controller whose position keeps the end in view while it was at
/// the end (see [_StickyPosition]). With [follow] false the position starts
/// away from the end, at the start of the newer rows.
class _StickyController extends ScrollController {
  _StickyController({this.follow = true}) : super(keepScrollOffset: false);

  final bool follow;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _StickyPosition(physics: physics, context: context, oldPosition: oldPosition, debugLabel: debugLabel)
    .._following = follow;
}

/// A list position that stays glued to the end.
///
/// While the person has not scrolled away from the end (and at first), the
/// position moves to the new end the moment the content grows or the viewport
/// shrinks, in the same layout pass: no frame is drawn with the end cut off,
/// and a keyboard opening keeps the last line above it. Scrolling away (a
/// drag, a fling, a jump) ends that; reaching the end again resumes it, so
/// reading earlier output while the agent streams does not move under the
/// finger.
///
/// Nothing moves while a finger is down ([holdFollow]): a touch that has not
/// started scrolling yet (the start of a selection, a tap) must not see its
/// text slide away. The view catches up to the end the moment the last
/// finger is up, unless a fling is under way.
///
/// The intent is a flag set by scrolling, not read off the geometry: a list
/// of rows of unknown height re-estimates its extent as rows are measured,
/// and a position that sat at the end can be a few pixels from the new one.
class _StickyPosition extends ScrollPositionWithSingleContext {
  _StickyPosition({required super.physics, required super.context, super.oldPosition, super.debugLabel});

  bool _following = true;
  bool _held = false;

  /// Whether the view stays at the end as the content grows.
  bool get following => _following;

  /// Stops following until the person scrolls back to the end.
  void pauseFollow() => _following = false;

  /// Follows the end again (the next layout moves there).
  void resumeFollow() => _following = true;

  /// A finger is on the list ([held]) or the last one just left.
  void holdFollow(bool held) {
    if (_held == held) return;
    _held = held;
    if (!held && _following && hasPixels && hasContentDimensions && !isScrollingNotifier.value) {
      if (pixels < maxScrollExtent - 0.5) jumpTo(maxScrollExtent);
    }
  }

  /// A jump is the person's choice too ("Jump to latest" resumes following).
  @override
  void jumpTo(double value) {
    super.jumpTo(value);
    _noteScroll();
  }

  void _noteScroll() {
    if (hasContentDimensions) _following = pixels >= maxScrollExtent - _atEnd;
  }

  /// Only the person's scrolling (a drag, or the fling after one) changes the
  /// intent. The settling the framework starts by itself when the extent
  /// shrinks under the position is not the person leaving the end.
  @override
  double setPixels(double newPixels) {
    final overscroll = super.setPixels(newPixels);
    if (userScrollDirection != ScrollDirection.idle) _noteScroll();
    return overscroll;
  }

  @override
  void forcePixels(double value) {
    super.forcePixels(value);
    _noteScroll();
  }

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    final follow = _following && !_held;
    final ok = super.applyContentDimensions(minScrollExtent, maxScrollExtent);
    if (follow && hasPixels && maxScrollExtent > pixels + 0.5) {
      correctPixels(maxScrollExtent);
      return false;
    }
    return ok;
  }
}
