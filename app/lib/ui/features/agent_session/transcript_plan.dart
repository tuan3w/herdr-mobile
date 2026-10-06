import 'dart:math' as math;

import '../../../data/acp/acp_models.dart';
import '../../../data/acp/session_state.dart';
import '../../../data/acp/turns/turns.dart';
import '../../core/markdown/markdown.dart';

/// What a [PlanRow] shows.
enum RowKind {
  /// The person's message that starts a turn.
  user,

  /// The folded work log of a finished turn, one line (`Worked 42s · ...`).
  fold,

  /// The agent's reasoning of one stretch of the log, folded to one line.
  thinking,

  /// One tool call.
  tool,

  /// Several adjacent reads and searches, one line (`Read 3 files`).
  group,

  /// One Markdown block of an agent message: narration inside the log
  /// ([PlanRow.quiet]) or the answer.
  text,

  /// A piece of an agent message that is not text (an image, a link).
  content,

  /// The top of the Changed card.
  changedHead,

  /// One file of the Changed card.
  changedFile,

  /// The last line of a Changed card that lists only some of its files.
  changedMore,

  /// A hairline with `N new` above the first thing the person has not seen.
  divider,

  /// A refusal or a limit.
  stop,

  /// Something the app says about the session (the agent changed the mode).
  note,
}

/// One row of the transcript list.
class PlanRow {
  const PlanRow(
    this.key,
    this.kind,
    this.gap, {
    this.item,
    this.part,
    this.turn,
    this.group,
    this.thoughts = const [],
    this.file,
    this.live = false,
    this.before,
    this.firstBlock = 0,
    this.quiet = false,
    this.nested = false,
    this.first = false,
    this.last = false,
    this.open = false,
    this.label,
    this.count = 0,
  });

  /// Stable list key.
  final String key;
  final RowKind kind;

  /// Space above the row.
  final double gap;

  /// The transcript item the row shows (a message, a tool call, a stop, a
  /// note); for a thinking row the first thought.
  final TranscriptItem? item;

  /// The Markdown block or content block of an agent message; null for the
  /// rows that show a whole item.
  final Object? part;

  /// The turn, for the fold line and the Changed card.
  final Turn? turn;

  /// The calls of a group row.
  final ToolGroup? group;

  /// The thoughts of a thinking row, in order.
  final List<TranscriptMessage> thoughts;

  /// The file of a Changed card row.
  final ChangedFile? file;

  /// The row of the message that is streaming in right now: one row for all
  /// the text that is arriving, where a settled message has one per block
  /// (`LiveMessageRow`).
  final bool live;

  /// Live row only: the segment right above the live text (a block of the
  /// same message, or null when the live text starts the message). The row
  /// works out the gap above its first block from it, as [TranscriptPlan]
  /// does for the rows of a settled message.
  final Object? before;

  /// Live row only: the index its first block would have as a row of the
  /// settled message (`<key>#<firstBlock>`), so a block keeps its key when
  /// the message ends.
  final int firstBlock;

  /// Narration inside the work log: the agent's words before its last step,
  /// drawn in the supporting colour at the size of the answer.
  final bool quiet;

  /// A call inside an expanded group.
  final bool nested;

  /// Changed card rows: the top and the bottom of the panel.
  final bool first;
  final bool last;

  /// Fold and group rows: whether what they fold is shown.
  final bool open;

  /// Fold row: a trailing part of the summary the view knows (`Plan 3 of 3
  /// done`). Divider: its label. Changed card: the head's totals.
  final String? label;

  /// Changed more row: how many files are not listed.
  final int count;
}

/// The rows of a transcript, in order, and where each key sits.
///
/// A transcript is a list of turns ([turnsOf]): the person's message, then the
/// agent's work log, the Changed card, the answer, and what breaks out of the
/// fold (a failed or cancelled call, a call that waits for the person, a stop,
/// a note). A finished turn shows its log as one line; the turn that runs
/// shows it open. The rows of an open log are rows of the list, not one tall
/// row, so a long log is as lazy as the rest.
///
/// [update] takes the next items and re-plans only from the first turn that is
/// not the same object as before. [turnsOf] keeps a turn whose items did not
/// change as the same object, so a tool call that starts in the last turn
/// costs that turn, not the transcript; a chunk of the streaming message does
/// not reach this class at all (the list is the same instance). What else a
/// turn's rows depend on is told to the plan: the fold state of the turn
/// ([open], kept by the owner; [refresh] re-plans a turn when one of its toggles
/// changed), the calls that wait for the person, the place of the since-left
/// divider and the plan note of a turn.
class TranscriptPlan {
  TranscriptPlan({this.open = const {}, this.notes = const {}}) {
    update(const []);
  }

  /// The owner's set of toggles. The plan reads `<turn>:log` (a finished
  /// turn's log is open), `<turn>:changed:all` (the Changed card lists every
  /// file) and `<call>:group` (a group shows its calls).
  final Set<String> open;

  /// A trailing part of the fold line per turn key (`Plan 3 of 3 done`).
  final Map<String, String> notes;

  List<Turn> _turns = const [];
  bool _live = false;
  Set<String> _waiting = const {};
  String? _dividerKey;
  int _dividerTurn = -1;

  /// The rows planned for the last items given.
  final List<PlanRow> rows = [];

  /// Where each row key sits in [rows].
  final Map<String, int> index = {};

  // Per planned turn: rows.length after it.
  final List<int> _ends = [];

  /// The turn each row belongs to, by row index (so a toggle can name its turn).
  final List<int> _rowTurn = [];

  int _forceFrom = 1 << 30;

  /// How many turns [update] has planned since this plan was made (tests).
  int plannedTurns = 0;

  /// How many items those turns held (tests).
  int plannedItems = 0;

  /// The index of the live row, or -1.
  int get liveRow {
    if (rows.isEmpty) return -1;
    final last = rows.length - 1;
    return rows[last].live ? last : -1;
  }

  /// The index of the divider row, or -1.
  int get dividerRow => _dividerRowIndex;
  int _dividerRowIndex = -1;
  String _dividerLabel = 'New';

  /// The turns of the last [update].
  List<Turn> get turns => _turns;

  /// Plans the turn that owns [rowKey] again on the next [update]: a toggle
  /// the plan reads (a fold, the Changed card, a group) changed.
  void refresh(String rowKey) {
    final at = index[rowKey];
    if (at == null) return;
    _forceFrom = math.min(_forceFrom, _rowTurn[at]);
  }

  /// Plans [items]; returns the keys of rows that existed and no longer do.
  ///
  /// [live] is whether a turn runs (the last turn is live). [waiting] are the
  /// ids of the calls that wait for the person's permission. [dividerKey] is
  /// the key of the first item the person has not seen.
  List<String> update(
    List<TranscriptItem> items, {
    bool live = false,
    Set<String> waiting = const {},
    String? dividerKey,
    String dividerLabel = 'New',
  }) {
    _dividerLabel = dividerLabel;
    final turns = turnsOf(items, live: live);
    var force = _forceFrom;
    _forceFrom = 1 << 30;

    // The calls that wait for the person changed: re-plan the turn they are in.
    if (!_sameIds(waiting, _waiting)) {
      final changed = {..._waiting.difference(waiting), ...waiting.difference(_waiting)};
      for (var t = turns.length - 1; t >= 0; t--) {
        if (turns[t].tools.any((tool) => changed.contains(tool.call.toolCallId))) {
          force = math.min(force, t);
          break;
        }
      }
    }
    // The divider moved: re-plan the turn that had it and the turn that has it.
    var dividerTurn = -2;
    if (dividerKey != _dividerKey) {
      dividerTurn = dividerKey == null ? -1 : _findTurn(turns, dividerKey, 0);
      if (_dividerTurn >= 0) force = math.min(force, _dividerTurn);
      if (dividerTurn >= 0) force = math.min(force, dividerTurn);
    }

    var p = 0;
    final shared = math.min(turns.length, _turns.length);
    while (p < shared && p < force && identical(turns[p], _turns[p])) {
      p++;
    }
    if (dividerTurn == -2) {
      // The same divider as before: it is still in its turn when that turn is
      // not planned again; else it can only be in a turn that is.
      dividerTurn = dividerKey == null
          ? -1
          : (_dividerTurn >= 0 && _dividerTurn < p ? _dividerTurn : _findTurn(turns, dividerKey, p));
    }
    final start = p == 0 ? 0 : _ends[p - 1];
    final removed = <String>[];
    for (var i = start; i < rows.length; i++) {
      removed.add(rows[i].key);
      index.remove(rows[i].key);
    }
    rows.removeRange(start, rows.length);
    _rowTurn.length = start;
    _ends.length = p;

    final planner = _Planner(this, waiting, dividerKey, dividerTurn);
    for (var t = p; t < turns.length; t++) {
      planner.turn(turns[t], t);
      _ends.add(rows.length);
      plannedTurns++;
      plannedItems += turns[t].items.length;
    }
    for (var i = start; i < rows.length; i++) {
      index[rows[i].key] = i;
    }
    _dividerRowIndex = index[_dividerRowKey] ?? -1;
    _turns = turns;
    _live = live;
    _waiting = waiting;
    _dividerKey = dividerKey;
    _dividerTurn = dividerTurn;
    return [
      for (final key in removed)
        if (!index.containsKey(key)) key,
    ];
  }

  bool get live => _live;
}

bool _sameIds(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

/// The index of the first turn from [from] that holds the item with [key]
/// (its message included), or -1.
int _findTurn(List<Turn> turns, String key, int from) {
  for (var t = from; t < turns.length; t++) {
    if (turns[t].user?.key == key || turns[t].items.any((i) => i.key == key)) return t;
  }
  return -1;
}

/// The key of the divider row.
const _dividerRowKey = 'since-left';

/// The key of the live row of the message [messageKey].
String liveRowKey(String messageKey) => '$messageKey#live';

/// The key of the toggle that opens the work log of the turn [turnKey].
String logKey(String turnKey) => '$turnKey:log';

/// The key of the toggle that lists every file of the Changed card.
String changedAllKey(String turnKey) => '$turnKey:changed:all';

/// The key of the row of a group whose first call is [toolKey].
String groupRowKey(String toolKey) => '$toolKey:group';

final _settled = Expando<List<Object>>('message segments');

/// The segments of a message that is not live: its Markdown blocks and its
/// other content blocks, in order. Parsed once per message object.
List<Object> segmentsOf(TranscriptMessage message) => _settled[message] ??= _segments(message.blocks);

List<Object> _segments(List<ContentBlock> blocks) => [
  for (final block in blocks)
    if (block is TextBlock) ...parseMd(block.text).blocks else block,
];

/// Files listed in a Changed card before `N more`.
const changedShown = 6;

// What the gap above a row depends on: the row before it.
enum _Before { none, user, step, text, changed, note, divider }

_Before _before(PlanRow? row) => switch (row?.kind) {
  null => _Before.none,
  RowKind.user => _Before.user,
  RowKind.fold || RowKind.thinking || RowKind.tool || RowKind.group => _Before.step,
  RowKind.text || RowKind.content => _Before.text,
  RowKind.changedHead || RowKind.changedFile || RowKind.changedMore => _Before.changed,
  RowKind.stop || RowKind.note => _Before.note,
  RowKind.divider => _Before.divider,
};

/// The space above a row of [kind] under the row before it. The narration of
/// the log and the answer are both [RowKind.text] and have the same gaps, so a
/// message that was the answer and becomes narration (a tool call starts after
/// it) keeps its place.
double gapAbove(PlanRow? previous, RowKind kind) {
  final before = _before(previous);
  if (before == _Before.none) return 0;
  switch (kind) {
    case RowKind.user:
      return before == _Before.divider ? 8 : 16;
    case RowKind.fold || RowKind.thinking || RowKind.tool || RowKind.group:
      return switch (before) {
        _Before.step || _Before.divider => 0,
        _Before.changed => 8,
        _ => 6,
      };
    case RowKind.text || RowKind.content:
      return switch (before) {
        _Before.user => 16,
        _Before.step => 10,
        _Before.text => 16,
        _Before.changed => 12,
        _Before.note => 10,
        _ => 8,
      };
    case RowKind.changedHead:
      return switch (before) {
        _Before.text => 12,
        _Before.note => 10,
        _Before.divider => 6,
        _ => 8,
      };
    case RowKind.changedFile || RowKind.changedMore:
      return 0;
    case RowKind.divider:
      return 8;
    case RowKind.stop || RowKind.note:
      return before == _Before.divider ? 4 : 10;
  }
}

class _Planner {
  _Planner(this.plan, this.waiting, this.dividerKey, this.dividerTurn);

  final TranscriptPlan plan;
  final Set<String> waiting;
  final String? dividerKey;
  final int dividerTurn;

  List<PlanRow> get rows => plan.rows;

  PlanRow? get previous => rows.isEmpty ? null : rows.last;

  int _turn = 0;
  bool _placed = false;

  /// Adds [row]; if the divider is waiting for one of [covers], it goes first.
  void add(PlanRow row, [Iterable<TranscriptItem>? covers]) {
    final key = dividerKey;
    if (key != null && !_placed && _turn == dividerTurn && covers != null && covers.any((i) => i.key == key)) {
      _placed = true;
      final before = previous;
      final gap = gapAbove(before, RowKind.divider);
      rows.add(PlanRow(_dividerRowKey, RowKind.divider, gap, label: plan._dividerLabel));
      plan._rowTurn.add(_turn);
    }
    rows.add(row);
    plan._rowTurn.add(_turn);
  }

  void turn(Turn t, int ti) {
    _turn = ti;
    _placed = false;
    final open = t.live || plan.open.contains(logKey(t.key));
    final user = t.user;
    if (user != null && user.blocks.isNotEmpty) {
      add(PlanRow(user.key, RowKind.user, gapAbove(previous, RowKind.user), item: user), [user]);
    }
    if (t.hasWork) {
      if (!t.live) {
        add(
          PlanRow(
            logKey(t.key),
            RowKind.fold,
            gapAbove(previous, RowKind.fold),
            turn: t,
            open: open,
            label: plan.notes[t.key],
          ),
          open ? null : t.work,
        );
      }
      if (open) _log(t);
    }
    if (!t.live && t.changed.isNotEmpty) _changed(t);
    final answer = t.answer;
    if (answer != null) _message(answer, quiet: false);
    // What breaks out of the fold stays visible. An open log already shows
    // the calls in their place.
    for (final item in t.items) {
      switch (item) {
        case TranscriptTool() when !open && _breaksOut(item):
          add(PlanRow(item.key, RowKind.tool, gapAbove(previous, RowKind.tool), item: item), [item]);
        case TranscriptStop():
          add(PlanRow(item.key, RowKind.stop, gapAbove(previous, RowKind.stop), item: item), [item]);
        case TranscriptNote():
          add(PlanRow(item.key, RowKind.note, gapAbove(previous, RowKind.note), item: item), [item]);
        default:
      }
    }
  }

  bool _breaksOut(TranscriptTool tool) =>
      toolFailed(tool.call) || tool.call.status == ToolStatus.cancelled || waiting.contains(tool.call.toolCallId);

  /// The open log: per stretch between two pieces of narration, one thinking
  /// line, then the calls (adjacent reads and searches grouped); the
  /// narration in between as quiet Markdown.
  void _log(Turn t) {
    final thoughts = <TranscriptMessage>[];
    final run = <TranscriptTool>[];

    void flush() {
      if (thoughts.isNotEmpty) {
        final list = List<TranscriptMessage>.of(thoughts);
        add(
          PlanRow(list.first.key, RowKind.thinking, gapAbove(previous, RowKind.thinking), item: list.first, thoughts: list),
          list,
        );
        thoughts.clear();
      }
      if (run.isNotEmpty) {
        for (final group in groupTools(run)) {
          if (group.isGroup) {
            final key = groupRowKey(group.key);
            final open = plan.open.contains(key);
            add(
              PlanRow(key, RowKind.group, gapAbove(previous, RowKind.group), group: group, open: open),
              open ? null : group.tools,
            );
            if (open) {
              for (final tool in group.tools) {
                add(PlanRow(tool.key, RowKind.tool, 0, item: tool, nested: true), [tool]);
              }
            }
          } else {
            final tool = group.tools.single;
            add(PlanRow(tool.key, RowKind.tool, gapAbove(previous, RowKind.tool), item: tool), [tool]);
          }
        }
        run.clear();
      }
    }

    for (final item in t.work) {
      switch (item) {
        case TranscriptTool():
          run.add(item);
        case TranscriptMessage(role: MessageRole.thought):
          thoughts.add(item);
        case TranscriptMessage():
          flush();
          _message(item, quiet: true);
        default:
      }
    }
    flush();
  }

  void _changed(Turn t) {
    final files = t.changed;
    final all = plan.open.contains(changedAllKey(t.key));
    final shown = all ? files.length : math.min(files.length, changedShown);
    add(
      PlanRow(
        '${t.key}:changed',
        RowKind.changedHead,
        gapAbove(previous, RowKind.changedHead),
        turn: t,
        first: true,
        count: files.length,
      ),
    );
    final trailing = shown < files.length || (all && files.length > changedShown);
    for (var i = 0; i < shown; i++) {
      add(
        PlanRow(
          '${t.key}:changed:${files[i].path}',
          RowKind.changedFile,
          0,
          turn: t,
          file: files[i],
          last: i == shown - 1 && !trailing,
        ),
      );
    }
    // A card that lists only some of its files ends in `N more`; one that
    // lists all of a long list ends in `Show fewer`.
    if (trailing) {
      add(PlanRow(changedAllKey(t.key), RowKind.changedMore, 0, turn: t, last: true, count: files.length - shown, open: all));
    }
  }

  /// The rows of an agent message: one per Markdown block, or the one live row
  /// for the text that is arriving. [quiet] is narration of the log.
  void _message(TranscriptMessage message, {required bool quiet}) {
    final live = message.live;
    final blocks = message.blocks;
    // A live message ends in its live text; the rows are the blocks before it.
    final head = live == null ? blocks : blocks.sublist(0, blocks.length - 1);
    final segments = live == null ? segmentsOf(message) : _segments(head);
    Object? last;
    var i = 0;
    for (final segment in segments) {
      final inner = last == null
          ? gapAbove(previous, segment is MdBlock ? RowKind.text : RowKind.content)
          : (last is MdBlock && segment is MdBlock ? mdBlockGap(last, segment) : 10.0);
      add(
        PlanRow(
          '${message.key}#${i++}',
          segment is MdBlock ? RowKind.text : RowKind.content,
          inner,
          item: message,
          part: segment,
          quiet: quiet,
        ),
        [message],
      );
      last = segment;
    }
    if (live != null) {
      add(
        PlanRow(
          liveRowKey(message.key),
          RowKind.text,
          gapAbove(previous, RowKind.text),
          item: message,
          live: true,
          before: last,
          firstBlock: i,
          quiet: quiet,
        ),
        [message],
      );
    }
  }
}
