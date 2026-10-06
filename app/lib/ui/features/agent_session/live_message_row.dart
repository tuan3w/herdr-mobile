import 'package:flutter/widgets.dart';

import '../../core/markdown/markdown.dart';
import 'live_message_model.dart';
import 'transcript_plan.dart' show liveRowKey;
import 'transcript_rows.dart';

/// The message that is streaming in right now: the one row of the transcript
/// that changes while text arrives. It draws what its [LiveMessageModel] has revealed:
///
///  * the frozen blocks, built once as widgets and kept (a `RepaintBoundary`
///    around them, so a frame that only changes the tail neither lays them out
///    nor paints them again), keyed `<message>#<index>` like the rows of a
///    settled message; and
///  * the tail: the open block, healed (`**bo` shows as bold, an open fence as
///    a code block), the only thing that is built, laid out and painted per
///    frame, so a frame costs the same at the start of the message and at the
///    end of a 20 KB one.
///
/// The gaps are those of the rows the message becomes when it ends
/// (`TranscriptPlan`), and the blocks are the same widgets, so ending the
/// message moves nothing.
class LiveMessageRow extends StatefulWidget {
  const LiveMessageRow({
    super.key,
    required this.messageKey,
    required this.model,
    required this.gap,
    required this.before,
    required this.firstBlock,
    required this.open,
    required this.openSignature,
    required this.onToggle,
  });

  /// `TranscriptItem.key` of the message.
  final String messageKey;
  final LiveMessageModel model;

  /// Space above the message, from the row before it; used when no block of
  /// the message comes before the live text.
  final double gap;

  /// The segment of the message right above the live text, or null (see
  /// `PlanRow.before`).
  final Object? before;

  /// Index of the first block of the live text among the message's rows.
  final int firstBlock;

  /// The owner's set of toggles ("Show all" of a long code block or table),
  /// and a value that changes when the ones of this message do.
  final Set<String> open;
  final int openSignature;
  final RowToggle onToggle;

  @override
  State<LiveMessageRow> createState() => _LiveMessageRowState();
}

class _LiveMessageRowState extends State<LiveMessageRow> {
  /// The frozen blocks as widgets, each built once, kept for the life of the
  /// message (or until what they depend on changes), and the one widget that
  /// holds them, replaced only when another block freezes.
  final _frozenRows = <Widget>[];
  Widget? _frozenView;
  int _frozenBuilt = -1;

  void _forgetFrozen() {
    _frozenRows.clear();
    _frozenView = null;
    _frozenBuilt = -1;
  }

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_changed);
  }

  @override
  void didUpdateWidget(LiveMessageRow old) {
    super.didUpdateWidget(old);
    if (!identical(old.model, widget.model)) {
      old.model.removeListener(_changed);
      widget.model.addListener(_changed);
      _forgetFrozen();
    } else if (old.openSignature != widget.openSignature ||
        old.gap != widget.gap ||
        !identical(old.before, widget.before) ||
        old.firstBlock != widget.firstBlock) {
      _forgetFrozen();
    }
  }

  @override
  void dispose() {
    widget.model.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  double _firstGap(MdBlock first) {
    final before = widget.before;
    if (before == null) return widget.gap;
    return before is MdBlock ? mdBlockGap(before, first) : 10.0;
  }

  Widget _row(int index, MdBlock block, double gap, {required bool tail}) {
    final id = '${widget.messageKey}#$index';
    return AgentTextRow(
      key: ValueKey(id),
      rowKey: id,
      block: block,
      gap: gap,
      expanded: widget.open.contains(allKey(id)),
      onToggle: widget.onToggle,
      tail: tail,
    );
  }

  /// The frozen blocks: one widget, rebuilt only when one more froze; the
  /// rows in it are the ones built before.
  Widget _frozen(List<MdBlock> frozen) {
    if (_frozenBuilt != frozen.length || _frozenView == null) {
      for (var i = _frozenRows.length; i < frozen.length; i++) {
        _frozenRows.add(
          _row(
            widget.firstBlock + i,
            frozen[i],
            i == 0 ? _firstGap(frozen[0]) : mdBlockGap(frozen[i - 1], frozen[i]),
            tail: false,
          ),
        );
      }
      _frozenBuilt = frozen.length;
      _frozenView = RepaintBoundary(
        key: const ValueKey('frozen'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: List.of(_frozenRows)),
      );
    }
    return _frozenView!;
  }

  @override
  Widget build(BuildContext context) {
    notifyRowBuilt(liveRowKey(widget.messageKey));
    final md = widget.model.md;
    final frozen = md.frozen;
    final tail = md.tail(heal: true);
    if (frozen.isEmpty && tail.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _frozen(frozen),
        for (var j = 0; j < tail.length; j++)
          _row(
            widget.firstBlock + frozen.length + j,
            tail[j],
            j > 0
                ? mdBlockGap(tail[j - 1], tail[j])
                : frozen.isEmpty
                ? _firstGap(tail[0])
                : mdBlockGap(frozen.last, tail[0]),
            tail: true,
          ),
      ],
    );
  }
}
