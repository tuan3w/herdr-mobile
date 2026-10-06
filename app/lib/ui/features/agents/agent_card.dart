import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/agent_screens.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/step_clock.dart';
import '../../core/tap_guard.dart';
import '../../core/theme.dart';
import 'agent_navigation.dart';
import 'agents_grouping.dart';
import 'quick_reply_controller.dart';
import 'reply_chips.dart';
import 'reply_sheet.dart';
import 'board_selection.dart';
import 'swipe_review.dart';

/// Rows of terminal a card previews, by what the agent is doing. A working
/// agent gets the most (the stream is the signal), a finished one shows how it
/// ended, an idle one shows nothing: a prompt box and a status bar are noise.
int previewRowCount(AgentStatus status) => switch (status) {
      AgentStatus.working || AgentStatus.blocked => 5,
      AgentStatus.done => 3,
      AgentStatus.idle || AgentStatus.unknown => 0,
    };

/// Terminal preview text: small, mono, no ligatures (a `->` stays two glyphs
/// wide, as in the real terminal).
const previewFontSize = 11.0;
const previewHeightFactor = 1.38;
const previewTextStyle = TextStyle(
  fontFamily: monoFamily,
  fontSize: previewFontSize,
  height: previewHeightFactor,
  fontFeatures: [FontFeature.disable('liga'), FontFeature.disable('calt')],
);

/// What a prompt is about (the command, the URL, the path), a notch larger
/// than [previewTextStyle] because it is what an approval is read from. The
/// caller adds the colour.
const promptSubjectStyle = TextStyle(
  fontFamily: monoFamily,
  fontSize: 12.5,
  height: 1.35,
  fontFeatures: [FontFeature.disable('liga'), FontFeature.disable('calt')],
);

/// One agent as a board card: what it is doing (task, where, how long), a calm
/// live look at the end of its terminal, and, when it is blocked on a prompt
/// the app understands, the question, what it is about (the command) and
/// one-tap answers.
///
/// The card's height depends only on its status and the prompt (its question,
/// its subject and its option count), never on how many lines have arrived or
/// on the state of the chips, so the board does not jump while a preview fills
/// in. It watches its pane's preview only while it is built (a virtualised
/// list builds the ones near the screen) and releases on dispose.
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

class _AgentCardState extends State<AgentCard> with SingleTickerProviderStateMixin, TapGuardState<AgentCard> {
  // Created on the first arrival, like the glyph's: a card that never gets
  // news carries one null field.
  AnimationController? _arrival;
  late final PanePreviews _previews;
  PreviewHandle? _handle;
  QuickReplyController? _reply;
  PromptInfo? _sentFor;

  /// The question the chips answer, null while the card shows none: a
  /// different one arms the guard again.
  PromptInfo? _shown;

  AgentRowData get _agent => widget.agent;
  bool get _wantsPreview => previewRowCount(_agent.status) > 0;

  @override
  void initState() {
    super.initState();
    _previews = context.read<PanePreviews>();
    _syncWatch();
    // The guard is already armed: the card, and its answers, just appeared.
    _shown = _promptIn(_handle?.preview.value);
  }

  @override
  void didUpdateWidget(AgentCard old) {
    super.didUpdateWidget(old);
    _syncWatch();
    _syncShown();
    final news = widget.agent.status == AgentStatus.blocked || widget.agent.status == AgentStatus.done;
    if (news && old.agent.status != widget.agent.status && !Motion.reduced(context)) {
      // The card changed section: a faint accent wash that fades finds it.
      (_arrival ??= AnimationController(vsync: this, duration: Motion.arrival)).forward(from: 0);
    }
  }

  void _syncWatch() {
    if (_wantsPreview && _handle == null) {
      _handle = _previews.watch(_agent.machine.profile.id, _agent.paneId)..preview.addListener(_onPreview);
    } else if (!_wantsPreview && _handle != null) {
      _releaseWatch();
    }
  }

  void _releaseWatch() {
    _handle?.preview.removeListener(_onPreview);
    _handle?.release();
    _handle = null;
  }

  /// The question the card shows from [preview]: only a live blocked agent's.
  PromptInfo? _promptIn(PanePreview? preview) =>
      _agent.status == AgentStatus.blocked && !_agent.stale ? preview?.prompt : null;

  /// A question arrived, changed (a new one after `Sent` included) or came
  /// back with the link: its answers are new under the thumb, so they are
  /// deaf and dimmed for `tapGuard`. Runs before the rebuild that draws them.
  void _syncShown() {
    final prompt = _promptIn(_handle?.preview.value);
    if (prompt == _shown) return;
    _shown = prompt;
    if (prompt != null) rearmGuard();
  }

  void _onPreview() {
    _syncShown();
    // A new question while "Sent" is showing: the answer did something and the
    // agent asked again, so show the new chips now instead of after the hold.
    final reply = _reply;
    if (reply == null || reply.phase != ReplyPhase.sent) return;
    if (_handle?.preview.value?.prompt != _sentFor) reply.reset();
  }

  /// The card changed height (it grows as a question arrives, a line above
  /// the question wraps): its answers, pinned to its bottom, moved under the
  /// thumb. Called during layout, so the dimmed redraw waits for the frame.
  bool _onResize(SizeChangedLayoutNotification _) {
    if (_shown == null) return true;
    final wasSettled = settled;
    rearmGuard();
    if (wasSettled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
    return true;
  }

  QuickReplyController get _controller => _reply ??=
      QuickReplyController(machine: _agent.machine, paneId: _agent.paneId, previews: _previews);

  /// Neither the card's own guard nor the board's (`SettleGate`) is open: the
  /// answers moved or changed a moment ago.
  bool get _unsettled => !settled || (context.read<SettleGate?>()?.closed ?? false);

  /// The chips are deaf while unsettled; this refuses too, so no path to an
  /// answer skips the guard. [asked] is the question the chips were drawn for.
  Future<void> _choose(PromptInfo asked, QuickReply r) async {
    if (_unsettled) return;
    _sentFor = asked;
    await _controller.choose(r, asked: asked);
  }

  void _more() {
    if (!_unsettled) _openSheet();
  }

  @override
  void dispose() {
    _releaseWatch();
    _reply?.dispose();
    _arrival?.dispose();
    super.dispose();
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
    final handle = _handle;
    return AnimatedBuilder(
      animation: _arrival ?? kAlwaysDismissedAnimation,
      builder: (context, _) => handle == null
          ? _build(context, null)
          : ValueListenableBuilder<PanePreview?>(
              valueListenable: handle.preview,
              builder: (context, preview, _) => _build(context, preview),
            ),
    );
  }

  Widget _build(BuildContext context, PanePreview? preview) {
    final ds = context.ds;
    final sel = rowSelect(context, paneRef(_agent.key));
    final a = _agent;
    final prompt = _promptIn(preview);
    final rows = previewRowCount(a.status);
    final shown = prompt == null ? math.max(rows, 0) : 0;
    final slim = rows == 0;
    final chips = prompt == null ? 0 : ReplyChips.count(prompt);
    final chipsHeight = ReplyChips.heightFor(chips);
    final canReply = !a.stale;
    // The answers are deaf and dimmed while they are new under the thumb: the
    // card's own guard (its question changed, or it grew) or the board's gate
    // (a card above them came or went, see `SettleGate`).
    final guarded = context.select<SettleGate?, bool>((g) => g?.closed ?? false) || !settled;

    // A blocked card is the same card as any other: the glyph, the section
    // and the orange question wash already say so (a tinted card with an
    // orange outline was the fourth statement of it).
    final wash = _arrival == null ? 0.0 : 1 - _arrival!.value;
    final base = wash > 0 ? Color.alphaBlend(ds.accent.withValues(alpha: 0.10 * wash), ds.surface) : ds.surface;
    final tint = sel.selected ? Color.alphaBlend(ds.accent.withValues(alpha: ds.isDark ? 0.14 : 0.08), base) : base;
    final edge = sel.selected ? ds.accent : ds.hairline;
    // A finished agent on a reachable machine can be marked reviewed without
    // opening it: by a swipe, or by the screen reader's "Mark reviewed".
    final swipeable = a.status == AgentStatus.done && !a.stale && !sel.active;
    bool review() => markReviewedWithUndo(context, a.machine, a.paneId);

    final body = AnimatedSize(
      // A question arriving or being answered changes what the card holds:
      // it grows or folds instead of snapping.
      duration: Motion.reduced(context) ? Duration.zero : Motion.expand,
      curve: Motion.easeOut,
      alignment: Alignment.topCenter,
      child: ReviewAction(
        enabled: swipeable,
        onReviewed: review,
        child: PressBuilder(
          onTap: sel.active ? _pick : _open,
          onLongPress: () => _pick(feedback: false),
          selected: sel.active ? sel.selected : null,
          semanticLabel: _semanticLabel(prompt),
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            padding: const EdgeInsets.fromLTRB(_pad, 12, _pad, _pad),
            decoration: BoxDecoration(
              color: pressed ? Color.alphaBlend(ds.fill.withValues(alpha: 0.6), tint) : tint,
              borderRadius: BorderRadius.circular(_radius),
              border: Border.all(color: edge),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(agent: a, showTime: !_stackTime(context)),
                Padding(
                  padding: EdgeInsets.only(left: _glyphColumn, right: slim && canReply ? 40 : 0),
                  child: _Subtitle(text: a.subtitle),
                ),
                if (_stackTime(context))
                  Padding(padding: const EdgeInsets.only(left: _glyphColumn), child: StateTime(agent: a)),
                if (!slim) const SizedBox(height: 10),
                if (prompt != null) ...[
                  _QuestionBlock(question: prompt.question, subject: prompt.subject),
                  SizedBox(height: 10 + chipsHeight),
                ] else if (shown > 0)
                  _PreviewPanel(
                    rows: shown,
                    lines: preview?.lines,
                    reserveReply: canReply,
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    Widget card = Stack(
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
                controller: _controller,
                onChoose: (r) => _choose(prompt, r),
                onMore: _more,
                guarded: guarded,
              ),
            ),
          ),
        if (canReply)
          Positioned(
            // The 44 hit box of the 32 circle ends at the panel's edge, so
            // the circle is painted 6 inside the panel.
            right: _pad,
            bottom: (slim ? 6 : _pad) + (prompt != null ? chipsHeight + 10 : 0),
            child: IgnorePointer(
              ignoring: sel.active,
              child: CircleButton(
                icon: LucideIcons.reply,
                tooltip: 'Reply to ${a.title}',
                size: 32,
                filled: false,
                onPressed: _openSheet,
              ),
            ),
          ),
        if (sel.active) Positioned(left: -4, top: -4, child: SelectMark(selected: sel.selected)),
      ],
    );
    card = NotificationListener<SizeChangedLayoutNotification>(onNotification: _onResize, child: card);
    // One Opacity layer for the (rare) stale card; none for a live one.
    if (a.stale) card = Opacity(opacity: 0.55, child: card);
    return SwipeToReview(
      enabled: swipeable,
      onReviewed: review,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: _margin, vertical: 5),
        child: card,
      ),
    );
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

  static const _pad = 14.0;
  static const _margin = 16.0;
  static const _radius = 14.0;

  /// Glyph (22) + gap (10): text starts here.
  static const _glyphColumn = 32.0;
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
          width: 22,
          height: math.max(titleLine, 22),
          child: Center(child: StatusGlyph(status: agent.status, size: 22)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            agent.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _titleStyle.copyWith(color: ds.text),
          ),
        ),
        if (showTime) ...[
          const SizedBox(width: 8),
          StateTime(agent: agent),
        ],
      ],
    );
  }

  static final _titleStyle = Type.row.copyWith(fontSize: 15.5);
}

/// "working 12m": tabular, by the minute, from one shared slow clock. After a
/// gap the start of a state is only a bound, and says so: "needs you ≤ 25m". A
/// working agent quiet for the connection's `quietAfter` says "quiet 14m"
/// instead, since that is the news; the number is the one the row was sorted
/// by (worked out at the machine's last refresh, never per event), so label
/// and order agree. Offline agents say so; an agent whose start is not known
/// at all claims nothing.
class StateTime extends StatelessWidget {
  const StateTime({super.key, required this.agent});

  final AgentRowData agent;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final blocked = agent.status == AgentStatus.blocked;
    TextStyle style() => Type.caption.copyWith(
          fontSize: 12.5,
          color: blocked ? ds.blockedText : ds.textMuted,
          fontFeatures: Type.tabular,
        );
    if (agent.stale) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text('offline', maxLines: 1, style: style()),
      );
    }
    if (agent.quietMinutes > 0) {
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          quietLabel(Duration(minutes: agent.quietMinutes)),
          maxLines: 1,
          softWrap: false,
          style: style(),
        ),
      );
    }
    final time = agent.machine.statusTime(agent.paneId);
    if (time == null) return const SizedBox.shrink();
    return MinuteBuilder(
      builder: (context, now) {
        final text = timeInState(agent.status, time.since(now), exact: time.exact);
        if (text.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(text, maxLines: 1, softWrap: false, style: style()),
        );
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
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Type.secondary.copyWith(color: context.ds.textSecondary),
      ),
    );
  }
}

/// The question a blocked agent asks, on a faint orange wash, and under it
/// what the question is about (the command, the path) in mono: the thing the
/// answer approves is always in front of the thumb that approves it.
class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({required this.question, required this.subject});

  final String question;
  final String subject;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      constraints: const BoxConstraints(minHeight: kMinTap),
      padding: const EdgeInsets.fromLTRB(12, 8, 44, 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: ds.blockedWash,
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            maxLines: subject.isEmpty ? 3 : 2,
            overflow: TextOverflow.ellipsis,
            style: Type.prompt.copyWith(color: ds.text),
          ),
          if (subject.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              subject,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: promptSubjectStyle.copyWith(color: ds.text),
            ),
          ],
        ],
      ),
    );
  }
}

/// The last few rows of a terminal in a calm inset panel. Fixed height for
/// [rows] lines (no jumping as lines arrive), text bottom-aligned, a soft fade
/// at the top, nothing wraps. `lines == null` is "still loading".
class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({required this.rows, required this.lines, required this.reserveReply});

  final int rows;
  final List<PreviewLine>? lines;

  /// Room at the right for the reply button that floats over the panel.
  final bool reserveReply;

  static const _style = previewTextStyle;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    // Terminal text is a picture of a screen: allow some scaling, not all.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.15);
    final line = scaler.scale(previewFontSize) * previewHeightFactor;
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
                    decoration: BoxDecoration(
                      color: ds.textTertiary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: const SizedBox(height: 7),
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
            Text(
              l.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textScaler: scaler,
              style: _style.copyWith(
                color: i == tail.length - 1 && last != null ? ds.text : ds.textSecondary,
              ),
            ),
        ],
      );
    }

    return ExcludeSemantics(
      child: Container(
        height: rows * line + 16,
        clipBehavior: Clip.hardEdge,
        decoration: BoxDecoration(
          color: ds.fill,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Padding(
                padding: EdgeInsets.fromLTRB(10, 8, reserveReply ? 40 : 10, 8),
                child: content,
              ),
            ),
            if (tail != null && tail.length >= rows)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 14,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [ds.fill, ds.fill.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
          ],
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

    return SwipeToReview(
      enabled: swipeable,
      onReviewed: review,
      inset: Gap.md,
      child: SelectableRowFrame(
        state: sel,
        child: ReviewAction(
          enabled: swipeable,
          onReviewed: review,
          child: ListRow(
            // Staleness dims the whole row once; the glyph is not dimmed again.
            leading: StatusGlyph(status: agent.status, size: 20),
            title: agent.title,
            subtitle: agent.subtitle,
            titleMaxLines: 2,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                StateTime(agent: agent),
                if (sel.active) ...[
                  const SizedBox(width: 6),
                  SelectMark(selected: sel.selected, size: 18),
                ],
              ],
            ),
            dim: agent.stale,
            divider: divider,
            // Merged from the glyph and the texts, plus what dimming only implies.
            semanticLabel: agent.stale
                ? [
                    agent.status.label,
                    agent.title,
                    if (agent.subtitle.isNotEmpty) agent.subtitle,
                    'offline',
                  ].join(', ')
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
  }
}

/// Large text or a narrow screen: the time label would squeeze the title to a
/// word, so it drops under the subtitle.
bool _stackTime(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) > 1.25 || MediaQuery.sizeOf(context).width < 340;
