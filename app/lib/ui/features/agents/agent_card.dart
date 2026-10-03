import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/models/herdr_models.dart';
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/pane_previews.dart';
import '../../core/controls.dart';
import '../../core/glyphs.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/step_clock.dart';
import '../../core/theme.dart';
import '../pane/pane_navigation.dart';
import 'agents_grouping.dart';
import 'quick_reply_controller.dart';
import 'reply_chips.dart';
import 'reply_sheet.dart';

/// Rows of terminal a card previews, by what the agent is doing. A working
/// agent gets the most (the stream is the signal), a finished one shows how it
/// ended, an idle one shows nothing: a prompt box and a status bar are noise.
int previewRowCount(AgentStatus status) => switch (status) {
      AgentStatus.working || AgentStatus.blocked => 3,
      AgentStatus.done => 2,
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

/// One agent as a board card: what it is doing (task, where, how long), a calm
/// live look at the end of its terminal, and, when it is blocked on a prompt
/// the app understands, the question with one-tap answers.
///
/// The card's height depends only on its status and the prompt's option count,
/// never on how many lines have arrived, so the board does not jump while a
/// preview fills in. It watches its pane's preview only while it is built (a
/// virtualised list builds the ones near the screen) and releases on dispose.
///
/// Semantics: the card body is ONE button that reads status, title, where, time
/// and the question; the reply button and the answer chips are separate nodes
/// above it, so they stay reachable.
class AgentCard extends StatefulWidget {
  const AgentCard({super.key, required this.agent});

  final AgentRowData agent;

  @override
  State<AgentCard> createState() => _AgentCardState();
}

class _AgentCardState extends State<AgentCard> {
  PreviewHandle? _handle;
  QuickReplyController? _reply;
  PromptInfo? _sentFor;

  AgentRowData get _agent => widget.agent;
  bool get _wantsPreview => previewRowCount(_agent.status) > 0;

  @override
  void initState() {
    super.initState();
    _syncWatch();
  }

  @override
  void didUpdateWidget(AgentCard old) {
    super.didUpdateWidget(old);
    _syncWatch();
  }

  void _syncWatch() {
    if (_wantsPreview && _handle == null) {
      _handle = context.read<PanePreviews>().watch(_agent.machine.profile.id, _agent.paneId)
        ..preview.addListener(_onPreview);
    } else if (!_wantsPreview && _handle != null) {
      _releaseWatch();
    }
  }

  void _releaseWatch() {
    _handle?.preview.removeListener(_onPreview);
    _handle?.release();
    _handle = null;
  }

  /// A new question while "Sent" is showing: the answer did something and the
  /// agent asked again, so show the new chips now instead of after the hold.
  void _onPreview() {
    final reply = _reply;
    if (reply == null || reply.phase != ReplyPhase.sent) return;
    if (_handle?.preview.value?.prompt != _sentFor) reply.reset();
  }

  QuickReplyController get _controller =>
      _reply ??= QuickReplyController(machine: _agent.machine, paneId: _agent.paneId);

  Future<void> _choose(QuickReply r) {
    _sentFor = _handle?.preview.value?.prompt;
    return _controller.choose(r);
  }

  @override
  void dispose() {
    _releaseWatch();
    _reply?.dispose();
    super.dispose();
  }

  void _open() {
    tapFeedback();
    openPaneTab(context, _agent.machine, _agent.paneId);
  }

  void _openSheet() => showReplySheet(context, key: _agent.key);

  @override
  Widget build(BuildContext context) {
    final handle = _handle;
    if (handle == null) return _build(context, null);
    return ValueListenableBuilder<PanePreview?>(
      valueListenable: handle.preview,
      builder: (context, preview, _) => _build(context, preview),
    );
  }

  Widget _build(BuildContext context, PanePreview? preview) {
    final ds = context.ds;
    final a = _agent;
    final blocked = a.status == AgentStatus.blocked;
    final prompt = blocked && !a.stale ? preview?.prompt : null;
    final rows = previewRowCount(a.status);
    final shown = prompt == null ? math.max(rows, 0) : 0;
    final slim = rows == 0;
    final chips = prompt == null ? 0 : ReplyChips.count(prompt);
    final chipsHeight = ReplyChips.heightFor(chips);
    final canReply = !a.stale;

    final tint = blocked
        ? Color.alphaBlend(ds.blocked.withValues(alpha: ds.isDark ? 0.07 : 0.05), ds.surface)
        : ds.surface;
    final edge = blocked ? ds.blocked.withValues(alpha: ds.isDark ? 0.55 : 0.5) : ds.hairline;

    final body = PressBuilder(
      onTap: _open,
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
              _QuestionBlock(question: prompt.question),
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
    );

    Widget card = Stack(
      children: [
        body,
        if (prompt != null)
          Positioned(
            left: _pad,
            right: _pad,
            bottom: _pad,
            height: chipsHeight,
            child: ReplyChips(
              prompt: prompt,
              controller: _controller,
              onChoose: _choose,
              onMore: _openSheet,
            ),
          ),
        if (canReply)
          Positioned(
            // The 44 hit box of the 32 circle ends at the panel's edge, so
            // the circle is painted 6 inside the panel.
            right: _pad,
            bottom: (slim ? 6 : _pad) + (prompt != null ? chipsHeight + 10 : 0),
            child: CircleButton(
              icon: LucideIcons.reply,
              tooltip: 'Reply to ${a.title}',
              size: 32,
              onPressed: _openSheet,
            ),
          ),
      ],
    );
    // One Opacity layer for the (rare) stale card; none for a live one.
    if (a.stale) card = Opacity(opacity: 0.55, child: card);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _margin, vertical: 5),
      child: card,
    );
  }

  String _semanticLabel(PromptInfo? prompt) => [
        _agent.status.label,
        _agent.title,
        if (_agent.subtitle.isNotEmpty) _agent.subtitle,
        if (_agent.stale) 'offline',
        if (prompt != null) 'Asks: ${prompt.question.replaceAll('\n', ' ')}',
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
          child: Center(child: StatusGlyph(status: agent.status, size: 22, animate: !agent.stale)),
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

/// "working 12m": tabular, by the minute, from one shared slow clock. Offline
/// agents say so instead; an agent we only just met has no known start, so
/// nothing is claimed.
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
    final since = agent.machine.statusSince(agent.paneId);
    if (since == null) return const SizedBox.shrink();
    return MinuteBuilder(
      builder: (context, now) {
        final text = timeInState(agent.status, now.difference(since));
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

/// The question a blocked agent asks, on a faint orange wash.
class _QuestionBlock extends StatelessWidget {
  const _QuestionBlock({required this.question});

  final String question;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Container(
      constraints: const BoxConstraints(minHeight: kMinTap),
      padding: const EdgeInsets.fromLTRB(12, 8, 44, 8),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: ds.blocked.withValues(alpha: ds.isDark ? 0.12 : 0.09),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        question,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: Type.body.copyWith(fontSize: 14, height: 1.35, color: ds.text, fontWeight: FontWeight.w500),
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
    final ds = context.ds;
    return ListRow(
      // Staleness dims the whole row once; the glyph is not dimmed again.
      leading: StatusGlyph(status: agent.status, size: 20, animate: !agent.stale),
      title: agent.title,
      subtitle: agent.subtitle,
      titleMaxLines: 2,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StateTime(agent: agent),
          const SizedBox(width: 6),
          Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
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
      onTap: () {
        tapFeedback();
        openPaneTab(context, agent.machine, agent.paneId);
      },
    );
  }
}

/// Large text or a narrow screen: the time label would squeeze the title to a
/// word, so it drops under the subtitle.
bool _stackTime(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) > 1.25 || MediaQuery.sizeOf(context).width < 340;
