import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/decision/permission_evidence.dart';
import '../../../data/words/plural.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/markdown/markdown.dart';
import 'code_panel.dart' show clipLine;
import 'diff_lines.dart';
import '../../render/visible_text.dart';

/// What a decision shows of what it approves:
/// the agent's last sentence, the edits as a diff, the plan as Markdown. The
/// data is `permissionEvidence` / `planApprovalEvidence` (bounded, free of
/// hidden characters); this file only draws it, in the same quiet boxes the
/// command uses: a few lines, a scrollbar, `More below` and `Read all`.

/// How tall an evidence box may be: the dock must leave the answers in reach,
/// so a short screen gets less.
double evidenceBoxHeight(BuildContext context, {required double tall, required double short}) =>
    MediaQuery.sizeOf(context).height < 700 ? short : tall;

/// Heights of the boxes (a phone / a short screen).
const diffBoxTall = 150.0;
const diffBoxShort = 96.0;
const planBoxTall = 180.0;
const planBoxShort = 110.0;

/// Past this many rows a box builds its rows lazily in a box of fixed height
/// (the dock is laid out for every frame of the keyboard's animation: a
/// 400-line plan must not be).
const _eagerRows = 8;

/// The words under a plan that is only the start of the real one (omp sends
/// the first 12 lines of its plan in the question and nothing else).
const planPreviewNote = 'First 12 lines of the plan';

// ---------------------------------------------------------------------------
// the agent's last sentence

/// The agent's last sentence before it asked, as a quiet lead-in above what it
/// asks. Two lines at most; the whole sentence is what a screen reader hears.
class EvidenceIntent extends StatelessWidget {
  const EvidenceIntent({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final said = visibleText(text);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs, bottom: Gap.hair),
      child: Semantics(
        label: context.l10n.messageTheAgentSaid(said),
        excludeSemantics: true,
        child: Text(
          '\u201c$said\u201d',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Type.secondary.copyWith(color: ds.textSecondary),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// a box that scrolls

/// A few rows of evidence in the surface box the command sits in: a scrollbar
/// whenever there is more than fits, rows built lazily past [_eagerRows].
class EvidenceBox extends StatelessWidget {
  const EvidenceBox({
    super.key,
    required this.count,
    required this.itemBuilder,
    required this.controller,
    required this.overflows,
    required this.maxHeight,
    this.padding = const EdgeInsets.symmetric(horizontal: Gap.md, vertical: Gap.sm),
  });

  final int count;
  final IndexedWidgetBuilder itemBuilder;
  final ScrollController controller;
  final bool overflows;
  final double maxHeight;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final Widget scroller;
    if (count <= _eagerRows) {
      scroller = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Scrollbar(
          controller: controller,
          thumbVisibility: overflows,
          child: SingleChildScrollView(
            controller: controller,
            padding: padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (var i = 0; i < count; i++) itemBuilder(context, i)],
            ),
          ),
        ),
      );
    } else {
      scroller = SizedBox(
        height: maxHeight,
        child: Scrollbar(
          controller: controller,
          thumbVisibility: overflows,
          child: ListView.builder(controller: controller, padding: padding, itemCount: count, itemBuilder: itemBuilder),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ds.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: ds.hairline),
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(Radii.sm), child: scroller),
    );
  }
}

/// Under a box that scrolls: how much is below, and a way to read it all.
/// Null [onOpen] leaves the button out (the box shows everything there is).
class ReadAllCue extends StatelessWidget {
  const ReadAllCue({super.key, required this.text, required this.onOpen});

  final String? text;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    if (text == null && onOpen == null) return const SizedBox.shrink();
    final ds = context.ds;
    return Row(
      children: [
        Expanded(
          child: text == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: onOpen == null ? const EdgeInsets.symmetric(vertical: Gap.xs) : EdgeInsets.zero,
                  child: Text(text!, style: Type.captionStrong.copyWith(color: ds.blockedText)),
                ),
        ),
        if (onOpen case final open?) ...[
          const SizedBox(width: Gap.md),
          TextAction(label: context.l10n.uiReadAll, onTap: open),
        ],
      ],
    );
  }
}

/// A sheet with a list of [count] rows that builds them lazily and scrolls.
Future<void> showEvidenceSheet(
  BuildContext context, {
  required String title,
  String? note,
  required int count,
  required IndexedWidgetBuilder itemBuilder,
}) {
  // The sheet is a route of its own: it does not sit under the dock's Markdown
  // handlers (a tap on a link or a path in a plan).
  final actions = context.getInheritedWidgetOfExactType<MdActions>();
  return showAppSheet<void>(
    context,
    builder: (ctx) {
      final ds = ctx.ds;
      final lead = note == null ? 0 : 1;
      Widget list = SelectionArea(
        child: ListView.builder(
          // The list kind's inset 4 + 16: the lines sit on the 20 gutter.
          padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.lg),
          itemCount: count + lead,
          itemBuilder: (context, i) => i < lead
              ? Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: Text(note!, style: Type.secondary.copyWith(color: ds.textSecondary)),
                )
              : itemBuilder(context, i - lead),
        ),
      );
      if (actions != null) list = MdActions(onLink: actions.onLink, onPath: actions.onPath, child: list);
      return SheetScaffold(title: title, kind: SheetKind.list, scrolls: true, child: list);
    },
  );
}

// ---------------------------------------------------------------------------
// the plan

/// How many lines a plan has, for `More below · 38 lines`.
int planLineCount(String plan) => '\n'.allMatches(plan).length + 1;

/// The plan as Markdown rows, one block each, with the gaps of a document.
/// Long code blocks keep their `Show all` state here.
class PlanBox extends StatefulWidget {
  const PlanBox({
    super.key,
    required this.document,
    required this.controller,
    required this.overflows,
    required this.maxHeight,
  });

  final MdDocument document;
  final ScrollController controller;
  final bool overflows;
  final double maxHeight;

  @override
  State<PlanBox> createState() => _PlanBoxState();
}

class _PlanBoxState extends State<PlanBox> {
  final _expanded = <int>{};

  @override
  Widget build(BuildContext context) {
    final blocks = widget.document.blocks;
    return EvidenceBox(
      count: blocks.length,
      controller: widget.controller,
      overflows: widget.overflows,
      maxHeight: widget.maxHeight,
      itemBuilder: (context, i) => planBlock(
        blocks,
        i,
        expanded: _expanded.contains(i),
        onToggle: () => setState(() => _expanded.contains(i) ? _expanded.remove(i) : _expanded.add(i)),
      ),
    );
  }
}

/// Block [i] of a document as a row.
Widget planBlock(List<MdBlock> blocks, int i, {bool expanded = false, VoidCallback? onToggle}) {
  final previous = i > 0 ? blocks[i - 1] : null;
  return Padding(
    padding: EdgeInsets.only(top: mdBlockGap(previous, blocks[i])),
    child: MdBlockView(block: blocks[i], expanded: expanded, onToggleExpanded: onToggle),
  );
}

/// The whole plan in a sheet.
Future<void> showPlanSheet(BuildContext context, MdDocument document, {bool preview = false}) {
  final blocks = document.blocks;
  return showEvidenceSheet(
    context,
    title: context.l10n.uiThePlan,
    note: preview ? planPreviewNote : null,
    count: blocks.length,
    itemBuilder: (context, i) => planBlock(blocks, i),
  );
}

/// A plan for a form that approves it (omp asks through a question): the box,
/// its cue and `Read all`, measuring itself.
class PlanEvidence extends StatefulWidget {
  const PlanEvidence({super.key, required this.markdown, this.preview = false});

  final String markdown;

  /// The plan is only the start of the real one ([planPreviewNote]).
  final bool preview;

  @override
  State<PlanEvidence> createState() => _PlanEvidenceState();
}

class _PlanEvidenceState extends State<PlanEvidence> {
  late final MdDocument _document = parseMd(widget.markdown);
  late final int _lines = planLineCount(widget.markdown);
  final _controller = ScrollController();
  bool _overflows = false;
  bool _atEnd = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth != 0) return false;
    _measure(n.metrics);
    return false;
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0) _measure(n.metrics);
    return false;
  }

  void _measure(ScrollMetrics m) {
    final over = m.maxScrollExtent > 1;
    final end = m.extentAfter <= 2;
    if (over == _overflows && (!end || _atEnd)) return;
    // Notifications arrive in the layout pass: build after it.
    scheduleMicrotask(() {
      if (mounted) {
        setState(() {
          _overflows = over;
          _atEnd = _atEnd || end;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: _onMetrics,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: PlanBox(
              document: _document,
              controller: _controller,
              overflows: _overflows,
              maxHeight: evidenceBoxHeight(context, tall: planBoxTall, short: planBoxShort),
            ),
          ),
        ),
        ReadAllCue(
          text: preview
              ? planPreviewNote
              : (_overflows && !_atEnd ? context.l10n.messageMoreBelowLines('$_lines') : null),
          onOpen: _overflows ? () => unawaited(showPlanSheet(context, _document, preview: preview)) : null,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// the edits

sealed class DiffRow {
  const DiffRow();
}

/// A file: its path and what changed in it.
class DiffHeaderRow extends DiffRow {
  const DiffHeaderRow(this.diff);

  final EvidenceDiff diff;
}

class DiffTextRow extends DiffRow {
  const DiffTextRow(this.line);

  final DiffLine line;
}

/// A sentence about what the diff leaves out.
class DiffNoteRow extends DiffRow {
  const DiffNoteRow(this.text);

  final String text;
}

/// The rows of every diff of [evidence]: per file a header, the changed lines
/// with two lines of context, and a note where text was cut.
List<DiffRow> diffRowsOf(PermissionEvidence evidence) {
  final rows = <DiffRow>[];
  for (final d in evidence.diffs) {
    rows.add(DiffHeaderRow(d));
    for (final line in diffLines(d.oldText, d.newText)) {
      rows.add(DiffTextRow(line));
    }
    if (d.cutChars > 0) rows.add(DiffNoteRow('\u2026 ${d.cutChars} characters of this file are not compared'));
  }
  if (evidence.hiddenDiffs > 0) {
    final n = evidence.hiddenDiffs;
    rows.add(DiffNoteRow('${countOf(n, 'more file')} not shown'));
  }
  return rows;
}

/// `+3 −1`, `new file +40`, `up to +300 −200` when the count is an upper
/// bound.
String diffCounts(EvidenceDiff d) {
  final counts = d.removed == 0 ? '+${d.added}' : '+${d.added} \u2212${d.removed}';
  final bounded = d.approximate ? 'up to $counts' : counts;
  return d.isNew ? 'new file $bounded' : bounded;
}

Widget diffRowView(BuildContext context, DiffRow row) {
  final ds = context.ds;
  switch (row) {
    case DiffHeaderRow(:final diff):
      final counts = diffCounts(diff);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.hair),
        child: Semantics(
          label: '${visibleText(diff.path)}, $counts',
          excludeSemantics: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: Gap.hair),
                child: Icon(LucideIcons.file, size: IconSize.inline, color: ds.textSecondary),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Text(visibleText(diff.path), style: Mono.base.copyWith(color: ds.text)),
              ),
              const SizedBox(width: Gap.sm),
              Text(
                counts,
                style: Mono.base.copyWith(
                  color: ds.textSecondary,
                  fontFeatures: [...Mono.noLigatures, ...Type.tabular],
                ),
              ),
            ],
          ),
        ),
      );
    case DiffNoteRow(:final text):
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.hair),
        child: Text(text, style: Type.caption.copyWith(color: ds.textSecondary)),
      );
    case DiffTextRow(:final line):
      final term = context.terminal;
      final text = visibleText(clipLine(line.text));
      final (prefix, color, spoken) = switch (line.kind) {
        DiffKind.add => ('+ ', term.ansi[2], 'added'),
        DiffKind.del => ('- ', term.ansi[1], 'removed'),
        DiffKind.same => ('  ', null, null),
        DiffKind.gap => ('\u2026 ', term.dim, null),
      };
      final body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xs),
        child: Text(
          '$prefix${text.isEmpty ? ' ' : text}',
          semanticsLabel: spoken == null ? null : '$spoken: $text',
          style: Mono.base.copyWith(color: color ?? ds.text),
        ),
      );
      if (line.kind != DiffKind.add && line.kind != DiffKind.del) return body;
      return DecoratedBox(
        decoration: BoxDecoration(color: ds.wash(color!)),
        child: SizedBox(width: double.infinity, child: body),
      );
  }
}

Future<void> showDiffSheet(BuildContext context, List<DiffRow> rows) => showEvidenceSheet(
  context,
  title: context.l10n.uiEverythingItWillChange,
  count: rows.length,
  itemBuilder: (context, i) => diffRowView(context, rows[i]),
);

/// The edits a request makes, as a diff in a box with `More below` and
/// `Read all`, measuring itself.
class DiffEvidence extends StatefulWidget {
  const DiffEvidence({super.key, required this.evidence});

  final PermissionEvidence evidence;

  @override
  State<DiffEvidence> createState() => _DiffEvidenceState();
}

class _DiffEvidenceState extends State<DiffEvidence> {
  late final List<DiffRow> _rows = diffRowsOf(widget.evidence);
  final _controller = ScrollController();
  bool _overflows = false;
  bool _atEnd = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth == 0) _measure(n.metrics);
    return false;
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth == 0) _measure(n.metrics);
    return false;
  }

  void _measure(ScrollMetrics m) {
    final over = m.maxScrollExtent > 1;
    final end = m.extentAfter <= 2;
    if (over == _overflows && (!end || _atEnd)) return;
    scheduleMicrotask(() {
      if (mounted) {
        setState(() {
          _overflows = over;
          _atEnd = _atEnd || end;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotificationListener<ScrollMetricsNotification>(
          onNotification: _onMetrics,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: EvidenceBox(
              count: rows.length,
              controller: _controller,
              overflows: _overflows,
              maxHeight: evidenceBoxHeight(context, tall: diffBoxTall, short: diffBoxShort),
              itemBuilder: (context, i) => diffRowView(context, rows[i]),
            ),
          ),
        ),
        ReadAllCue(
          text: _overflows && !_atEnd ? context.l10n.messageMoreBelowLines('${rows.length}') : null,
          onOpen: _overflows ? () => unawaited(showDiffSheet(context, rows)) : null,
        ),
      ],
    );
  }
}
