import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/background/background_work.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/words/elapsed.dart';
import '../../../data/repositories/observed_session.dart' show ObservedAgentSession;

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/step_clock.dart';
import 'agent_session_navigation.dart';
import 'background_controls.dart';
import 'background_format.dart';
import 'session_select.dart';
import 'subagent_roster.dart' show showSubagents;
import '../../render/visible_text.dart';

/// Up to this many lines the sheet is as tall as its lines; past it, it is as
/// tall as a list sheet grows and the list is lazy (like the subagent roster).
const _shrinkWrapUntil = 8;

/// Longest first line a row shows of a command: more than a screen of it never
/// fits one line, and the rest is read by expanding the row.
const _titleChars = 300;

/// Lines of an opened command before `Read all`.
const _openLines = 6;

/// The background work of [session] as a sheet: what runs (with a stop per
/// task, held), what finished, one sentence on whether the agent resumes by
/// itself, and the footer that says what Stop on the message bar does.
Future<void> showBackgroundWork(BuildContext context, AgentSessionView session) =>
    showAppSheet<void>(context, builder: (_) => BackgroundSheet(session: session));

/// One toast after Stop, when the turn ended and work remains (`Turn stopped ·
/// 1 job still running`), with `Open` to open the sheet. Replaces a toast that
/// is showing.
void showBackgroundToast(BuildContext context, String text, {required VoidCallback onView}) =>
    showToast(context, text, action: ToastAction('Open', onView), duration: Dwell.toastAction);

sealed class _Item {
  const _Item();
}

class _Head extends _Item {
  const _Head(this.title, this.count);

  final String title;
  final int count;
}

class _TaskItem extends _Item {
  const _TaskItem(this.task);

  final BackgroundTask task;
}

class _More extends _Item {
  const _More(this.hidden, this.open);

  final int hidden;
  final bool open;
}

class _Note extends _Item {
  const _Note(this.text);

  final String text;
}

class BackgroundSheet extends StatefulWidget {
  const BackgroundSheet({super.key, required this.session});

  final AgentSessionView session;

  @override
  State<BackgroundSheet> createState() => _BackgroundSheetState();
}

class _BackgroundSheetState extends State<BackgroundSheet> {
  late final BackgroundStopper _stopper = BackgroundStopper(widget.session)..addListener(_changed);
  final Set<String> _open = {};
  final Set<String> _readAll = {};
  bool _moreFinished = false;

  AgentSessionView get _session => widget.session;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stopper.dispose();
    super.dispose();
  }

  // ---- stop ----------------------------------------------------------------

  /// Reads the work when the hold completes, not when the sheet was built: the
  /// list may have changed under the finger.
  void _stopAll() {
    final work = _session.backgroundWork;
    unawaited(_stopper.stopAll(targets: work.stoppable, skipped: work.running.length - work.stoppable.length));
  }

  // ---- rows ----------------------------------------------------------------

  bool _opensSubagent(BackgroundTask t) =>
      t.kind == BackgroundKind.agent &&
      t.isActive &&
      (_session.subagentRun(t.id) != null || _session.subagents.any((e) => e.name == t.id));

  void _openSubagent(BackgroundTask t) {
    final session = _session;
    final navigator = Navigator.of(context)..pop();
    // ignore: use_build_context_synchronously
    final outer = navigator.context;
    if (session.subagentRun(t.id) != null) {
      unawaited(openSubagentRun(outer, session, t.id));
    } else if (session is ObservedAgentSession) {
      unawaited(openSubagentChat(outer, session, t.id));
    } else {
      unawaited(showSubagents(outer, session));
    }
  }

  void _toggle(BackgroundTask t) => setState(() {
    if (!_open.remove(t.key)) _open.add(t.key);
  });

  List<_Item> _items(BackgroundWork work) {
    final running = work.running;
    final finished = finishedOrder(work.finished);
    final shown = _moreFinished ? finished : finished.take(finishedShown).toList();
    return [
      if (running.isNotEmpty) _Head('Running', running.length),
      for (final t in running) _TaskItem(t),
      if (running.isEmpty && work.unknownRunning)
        const _Note('Details are unavailable: the agent waits on something its log doesn’t list.'),
      if (finished.isNotEmpty) _Head('Done', finished.length),
      for (final t in shown) _TaskItem(t),
      if (finished.length > finishedShown) _More(finished.length - finishedShown, _moreFinished),
    ];
  }

  @override
  Widget build(BuildContext context) => SessionSelect<(BackgroundWork, bool)>(
    session: _session,
    select: (s) => (s.backgroundWork, s.link == AgentLink.live),
    same: (a, b) => identical(a.$1, b.$1) && a.$2 == b.$2,
    builder: (context, snap) {
      final (work, live) = snap;
      final ds = context.ds;
      final items = _items(work);
      final sentence = work.running.isEmpty ? null : wakeSentence(work);
      final stopAll =
          live &&
          work.stoppable.length >= 2 &&
          work.stoppable.any((t) => _stopper.stops[t.key]?.phase != StopPhase.stopping);
      final summary = _stopper.summary;
      final routeMessage = work.running.any((t) => t.stop == StopRoute.message);
      final agent = _session.agentLabel;
      // What comes before the tasks and after them scrolls with them: one
      // lazy list under the pinned title.
      final pre = [
        if (sentence != null)
          Padding(
            padding: const EdgeInsets.only(left: Gap.md, top: Gap.xs, right: Gap.md),
            child: Text(sentence, style: Type.secondary.copyWith(color: ds.textSecondary)),
          ),
        if (stopAll)
          Padding(
            padding: const EdgeInsets.only(left: Gap.md, top: Gap.md, right: Gap.md),
            child: StopAllChip(
              count: work.stoppable.length,
              primed: _stopper.primed == BackgroundStopper.all,
              onTap: () =>
                  _stopper.primed == BackgroundStopper.all ? _stopAll() : _stopper.prime(BackgroundStopper.all),
              onHeld: _stopAll,
            ),
          ),
        if (summary != null)
          Padding(
            padding: const EdgeInsets.only(left: Gap.md, top: Gap.sm, right: Gap.md),
            child: Text(summary, style: Type.secondary.copyWith(color: ds.textSecondary)),
          ),
      ];
      final post = [
        if (!live)
          const SheetFooter(lines: ['Not connected. This is the last known list.'])
        else if (work.hasRunning)
          SheetFooter(
            lines: [
              'Stop on the message bar ends the turn only. Work listed here keeps running until you stop it.',
              if (routeMessage) messageRouteNote(agent),
            ],
          ),
      ];
      Widget item(BuildContext context, int i) => switch (items[i]) {
        _Head(:final title, :final count) => SectionHead(title, count),
        _TaskItem(:final task) => _TaskRow(
          key: ValueKey(task.key),
          task: task,
          agentLabel: _session.agentLabel,
          live: live,
          expanded: _open.contains(task.key),
          readAll: _readAll.contains(task.key),
          stop: _stopper.stops[task.key],
          primed: _stopper.primed == task.key,
          opensSubagent: _opensSubagent(task),
          onTap: () => _opensSubagent(task) ? _openSubagent(task) : _toggle(task),
          onReadAll: () => setState(() => _readAll.add(task.key)),
          onActivate: () => _stopper.activate(task),
          onHold: () => _stopper.stop(task),
          onRetry: () => _stopper.stop(task),
        ),
        _More(:final hidden, :final open) => ShowMoreRow(
          hidden: hidden,
          open: open,
          onTap: () => setState(() => _moreFinished = !_moreFinished),
        ),
        _Note(:final text) => Padding(
          padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
          child: Text(text, style: Type.secondary.copyWith(color: ds.textMuted)),
        ),
      };
      return SheetScaffold(
        title: work.runningCount == 0 ? 'Background work' : 'Background work · ${work.runningCount}',
        kind: SheetKind.list,
        scrolls: items.isNotEmpty,
        child: items.isEmpty
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...pre,
                  const EmptyState.inline(
                    'Nothing is running in the background.',
                    padding: EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.lg),
                  ),
                  ...post,
                ],
              )
            : ListView.builder(
                shrinkWrap: items.length <= _shrinkWrapUntil,
                padding: const EdgeInsets.only(bottom: Gap.xs),
                itemCount: pre.length + items.length + post.length,
                itemBuilder: (context, i) => i < pre.length
                    ? pre[i]
                    : i < pre.length + items.length
                    ? item(context, i - pre.length)
                    : post[i - pre.length - items.length],
              ),
      );
    },
  );
}

/// The first non-empty line of [raw], cut to what a one-line title can show.
String firstLine(String raw) {
  for (final line in raw.split('\n')) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (t.length <= _titleChars) return t;
    final unit = t.codeUnitAt(_titleChars - 1);
    return t.substring(0, unit >= 0xD800 && unit <= 0xDBFF ? _titleChars - 1 : _titleChars);
  }
  return '';
}

IconData _icon(BackgroundKind kind) => switch (kind) {
  BackgroundKind.shell || BackgroundKind.terminal || BackgroundKind.eval => LucideIcons.squareTerminal,
  BackgroundKind.agent => HerdrIcons.agents,
  BackgroundKind.workflow => LucideIcons.workflow,
  BackgroundKind.monitor => LucideIcons.eye,
  BackgroundKind.other => LucideIcons.cog,
};

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.agentLabel,
    required this.live,
    required this.expanded,
    required this.readAll,
    required this.stop,
    required this.primed,
    required this.opensSubagent,
    required this.onTap,
    required this.onReadAll,
    required this.onActivate,
    required this.onHold,
    required this.onRetry,
  });

  final BackgroundTask task;
  final String agentLabel;
  final bool live;
  final bool expanded;
  final bool readAll;
  final TaskStop? stop;
  final bool primed;
  final bool opensSubagent;
  final VoidCallback onTap;
  final VoidCallback onReadAll;
  final VoidCallback onActivate;
  final VoidCallback onHold;
  final VoidCallback onRetry;

  Widget _meta(BuildContext context, DateTime? now) {
    final ds = context.ds;
    final base = Type.caption.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular);
    final parts = [kindWord(task.kind), shorten(visibleText(task.id), 20)];
    String? word;
    Color? tone;
    switch (task.status) {
      case BackgroundStatus.running:
        final start = task.startedAt;
        if (now != null && task.pastDeadline(now)) {
          word = 'ended?';
          tone = ds.textMuted;
        } else if (start != null && now != null) {
          parts.add(Elapsed.compact(now.difference(start)));
        }
      case BackgroundStatus.paused:
        word = 'paused';
        tone = ds.textMuted;
      case BackgroundStatus.finished:
        final start = task.startedAt;
        final end = task.endedAt;
        word = start != null && end != null ? 'done · ${Elapsed.compact(end.difference(start))}' : 'done';
        tone = ds.done;
      case BackgroundStatus.failed:
        word = 'failed';
        tone = ds.dangerText;
      case BackgroundStatus.stopped:
        word = 'stopped';
        tone = ds.dangerText;
    }
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: parts.join(' · ')),
          if (word != null) ...[
            const TextSpan(text: ' · '),
            TextSpan(
              text: word,
              style: Type.captionStrong.copyWith(color: tone, fontFeatures: Type.tabular),
            ),
          ],
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final active = task.isActive;
    final textColor = !active || !live ? ds.textSecondary : ds.text;
    final raw = task.title.trim().isEmpty ? task.id : task.title;
    final full = visibleText(expanded ? (task.detail?.trim().isNotEmpty ?? false ? task.detail! : raw) : '');
    final timed = active && task.startedAt != null;
    final meta = timed
        ? MinuteBuilder(builder: (context, now) => _meta(context, now))
        : _meta(context, active ? DateTime.now() : null);
    final canStop = active && live && task.stop != StopRoute.none;
    final phase = stop?.phase;
    final noteLine = stopNote(context, stop);
    final Widget? trailing = !canStop && phase != StopPhase.unconfirmed
        ? (opensSubagent ? Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary) : null)
        : stopControl(
            context,
            task: task,
            agentLabel: agentLabel,
            stop: stop,
            primed: primed,
            onActivate: onActivate,
            onHold: onHold,
            onRetry: onRetry,
          );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: PressRow(
            onTap: onTap,
            padding: const EdgeInsets.only(left: Gap.md - PressRow.inset, top: Gap.sm, bottom: Gap.sm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: RowMetrics.leadingExtent,
                  child: Padding(
                    padding: const EdgeInsets.only(top: Gap.hair),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: Icon(_icon(task.kind), size: IconSize.bar, color: live ? ds.textSecondary : ds.textMuted),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (expanded)
                        // Read all comes last: its touch area stays out of the words.
                        _OpenText(
                          text: full,
                          style: Mono.input.copyWith(color: textColor),
                          all: readAll,
                          onReadAll: onReadAll,
                          after: [meta, ?noteLine],
                        )
                      else ...[
                        Text(
                          visibleText(firstLine(raw)).isEmpty ? visibleText(task.id) : visibleText(firstLine(raw)),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: Mono.input.copyWith(color: textColor),
                        ),
                        meta,
                        ?noteLine,
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (trailing != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.sm, right: Gap.sm),
            child: trailing,
          ),
      ],
    );
  }
}

/// An opened command: [_openLines] lines, [after] it (the meta line), then
/// `Read all` when the text is longer.
class _OpenText extends StatelessWidget {
  const _OpenText({
    required this.text,
    required this.style,
    required this.all,
    required this.onReadAll,
    required this.after,
  });

  final String text;
  final TextStyle style;
  final bool all;
  final VoidCallback onReadAll;
  final List<Widget> after;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        var cut = false;
        if (!all) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: _openLines,
          )..layout(maxWidth: box.maxWidth);
          cut = painter.didExceedMaxLines;
          painter.dispose();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              text,
              maxLines: all ? null : _openLines,
              overflow: all ? TextOverflow.clip : TextOverflow.ellipsis,
              style: style,
            ),
            ...after,
            if (cut) TextAction(label: 'Read all', onTap: onReadAll),
          ],
        );
      },
    );
  }
}
