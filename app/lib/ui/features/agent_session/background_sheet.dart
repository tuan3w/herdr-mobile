import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/acp/background/background_work.dart';
import '../../../data/repositories/agent_session.dart';
import '../../../data/repositories/observed_session.dart' show ObservedAgentSession;
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/hold_confirm.dart';
import '../../core/motion.dart';
import '../../core/step_clock.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'agent_session_navigation.dart';
import 'background_format.dart';
import 'permission_dock.dart' show confirmWindow;
import 'session_select.dart';
import 'subagent_roster.dart' show showSubagents;
import 'visible_text.dart';

/// How long `Stopping…` waits for the task to leave the running set before it
/// says it could not confirm.
const stopConfirmWindow = Duration(seconds: 12);

/// Up to this many lines the sheet is as tall as its lines; past it, it is two
/// thirds of the screen and the list is lazy (like the subagent roster).
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
/// 1 job still running`), with `View` to open the sheet. Replaces a toast that
/// is showing.
void showBackgroundToast(BuildContext context, String text, {required VoidCallback onView}) =>
    showToast(context, text, action: ToastAction('View', onView), duration: const Duration(seconds: 6));

enum _StopPhase { stopping, unconfirmed, finished }

class _Stop {
  const _Stop(this.phase, [this.reason]);

  final _StopPhase phase;
  final String? reason;
}

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
  /// Per task key: what its stop is doing. Kept here, not in the rows: a lazy
  /// list drops a row that scrolls away.
  final Map<String, _Stop> _stops = {};
  final Map<String, Timer> _timers = {};
  final Set<String> _open = {};
  final Set<String> _readAll = {};
  bool _moreFinished = false;

  /// A task key (or [_all]) the assistive activation primed.
  String? _primed;
  Timer? _primeTimer;
  String? _summary;

  static const _all = '\u0000all';

  AgentSessionView get _session => widget.session;

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _primeTimer?.cancel();
    super.dispose();
  }

  // ---- stop ----------------------------------------------------------------

  void _prime(String key) {
    Haptics.armed();
    _primeTimer?.cancel();
    setState(() => _primed = key);
    _primeTimer = Timer(confirmWindow, () {
      if (mounted) setState(() => _primed = null);
    });
  }

  void _clearPrime() {
    _primeTimer?.cancel();
    _primed = null;
  }

  /// The assistive activation: the first primes, the second stops.
  void _activate(BackgroundTask task) => _primed == task.key ? _stop(task) : _prime(task.key);

  void _setStop(String key, _Stop? stop) {
    _timers.remove(key)?.cancel();
    setState(() => stop == null ? _stops.remove(key) : _stops[key] = stop);
    if (stop?.phase == _StopPhase.stopping) {
      _timers[key] = Timer(stopConfirmWindow, () {
        if (!mounted || _stops[key]?.phase != _StopPhase.stopping) return;
        if (!_session.backgroundWork.running.any((t) => t.key == key)) return;
        Haptics.failed();
        _setStop(key, const _Stop(_StopPhase.unconfirmed));
      });
    }
  }

  void _stop(BackgroundTask task) {
    _clearPrime();
    Haptics.sent();
    _setStop(task.key, const _Stop(_StopPhase.stopping));
    unawaited(_ask(task));
  }

  Future<void> _ask(BackgroundTask task) async {
    final result = await _session.stopBackground(task.id);
    if (!mounted) return;
    switch (result) {
      case BackgroundStopped():
        // Stays `Stopping…` until the task leaves the running set.
        break;
      case BackgroundAlreadyDone():
        _setStop(task.key, const _Stop(_StopPhase.finished));
      case BackgroundNotStoppable():
        _setStop(task.key, null);
      case BackgroundStopFailed(:final reason):
        Haptics.failed();
        _setStop(task.key, _Stop(_StopPhase.unconfirmed, reason));
    }
  }

  Future<void> _stopAll() async {
    _clearPrime();
    final work = _session.backgroundWork;
    final targets = work.stoppable;
    final skipped = work.running.length - targets.length;
    Haptics.sent();
    for (final t in targets) {
      _setStop(t.key, const _Stop(_StopPhase.stopping));
    }
    setState(() => _summary = null);
    final result = await _session.stopAllBackground();
    if (!mounted) return;
    switch (result) {
      case BackgroundStopped(:final asked):
        setState(() => _summary = stopAllSummary(stopped: targets.length, skipped: skipped, asked: asked));
      case BackgroundAlreadyDone():
        for (final t in targets) {
          _setStop(t.key, const _Stop(_StopPhase.finished));
        }
        setState(() => _summary = 'Already finished');
      case BackgroundNotStoppable():
        for (final t in targets) {
          _setStop(t.key, null);
        }
        setState(() => _summary = 'Nothing here has a stop control');
      case BackgroundStopFailed(:final reason):
        Haptics.failed();
        for (final t in targets) {
          _setStop(t.key, const _Stop(_StopPhase.unconfirmed));
        }
        setState(() => _summary = visibleText(reason));
    }
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
        const _Note('Details are unavailable: the agent waits on something its log does not list.'),
      if (finished.isNotEmpty) _Head('Finished', finished.length),
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
      final stopAll = live && work.stoppable.length >= 2 && work.stoppable.any((t) => _stops[t.key]?.phase != _StopPhase.stopping);
      final summary = _summary;
      final list = ListView.builder(
        shrinkWrap: items.length <= _shrinkWrapUntil,
        padding: const EdgeInsets.fromLTRB(Gap.xs, 0, Gap.xs, Gap.xs),
        itemCount: items.length,
        itemBuilder: (context, i) => switch (items[i]) {
          _Head(:final title, :final count) => Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
            child: Semantics(
              header: true,
              child: Text(
                '$title · $count',
                style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600, fontFeatures: Type.tabular),
              ),
            ),
          ),
          _TaskItem(:final task) => _TaskRow(
            key: ValueKey(task.key),
            task: task,
            agentLabel: _session.agentLabel,
            live: live,
            expanded: _open.contains(task.key),
            readAll: _readAll.contains(task.key),
            stop: _stops[task.key],
            primed: _primed == task.key,
            opensSubagent: _opensSubagent(task),
            onTap: () => _opensSubagent(task) ? _openSubagent(task) : _toggle(task),
            onReadAll: () => setState(() => _readAll.add(task.key)),
            onActivate: () => _activate(task),
            onHold: () => _stop(task),
            onRetry: () => _stop(task),
          ),
          _More(:final hidden, :final open) => PressBuilder(
            onTap: () => setState(() => _moreFinished = !_moreFinished),
            builder: (context, pressed) => Container(
              constraints: const BoxConstraints(minHeight: kMinTap),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: Gap.md),
              child: Text(
                open ? 'Show fewer' : 'Show $hidden more',
                style: Type.label.copyWith(color: pressed ? ds.text : ds.textSecondary, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          _Note(:final text) => Padding(
            padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.sm),
            child: Text(text, style: Type.secondary.copyWith(color: ds.textMuted)),
          ),
        },
      );
      final routeMessage = work.running.any((t) => t.stop == StopRoute.message);
      final agent = _session.agentLabel;
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
              child: Semantics(
                header: true,
                child: Text(
                  work.runningCount == 0 ? 'Background work' : 'Background work · ${work.runningCount}',
                  style: Type.label.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
                ),
              ),
            ),
            if (sentence != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, 0),
                child: Text(sentence, style: Type.secondary.copyWith(color: ds.textSecondary)),
              ),
            if (stopAll)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, 0),
                child: _StopAllButton(
                  count: work.stoppable.length,
                  primed: _primed == _all,
                  onActivate: () => _primed == _all ? unawaited(_stopAll()) : _prime(_all),
                  onHold: () => unawaited(_stopAll()),
                ),
              ),
            if (summary != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, 0),
                child: Text(summary, style: Type.secondary.copyWith(color: ds.textSecondary)),
              ),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.lg),
                child: Text('Nothing is running in the background.', style: Type.secondary.copyWith(color: ds.textMuted)),
              )
            else if (items.length <= _shrinkWrapUntil)
              list
            else
              // Two thirds of the screen for the whole sheet: what is not the
              // list (header, sentence, Stop all, footer) comes off it.
              SizedBox(height: math.max(180.0, MediaQuery.sizeOf(context).height * 0.66 - 200), child: list),
            if (!live)
              _Footer(lines: const ['Not connected. This is the last known list.'])
            else if (work.hasRunning)
              _Footer(
                lines: [
                  'Stop on the message bar ends the turn only. Work listed here keeps running until you stop it.',
                  if (routeMessage) '$agent has no stop key for this. The phone sends $agent a message asking it to.',
                ],
              ),
          ],
        ),
      );
    },
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.xs, Gap.lg, Gap.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.xs),
            child: Text(line, style: Type.caption.copyWith(color: context.ds.textMuted)),
          ),
      ],
    ),
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
  BackgroundKind.agent => LucideIcons.bot,
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
  final _Stop? stop;
  final bool primed;
  final bool opensSubagent;
  final VoidCallback onTap;
  final VoidCallback onReadAll;
  final VoidCallback onActivate;
  final VoidCallback onHold;
  final VoidCallback onRetry;

  static TextStyle mono(Ds ds, Color color) =>
      TextStyle(fontFamily: monoFamily, fontSize: 13, height: 1.45, color: color);

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
          parts.add(backgroundElapsed(now.difference(start)));
        }
      case BackgroundStatus.paused:
        word = 'paused';
        tone = ds.textMuted;
      case BackgroundStatus.finished:
        final start = task.startedAt;
        final end = task.endedAt;
        word = start != null && end != null ? 'finished · ${backgroundElapsed(end.difference(start))}' : 'finished';
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
            TextSpan(text: word, style: TextStyle(color: tone, fontWeight: FontWeight.w600)),
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
    final note = switch (phase) {
      _StopPhase.unconfirmed => ('Could not confirm', ds.dangerText, stop?.reason),
      _StopPhase.finished => ('Already finished', ds.done, null),
      _ => null,
    };
    final Widget? noteLine = note == null
        ? null
        : Text(
            [note.$1, ?note.$3].join(' \u00b7 '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Type.caption.copyWith(color: note.$2, fontWeight: FontWeight.w600),
          );
    final Widget? trailing = !canStop && phase != _StopPhase.unconfirmed
        ? (opensSubagent ? Icon(LucideIcons.chevronRight, size: 14, color: ds.textTertiary) : null)
        : switch (phase) {
            _StopPhase.stopping => _StopStatus(label: 'Stopping…', semantic: 'Stopping ${visibleText(task.id)}'),
            _StopPhase.unconfirmed => _TapChip(
              label: 'Retry',
              semantic: 'Retry stopping ${visibleText(task.id)}',
              onTap: onRetry,
            ),
            _StopPhase.finished => null,
            null => _HoldChip(
              label: stopLabel(task.stop, agentLabel),
              semantic: stopSemantics(task, agentLabel, primed: primed),
              primed: primed,
              onActivate: onActivate,
              onHold: onHold,
            ),
          };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: PressBuilder(
            onTap: onTap,
            button: true,
            builder: (context, pressed) => AnimatedContainer(
              duration: Motion.pressing(pressed),
              curve: Motion.easeOut,
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.xs, Gap.sm),
              decoration: BoxDecoration(
                color: pressed ? ds.fill : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.row),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 32,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: Icon(_icon(task.kind), size: 18, color: live ? ds.textSecondary : ds.textMuted),
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
                            style: mono(ds, textColor),
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
                            style: mono(ds, textColor),
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
        ),
        if (trailing != null) Padding(padding: const EdgeInsets.only(top: 6, right: Gap.sm), child: trailing),
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
    final ds = context.ds;
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
            if (cut)
              PressBuilder(
                onTap: onReadAll,
                minTapSize: kMinTap,
                haptic: true,
                builder: (context, pressed) => Text(
                  'Read all',
                  style: Type.label.copyWith(color: pressed ? ds.text : ds.accentText, fontWeight: FontWeight.w600),
                ),
              ),
          ],
        );
      },
    );
  }
}

const _chipHeight = 36.0;
const _chipMinWidth = 104.0;

/// 44 dp to touch around a chip that paints [_chipHeight].
Widget _touchBox(Widget chip) => ConstrainedBox(
  constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
  child: Align(widthFactor: 1, heightFactor: 1, child: chip),
);

/// The held stop: the dock's pattern. A tap says how; a hold of 550 ms stops.
class _HoldChip extends StatelessWidget {
  const _HoldChip({
    required this.label,
    required this.semantic,
    required this.primed,
    required this.onActivate,
    required this.onHold,
  });

  final String label;
  final String semantic;
  final bool primed;
  final VoidCallback onActivate;
  final VoidCallback onHold;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return HoldToConfirm(
      semanticLabel: semantic,
      onActivate: onActivate,
      onConfirmed: onHold,
      builder: (context, hold) {
        final shown = hold.showsHold
            ? 'Hold to stop'
            : primed
            ? 'Hold or tap again'
            : label;
        final (bg, pressedBg, fg) = primed
            ? (ds.danger.withValues(alpha: 0.14), ds.danger.withValues(alpha: 0.24), ds.dangerText)
            : (ds.fill, ds.fillPressed, ds.text);
        return _touchBox(
          AnimatedContainer(
            duration: Motion.pressing(hold.holding),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minWidth: _chipMinWidth, minHeight: _chipHeight),
            decoration: BoxDecoration(
              color: hold.holding ? pressedBg : bg,
              borderRadius: BorderRadius.circular(Radii.chip),
            ),
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                hold.fill,
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.md),
                  child: Center(
                    widthFactor: 1,
                    heightFactor: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        shown,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Type.label.copyWith(color: fg, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// `Stopping…` with the one allowed spinner, until the task leaves running.
class _StopStatus extends StatelessWidget {
  const _StopStatus({required this.label, required this.semantic});

  final String label;
  final String semantic;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      label: semantic,
      excludeSemantics: true,
      child: _touchBox(
        Container(
          constraints: const BoxConstraints(minWidth: _chipMinWidth, minHeight: _chipHeight),
          padding: const EdgeInsets.symmetric(horizontal: Gap.md),
          decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.chip)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const BusySpinner(),
              const SizedBox(width: Gap.sm),
              Text(label, maxLines: 1, style: Type.label.copyWith(color: ds.textSecondary, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A plain tap chip: Retry. The person already held once for this task.
class _TapChip extends StatelessWidget {
  const _TapChip({required this.label, required this.semantic, required this.onTap});

  final String label;
  final String semantic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return PressBuilder(
      onTap: onTap,
      scale: 0.96,
      haptic: true,
      semanticLabel: semantic,
      minTapSize: kMinTap,
      builder: (context, pressed) => AnimatedContainer(
        duration: Motion.pressing(pressed),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minWidth: _chipMinWidth, minHeight: _chipHeight),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: Gap.md),
        decoration: BoxDecoration(
          color: pressed ? ds.fillPressed : ds.fill,
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: Text(label, maxLines: 1, style: Type.label.copyWith(color: ds.text, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// `Stop all`: a held, danger-toned button as wide as the sheet.
class _StopAllButton extends StatelessWidget {
  const _StopAllButton({required this.count, required this.primed, required this.onActivate, required this.onHold});

  final int count;
  final bool primed;
  final VoidCallback onActivate;
  final VoidCallback onHold;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return HoldToConfirm(
      semanticLabel: primed
          ? 'Confirm: Stop all $count, activate again to confirm'
          : 'Stop all $count, hold to confirm',
      onActivate: onActivate,
      onConfirmed: onHold,
      builder: (context, hold) => AnimatedContainer(
        duration: Motion.pressing(hold.holding),
        curve: Motion.easeOut,
        constraints: const BoxConstraints(minHeight: 46),
        decoration: BoxDecoration(
          color: ds.danger.withValues(alpha: hold.holding || primed ? 0.2 : 0.12),
          borderRadius: BorderRadius.circular(Radii.chip),
        ),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            hold.fill,
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                child: Text(
                  hold.showsHold
                      ? 'Hold to stop all'
                      : primed
                      ? 'Hold or tap again'
                      : 'Stop all',
                  maxLines: 1,
                  style: Type.button.copyWith(color: ds.dangerText, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
