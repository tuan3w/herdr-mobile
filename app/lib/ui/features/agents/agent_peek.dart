import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../../../data/decision/permission_evidence.dart' show lastAgentSentence;
import '../../../data/models/herdr_models.dart' show AgentStatus;
import '../../../data/models/pane_preview.dart';
import '../../../data/repositories/pane_previews.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'agent_card.dart' show StateTime;
import 'agent_session_rows.dart' show SessionStateTime, blockedSummary, sessionMeta;
import 'agents_grouping.dart';

/// The agent a swipe between agents leads to, as the board's row shows it:
/// status glyph, title (up to two lines, as on the board), what it asks or
/// last said ([peekLine]), where it runs and how long it has been in its
/// state, and its place in the walk ([position] of [count]). A glance, not
/// the row. Once letting go would go there ([PeekArmed]), the place says so.
///
/// [fromLeft] (a swipe right, to the previous agent): the card comes in from
/// the left, so it is laid out the other way round, glyph and title at its
/// right edge. Whichever side it enters from, what shows first is who it is.
class AgentPeekCard extends StatelessWidget {
  const AgentPeekCard({
    super.key,
    required this.item,
    required this.fromLeft,
    required this.position,
    required this.count,
  });

  final BoardItem item;
  final bool fromLeft;
  final int position;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final (status, title, where, time, dim) = switch (item) {
      PaneItem(:final row) => (row.status, row.title, row.subtitle, StateTime(agent: row) as Widget, row.stale),
      SessionItem(:final session) => (
        boardStatus(session),
        session.title,
        sessionMeta(session),
        SessionStateTime(session: session) as Widget,
        false,
      ),
    };
    final line = peekLine(context, item);
    final align = fromLeft ? TextAlign.end : TextAlign.start;
    final titleStyle = Type.row.copyWith(color: ds.text);
    final lineStyle = Type.secondary.copyWith(color: status == AgentStatus.blocked ? ds.text : ds.textSecondary);
    final whereStyle = Type.secondary.copyWith(color: ds.textSecondary);
    Widget oneLine(String text, TextStyle style) => Padding(
      padding: const EdgeInsets.only(top: Gap.hair),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: align, style: style),
    );
    final children = [
      StatusGlyph(status: status, size: IconSize.lead, dim: dim),
      const SizedBox(width: Gap.md),
      Expanded(
        // A short content area (a small phone, large text, the keyboard up)
        // drops lines, least needed first: the title's second line, where it
        // runs, what it says, then its place in the walk. The title stays.
        child: LayoutBuilder(
          builder: (context, box) {
            final scaler = MediaQuery.textScalerOf(context);
            double tall(TextStyle style) => scaler.scale(style.fontSize!) * style.height!;
            final place = Gap.xs + tall(Type.caption);
            final shown = _fit(box.maxHeight, title: tall(titleStyle), [
              place,
              if (line != null) Gap.hair + tall(lineStyle),
              if (where.isNotEmpty) Gap.hair + tall(whereStyle),
              tall(titleStyle),
            ]);
            var at = 0;
            final withPlace = shown > at++;
            final withLine = line != null && shown > at++;
            final withWhere = where.isNotEmpty && shown > at++;
            final twoLines = shown > at;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: fromLeft ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: twoLines ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: align,
                  style: titleStyle,
                ),
                if (withLine) oneLine(line, lineStyle),
                if (withWhere) oneLine(where, whereStyle),
                if (withPlace) _WalkPlace(position: position, count: count, align: align),
              ],
            );
          },
        ),
      ),
      const SizedBox(width: Gap.sm),
      time,
    ];
    return Row(children: fromLeft ? children.reversed.toList() : children);
  }
}

/// How many of [extras] (heights, most needed first) fit in [room] under a
/// title of height [title].
int _fit(double room, List<double> extras, {required double title}) {
  var used = title;
  var n = 0;
  for (final extra in extras) {
    if (used + extra > room) break;
    used += extra;
    n++;
  }
  return n;
}

/// The one line a peek shows of what [item] is doing or asking, from what is
/// already in memory: the question it waits on (a pane's prompt, a session's
/// request), else the last thing it said (a pane's last terminal row, a
/// session's last sentence). Null when nothing is known. Never read for the
/// peek: a glance must not cost the radio or the battery.
String? peekLine(BuildContext context, BoardItem item) {
  final line = switch (item) {
    PaneItem(:final row) => _paneLine(context.read<PanePreviews?>()?.known(row.machine.profile.id, row.paneId)),
    SessionItem(:final session) =>
      boardStatus(session) == AgentStatus.blocked ? blockedSummary(session) : lastAgentSentence(session.state.items),
  };
  final one = line?.replaceAll(_space, ' ').trim();
  return one == null || one.isEmpty ? null : one;
}

final _space = RegExp(r'\s+');

String? _paneLine(PanePreview? preview) {
  if (preview == null) return null;
  if (preview.prompt case final prompt?) return prompt.question;
  for (final line in preview.lines.reversed) {
    if (line.text.trim().isNotEmpty) return line.text;
  }
  return null;
}

/// The stop's place in the walk ("2 of 4"); once letting go would go there,
/// "Let go to open" in its place, so the card says what the tint means.
class _WalkPlace extends StatelessWidget {
  const _WalkPlace({required this.position, required this.count, required this.align});

  final int position;
  final int count;
  final TextAlign align;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final armed = PeekArmed.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Gap.xs),
      child: Text(
        armed ? 'Let go to open' : '$position of $count',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        style: armed
            ? Type.captionStrong.copyWith(color: ds.accentText)
            : Type.caption.copyWith(color: ds.textMuted, fontFeatures: Type.tabular),
      ),
    );
  }
}

/// What a swipe past either end of the walk shows: that there is nothing
/// there. Quiet: it is not news, only where the walk ends.
class AgentPeekEnd extends StatelessWidget {
  const AgentPeekEnd({super.key, required this.next, this.working = 0});

  /// The swipe asked for the next agent (else the previous one).
  final bool next;

  /// Agents working now, said at the end of the walk.
  final int working;

  @override
  Widget build(BuildContext context) => Text(
    peekEndWords(next: next, working: working),
    maxLines: 1,
    style: Type.label.copyWith(color: context.ds.textMuted),
  );
}

/// What the end card says; the `Next agent` / `Previous agent` actions
/// announce the same at either end. Past the last stop nothing else wants the
/// person: it says so, and what is still going on without them.
String peekEndWords({required bool next, int working = 0}) => !next
    ? 'No previous agent'
    : working == 0
    ? 'All caught up'
    : 'All caught up · $working working';

/// Whether letting go now goes where the peek shows (the finger is past the
/// commit distance): [PeekFrame] says it to the card it holds.
class PeekArmed extends InheritedWidget {
  const PeekArmed({super.key, required this.armed, required super.child});

  final bool armed;

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<PeekArmed>()?.armed ?? false;

  @override
  bool updateShouldNotify(PeekArmed oldWidget) => oldWidget.armed != armed;
}

/// The card a peek sits on: the floating lanes' look (surface, hairline, the
/// one float shadow), so it reads as something over the screen, not part of
/// it. [armed] (letting go now goes there) tints it with the accent and gives
/// it the armed edge, as a primed answer has one: letting go acts, so it must
/// not be missed under the thumb. The card it holds hears it ([PeekArmed]).
class PeekFrame extends StatelessWidget {
  const PeekFrame({super.key, required this.armed, required this.child});

  final bool armed;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return AnimatedContainer(
      duration: Motion.of(context, Motion.fade),
      curve: Motion.easeOut,
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: armed ? Color.alphaBlend(ds.accentWash, ds.surface) : ds.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: armed ? ds.armedEdge(ds.accent) : ds.hairline),
        boxShadow: ds.floatShadow,
      ),
      child: PeekArmed(armed: armed, child: child),
    );
  }
}
