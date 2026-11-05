import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/machine_connection.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../../data/words/elapsed.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/step_clock.dart';
import '../../support/tap_guard.dart';
import 'agent_navigation.dart';
import 'answer_surface.dart';
import 'agents_grouping.dart';
import 'reply_chips.dart';
import 'reply_sheet.dart';
import 'board_selection.dart';
import 'swipe_review.dart';

/// Rows of terminal the card previews while the app reads no question in
/// them: enough to see what the agent asks.
const _previewRows = 5;

/// The card's way to answer in words, at the end of its last line (the
/// question's or the preview's). A quiet word, not the ↩ circle it
/// replaced: the arrow read as undo or back.
const _replyLabel = 'Reply…';

/// The painted width of [_replyLabel] at each text scale: measured once, not
/// on every preview refresh.
final _replyWidths = <double, double>{};

double _replyWidth(TextScaler scaler) => _replyWidths[scaler.scale(1)] ??= () {
  final painter = TextPainter(
    text: const TextSpan(text: _replyLabel, style: Type.labelStrong),
    textScaler: scaler,
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}();

/// A line's height in [style] at [scaler].
double _lineOf(TextStyle style, TextScaler scaler) => scaler.scale(style.fontSize!) * style.height!;

/// The one decision in front of the board: the first agent of Needs you that
/// can be answered, as a card. What it is (task, where, how long), a calm live
/// look at the end of its terminal and, when it is blocked on a prompt the app
/// understands, the question, what it is about (the command) and one-tap
/// answers. Every other agent is a row ([AgentCompactRow]). Why (owner
/// decision): a setting that drew every agent as a card put eleven idle cards
/// with `Reply…` between the person and what needed them.
///
/// The card's height depends only on the prompt (its question,
/// its subject and how its answers group, see `ReplyLayout`), never on how many lines have arrived or
/// on the state of the chips, so the board does not jump while a preview fills
/// in. It watches its pane's preview only while it is built and on a screen
/// the person can see (a virtualised list builds the ones near the screen; a
/// hidden tab or a covered screen reads nothing) and releases on dispose.
///
/// Semantics: the card body is ONE button that reads status, title, where, time
/// and the question with its subject; the reply button and the answer chips
/// are separate nodes above it, so they stay reachable.
class AgentCard extends StatefulWidget {
  const AgentCard({super.key, required this.agent});

  final AgentRowData agent;

  @override
  State<AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<AgentCard> with TapGuardState<AgentCard>, AnswerSurfaceMixin<AgentCard> {
  late final PanePreviews _previews;

  @override
  MachineConnection get answerMachine => _agent.machine;
  @override
  String get answerPaneId => _agent.paneId;
  @override
  PanePreviews get answerPreviews => _previews;

  AgentRowData get _agent => widget.agent;

  /// The card is on a screen the person can see: the board hidden behind
  /// another tab (an IndexedStack runs it with tickers off) or covered by
  /// another screen reads nothing. Known from `TickerMode`, which cannot be
  /// asked in [initState], so the first watch is taken in
  /// [didChangeDependencies].
  bool _onScreen = true;
  bool _started = false;

  bool get _wantsPreview => _onScreen;

  @override
  void initState() {
    super.initState();
    _previews = context.read<PanePreviews>();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _onScreen = TickerMode.valuesOf(context).enabled;
    _syncWatch();
    if (_started) {
      syncShown();
    } else {
      // The guard is already armed: the card, and its answers, just appeared.
      _started = true;
      shownPrompt = _promptIn(answerHandle?.preview.value);
    }
  }

  @override
  void didUpdateWidget(AgentCard old) {
    super.didUpdateWidget(old);
    _syncWatch();
    syncShown();
  }

  void _syncWatch() {
    if (_wantsPreview && answerHandle == null) {
      watchAnswers();
    } else if (!_wantsPreview && answerHandle != null) {
      releaseAnswers();
    }
  }

  /// The question the card shows from [preview]: only a live blocked agent's.
  PromptInfo? _promptIn(PanePreview? preview) =>
      _agent.status == AgentStatus.blocked && !_agent.stale ? preview?.prompt : null;

  @override
  PromptInfo? answerPromptIn(PanePreview? preview) => _promptIn(preview);

  /// The card changed height (it grows as a question arrives, a line above
  /// the question wraps): its answers, pinned to its bottom, moved under the
  /// thumb. Called during layout, so the dimmed redraw waits for the frame.
  bool _onResize(SizeChangedLayoutNotification _) {
    if (shownPrompt == null) return true;
    final wasSettled = settled;
    rearmGuard();
    if (wasSettled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return true;
  }

  /// Neither the card's own guard nor the board's (`SettleGate`) is open: the
  /// answers moved or changed a moment ago.
  bool get _unsettled => !settled || (context.read<SettleGate?>()?.closed ?? false);

  /// The chips are deaf while unsettled; this refuses too, so no path to an
  /// answer skips the guard. [asked] is the question the chips were drawn for.
  Future<void> _choose(PromptInfo asked, QuickReply r) async {
    if (_unsettled) return;
    await chooseAnswer(asked, r);
  }

  void _more() {
    if (!_unsettled) _openSheet();
  }

  void _open() {
    Haptics.tick();
    _agent.machine.markReviewed(_agent.paneId);
    openAgent(context, PaneAgent(_agent.machine.profile.id, _agent.paneId));
  }

  void _openSheet() => showReplySheet(context, key: _agent.key);

  /// A long press starts picking (it has its own haptic), a tap while picking
  /// toggles.
  void _pick({bool feedback = true}) {
    if (feedback) Haptics.tick();
    context.read<BoardSelection?>()?.toggle(paneRef(_agent.key));
  }

  @override
  Widget build(BuildContext context) {
    final handle = answerHandle;
    return handle == null
        ? _build(context, null)
        : ValueListenableBuilder<PanePreview?>(
            valueListenable: handle.preview,
            builder: (context, preview, _) => _build(context, preview),
          );
  }

  Widget _build(BuildContext context, PanePreview? preview) {
    final ds = context.ds;
    final sel = rowSelect(context, paneRef(_agent.key));
    final a = _agent;
    final prompt = _promptIn(preview);
    final chipsHeight = prompt == null ? 0.0 : ReplyChips.heightFor(prompt);
    final canReply = !a.stale;
    final scaler = MediaQuery.textScalerOf(context);
    final replyWidth = _replyWidth(scaler);
    // What a line keeps clear at its end for `Reply…`.
    final replyRoom = replyWidth + Gap.sm;
    final stackTime = _stackTime(context);
    // The answers are deaf and dimmed while they are new under the thumb: the
    // card's own guard (its question changed, or it grew) or the board's gate
    // (a card above them came or went, see `SettleGate`).
    final guarded = context.select<SettleGate?, bool>((g) => g?.closed ?? false) || !settled;

    // The glyph, the section and the orange question wash already say it
    // waits (a tinted card with an orange outline was the fourth statement
    // of it).
    final tint = sel.selected ? Color.alphaBlend(ds.accentWash, ds.surface) : ds.surface;
    // Picked is a tint, never an outline ("tint, don't outline").
    final edge = ds.hairline;
    final body = AnimatedSize(
      // A question arriving or being answered changes what the card holds:
      // it grows or folds instead of snapping.
      duration: Motion.of(context, Motion.expand),
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: PressBuilder(
        onTap: sel.active ? _pick : _open,
        onLongPress: () => _pick(feedback: false),
        selected: sel.active ? sel.selected : null,
        semanticLabel: _semanticLabel(prompt),
        builder: (context, pressed) => AnimatedContainer(
          duration: Motion.pressing(pressed),
          curve: Motion.easeOut,
          decoration: BoxDecoration(
            color: pressed ? Color.alphaBlend(ds.pressTint, tint) : tint,
            borderRadius: BorderRadius.circular(_radius),
            border: Border.all(color: edge),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(_pad, Gap.md, _pad, _pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(agent: a, showTime: !stackTime),
                Padding(
                  padding: const EdgeInsets.only(left: _glyphColumn),
                  child: _Subtitle(text: a.subtitle),
                ),
                if (stackTime)
                  Padding(
                    padding: const EdgeInsets.only(left: _glyphColumn),
                    child: StateTime(agent: a),
                  ),
                const SizedBox(height: Gap.md),
                if (prompt != null) ...[
                  QuestionWash(
                    question: prompt.question,
                    subject: prompt.subject,
                    // Room for the `Reply…` that floats over the wash's end.
                    trailing: canReply ? SizedBox(width: replyRoom) : null,
                    onReadAll: _more,
                  ),
                  SizedBox(height: Gap.md + chipsHeight),
                ] else
                  _PreviewPanel(rows: _previewRows, lines: preview?.lines, replyRoom: canReply ? replyRoom : 0),
              ],
            ),
          ),
        ),
      ),
    );

    // The card's width says whether the wash cuts its question (`Read all`),
    // which decides the line `Reply…` sits on.
    Widget card = LayoutBuilder(
      builder: (context, box) => Stack(
        // The selection mark sits on the card's corner.
        clipBehavior: Clip.none,
        children: [
          // A height change moves the answers pinned to the card's bottom.
          SizeChangedLayoutNotifier(child: body),
          if (prompt != null)
            Positioned(
              left: _pad,
              right: _pad,
              bottom: _pad,
              height: chipsHeight,
              // Picking agents: a tap on the answers picks the card.
              child: IgnorePointer(
                ignoring: sel.active,
                child: ReplyChips(
                  prompt: prompt,
                  controller: answerController,
                  onChoose: (r) => _choose(prompt, r),
                  onMore: _more,
                  guarded: guarded,
                ),
              ),
            ),
          if (canReply)
            _replyAt(
              // The text's right edge and the centre of the line it ends, from
              // the card's bottom right.
              right: _pad + (prompt != null ? Gap.md : Gap.sm + Gap.hair),
              centre: prompt != null
                  ? _pad +
                        chipsHeight +
                        Gap.md +
                        Gap.md +
                        _questionLastLine(prompt, context, box.maxWidth, replyRoom) / 2
                  : _pad + Gap.sm + _PreviewPanel.lineOf(context) / 2,
              width: replyWidth,
              title: a.title,
              ignoring: sel.active,
            ),
          if (sel.active) Positioned(left: -4, top: -4, child: SelectMark(selected: sel.selected)),
        ],
      ),
    );
    card = NotificationListener<SizeChangedLayoutNotification>(onNotification: _onResize, child: card);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _margin, vertical: Gap.xs),
      child: card,
    );
  }

  /// `Reply…`: its text ends [right] from the card's right edge, centred
  /// [centre] above the card's bottom, in a 44 dp hit box.
  Widget _replyAt({
    required double right,
    required double centre,
    required double width,
    required String title,
    required bool ignoring,
  }) {
    final box = math.max(width, kMinTap);
    return Positioned(
      right: right - (box - width) / 2,
      bottom: centre - kMinTap / 2,
      child: IgnorePointer(
        ignoring: ignoring,
        child: TextAction(
          label: _replyLabel,
          tone: TextActionTone.quiet,
          semanticLabel: 'Reply to $title',
          onTap: _openSheet,
        ),
      ),
    );
  }

  /// The height of the wash's last line: the `Read all` row when the wash
  /// cuts its text, else the subject's (or the question's) last line.
  double _questionLastLine(PromptInfo prompt, BuildContext context, double cardWidth, double replyRoom) {
    final scaler = MediaQuery.textScalerOf(context);
    // The card's 1 dp edge, its inset and the wash's.
    final width = cardWidth - 2 * (1 + _pad + Gap.md) - replyRoom;
    if (QuestionWash.cuts(prompt.question, prompt.subject, width, scaler, Directionality.of(context))) return kMinTap;
    return _lineOf(prompt.subject.isEmpty ? Type.prompt : Mono.input, scaler);
  }

  String _semanticLabel(PromptInfo? prompt) => [
    _agent.status.label,
    _agent.title,
    if (_agent.subtitle.isNotEmpty) _agent.subtitle,
    if (_agent.stale) 'offline',
    if (prompt != null)
      'Asks: ${prompt.question.replaceAll('\n', ' ')}'
          '${prompt.subject.isEmpty ? '' : '. ${prompt.subject.replaceAll('\n', ', ')}'}',
  ].join(', ');

  /// The card's inner edge: its corner radius, so content sits concentric.
  static const _pad = Radii.md;
  static const _margin = Gap.lg;
  static const _radius = Radii.md;

  /// Glyph + gap: text starts here.
  static const _glyphColumn = IconSize.lead + Gap.md;
}

class _Header extends StatelessWidget {
  const _Header({required this.agent, required this.showTime});

  final AgentRowData agent;

  /// False when the label moves under the subtitle ([_stackTime]).
  final bool showTime;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final titleLine = MediaQuery.textScalerOf(context).scale(_titleStyle.fontSize!) * _titleStyle.height!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Centred on the first title line.
        SizedBox(
          width: IconSize.lead,
          height: math.max(titleLine, IconSize.lead),
          child: Center(
            child: StatusGlyph(status: agent.status, size: IconSize.lead, dim: agent.stale),
          ),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Text(
            agent.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _titleStyle.copyWith(color: agent.stale ? ds.textSecondary : ds.text),
          ),
        ),
        if (showTime) ...[const SizedBox(width: Gap.sm), StateTime(agent: agent)],
      ],
    );
  }

  static const _titleStyle = Type.row;
}

/// "12m": the time only, tabular, by the minute, from one shared slow clock;
/// the glyph already says the state (DESIGN.md Hierarchy 5). Blocked reads in
/// the blocked colour and weight, every other state muted. After a gap the
/// start of a state is only a bound, and says so: "≤ 25m". A working agent
/// quiet for the connection's `quietAfter` shows `quiet 14m` instead: the
/// glyph says working, not quiet, so the word stays visible; the number is the one the row was sorted
/// by (worked out at the machine's last refresh, never per event), so label
/// and order agree. Offline agents say so; an agent whose start is not known
/// at all claims nothing. Screen readers hear the words ("needs you, 4
/// minutes").
class StateTime extends StatelessWidget {
  const StateTime({super.key, required this.agent});

  final AgentRowData agent;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final blocked = agent.status == AgentStatus.blocked;
    final style = (blocked && !agent.stale ? Type.captionStrong : Type.caption).copyWith(
      color: blocked && !agent.stale ? ds.blockedText : ds.textMuted,
      fontFeatures: Type.tabular,
    );
    Widget label(String text, String words) => Padding(
      padding: const EdgeInsets.only(top: Gap.hair),
      child: Semantics(
        label: words,
        excludeSemantics: true,
        child: Text(text, maxLines: 1, softWrap: false, style: style),
      ),
    );
    if (agent.stale) return label('offline', 'offline');
    if (agent.quietMinutes > 0) {
      // design-lint: allow(raw-duration) a count of minutes the machine measured, not a timer
      final quiet = Duration(minutes: agent.quietMinutes);
      return label('quiet ${Elapsed.compact(quiet, seconds: false)}', 'working, quiet for ${Elapsed.words(quiet)}');
    }
    final time = agent.since;
    if (time == null) return const SizedBox.shrink();
    return MinuteBuilder(
      builder: (context, now) {
        final d = time.since(now);
        final text = timeInState(agent.status, d, exact: time.exact);
        if (text.isEmpty) return const SizedBox.shrink();
        return label(text, timeInStateWords(agent.status, d, exact: time.exact));
      },
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Gap.hair),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Type.secondary.copyWith(color: context.ds.textSecondary),
      ),
    );
  }
}

/// The last few rows of a terminal in a calm inset panel. Fixed height for
/// [rows] lines (no jumping as lines arrive), text bottom-aligned, a soft fade
/// at the top, nothing wraps. `lines == null` is "still loading".
class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({required this.rows, required this.lines, required this.replyRoom});

  final int rows;
  final List<PreviewLine>? lines;

  /// What the last rows keep clear at their end for the `Reply…` that floats
  /// over the panel; 0 for none.
  final double replyRoom;

  static const _style = Mono.preview;

  /// Terminal text is a picture of a screen: it takes some scaling, not all.
  static TextScaler _scaler(BuildContext context) => MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15);

  /// One row's height.
  static double lineOf(BuildContext context) => _lineOf(_style, _scaler(context));

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final scaler = _scaler(context);
    final line = lineOf(context);
    // `Reply…` is centred on the last row; at a large text size it is taller
    // than a row and reaches into the one above.
    final keep = replyRoom == 0 ? 0 : (_lineOf(Type.labelStrong, MediaQuery.textScalerOf(context)) / line).ceil();
    final shown = lines;
    final last = shown == null || shown.isEmpty ? null : shown.length - 1;
    final tail = shown == null || shown.length <= rows ? shown : shown.sublist(shown.length - rows);

    Widget content;
    if (tail == null) {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final f in const [0.78, 0.52, 0.66].take(rows))
            SizedBox(
              height: line,
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: f,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: ds.skeleton, borderRadius: BorderRadius.circular(Radii.pill)),
                    child: const SizedBox(height: Gap.sm),
                  ),
                ),
              ),
            ),
        ],
      );
    } else if (tail.isEmpty) {
      content = Align(
        alignment: Alignment.bottomLeft,
        child: Text('No output yet', style: _style.copyWith(color: ds.textMuted)),
      );
    } else {
      content = Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (i, l) in tail.indexed)
            Padding(
              padding: i >= tail.length - keep ? EdgeInsets.only(right: replyRoom) : EdgeInsets.zero,
              child: Text(
                l.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textScaler: scaler,
                style: _style.copyWith(color: i == tail.length - 1 && last != null ? ds.text : ds.textSecondary),
              ),
            ),
        ],
      );
    }

    return ExcludeSemantics(
      child: SizedBox(
        height: rows * line + 2 * Gap.sm,
        // The panel's corners clip the top fade.
        child: ClipRRect(
          borderRadius: BorderRadius.circular(Radii.md),
          child: Panel(
            padding: EdgeInsets.zero,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(Gap.sm + Gap.hair, Gap.sm, Gap.sm + Gap.hair, Gap.sm),
                    child: content,
                  ),
                ),
                if (tail != null && tail.length >= rows)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: Gap.lg,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [ds.fill, ds.fill.withAlpha(0)],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The dense two-line row (the old list), with the same time-in-state label.
class AgentCompactRow extends StatelessWidget {
  const AgentCompactRow({super.key, required this.agent, required this.divider});

  final AgentRowData agent;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final ref = paneRef(agent.key);
    final sel = rowSelect(context, ref);
    void pick({bool feedback = true}) {
      if (feedback) Haptics.tick();
      context.read<BoardSelection?>()?.toggle(ref);
    }

    final swipeable = agent.status == AgentStatus.done && !agent.stale && !sel.active;
    bool review() => markReviewedWithUndo(context, agent.machine, agent.paneId);

    final row = SwipeToReview(
      enabled: swipeable,
      onReviewed: review,
      inset: Gap.md,
      child: SelectableRowFrame(
        state: sel,
        child: ReviewAction(
          enabled: swipeable,
          onReviewed: review,
          child: ListRow(
            // Staleness dims the row's glyph and softens its words (see ListRow.dim).
            leading: StatusGlyph(status: agent.status, size: IconSize.lead),
            title: agent.title,
            subtitle: agent.subtitle,
            titleMaxLines: 2,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StateTime(agent: agent),
                if (sel.active) ...[
                  const SizedBox(width: Gap.sm),
                  SelectMark(selected: sel.selected, size: IconSize.bar),
                ],
              ],
            ),
            dim: agent.stale,
            // Merged from the glyph and the texts, plus what dimming only implies.
            semanticLabel: agent.stale
                ? [agent.status.label, agent.title, if (agent.subtitle.isNotEmpty) agent.subtitle, 'offline'].join(', ')
                : null,
            onTap: sel.active
                ? pick
                : () {
                    Haptics.tick();
                    agent.machine.markReviewed(agent.paneId);
                    openAgent(context, PaneAgent(agent.machine.profile.id, agent.paneId));
                  },
            onLongPress: () => pick(feedback: false),
          ),
        ),
      ),
    );
    if (!divider) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        Hairline(indent: ListRow.textIndent()),
      ],
    );
  }
}

/// Large text or a narrow screen: the time label would squeeze the title to a
/// word, so it drops under the subtitle.
bool _stackTime(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) > 1.25 || MediaQuery.sizeOf(context).width < 340;
