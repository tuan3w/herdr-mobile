import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/acp/background/background_work.dart';
import '../../../data/repositories/agent_session.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/visible_text.dart';
import 'background_format.dart';

// What the background sheet and the subagent roster share: stopping a task from
// a sheet (one state machine, one set of controls), so a subagent is stopped
// the same way, with the same words, wherever the person finds it.

enum StopPhase { stopping, unconfirmed, finished }

class TaskStop {
  const TaskStop(this.phase, [this.reason]);

  final StopPhase phase;
  final String? reason;
}

/// What stopping is doing, per task key, for one open sheet. Kept in an object
/// of its own, not in the rows: a lazy list drops a row that scrolls away.
///
/// Stop is held (or primed by the assistive activation: the first activation
/// primes, the second stops). Accepted, it stays `Stopping…` until the task
/// leaves the running set; unconfirmed after [Dwell.stopConfirm].
class BackgroundStopper extends ChangeNotifier {
  BackgroundStopper(this.session);

  final AgentSessionView session;

  /// Per task key: what its stop is doing.
  final Map<String, TaskStop> stops = {};
  final Map<String, Timer> _timers = {};

  /// A task key (or [all]) the assistive activation primed.
  String? primed;
  Timer? _primeTimer;

  /// One sentence on what the last Stop all did; null before it.
  String? summary;

  bool _disposed = false;

  static const all = '\u0000all';

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void prime(String key) {
    Haptics.armed();
    _primeTimer?.cancel();
    primed = key;
    _notify();
    _primeTimer = Timer(Dwell.confirm, () {
      if (_disposed) return;
      primed = null;
      _notify();
    });
  }

  void clearPrime() {
    _primeTimer?.cancel();
    primed = null;
  }

  /// The assistive activation: the first primes, the second stops.
  void activate(BackgroundTask task) => primed == task.key ? stop(task) : prime(task.key);

  void _setStop(String key, TaskStop? stop) {
    _timers.remove(key)?.cancel();
    if (_disposed) return;
    if (stop == null) {
      stops.remove(key);
    } else {
      stops[key] = stop;
    }
    notifyListeners();
    if (stop?.phase == StopPhase.stopping) {
      _timers[key] = Timer(Dwell.stopConfirm, () {
        if (_disposed || stops[key]?.phase != StopPhase.stopping) return;
        if (!session.backgroundWork.running.any((t) => t.key == key)) return;
        Haptics.failed();
        _setStop(key, const TaskStop(StopPhase.unconfirmed));
      });
    }
  }

  void stop(BackgroundTask task) {
    clearPrime();
    _setStop(task.key, const TaskStop(StopPhase.stopping));
    unawaited(_ask(task));
  }

  Future<void> _ask(BackgroundTask task) async {
    final result = await session.stopBackground(task.id);
    if (_disposed) return;
    switch (result) {
      case BackgroundStopped():
        // Accepted: stays `Stopping…` until the task leaves the running set.
        Haptics.sent();
      case BackgroundAlreadyDone():
        _setStop(task.key, const TaskStop(StopPhase.finished));
      case BackgroundNotStoppable():
        _setStop(task.key, null);
      case BackgroundStopFailed(:final reason):
        Haptics.failed();
        _setStop(task.key, TaskStop(StopPhase.unconfirmed, reason));
    }
  }

  /// Stops [targets] with one request. [skipped] running tasks have no stop
  /// route (the summary says so); [only] limits the request to one kind.
  Future<void> stopAll({required List<BackgroundTask> targets, required int skipped, BackgroundKind? only}) async {
    clearPrime();
    for (final t in targets) {
      _setStop(t.key, const TaskStop(StopPhase.stopping));
    }
    summary = null;
    _notify();
    final result = await session.stopAllBackground(only: only);
    if (_disposed) return;
    switch (result) {
      case BackgroundStopped(:final asked):
        Haptics.sent();
        summary = stopAllSummary(stopped: targets.length, skipped: skipped, asked: asked);
        _notify();
      case BackgroundAlreadyDone():
        for (final t in targets) {
          _setStop(t.key, const TaskStop(StopPhase.finished));
        }
        summary = 'Already done';
        _notify();
      case BackgroundNotStoppable():
        for (final t in targets) {
          _setStop(t.key, null);
        }
        summary = 'Nothing here has a stop control';
        _notify();
      case BackgroundStopFailed(:final reason):
        Haptics.failed();
        for (final t in targets) {
          _setStop(t.key, const TaskStop(StopPhase.unconfirmed));
        }
        summary = visibleText(reason);
        _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _primeTimer?.cancel();
    super.dispose();
  }
}

/// The control at the end of a row whose task can be stopped (or whose stop
/// went wrong): `Stopping…`, `Retry`, or the held stop chip. Null once the task
/// turned out to be finished already.
Widget? stopControl(
  BuildContext context, {
  required BackgroundTask task,
  required String agentLabel,
  required TaskStop? stop,
  required bool primed,
  required VoidCallback onActivate,
  required VoidCallback onHold,
  required VoidCallback onRetry,
}) => switch (stop?.phase) {
  StopPhase.stopping => _StopStatus(label: context.l10n.uiStopping, semantic: 'Stopping ${visibleText(task.id)}'),
  StopPhase.unconfirmed => AppChip(
    label: context.l10n.uiRetry,
    semanticLabel: context.l10n.messageRetryStopping(visibleText(task.id)),
    onTap: onRetry,
  ),
  StopPhase.finished => null,
  null => AnswerChip(
    label: stopLabel(task.stop, agentLabel),
    wide: false,
    hold: true,
    holdVerb: 'Hold to stop',
    state: primed ? AnswerChipState.primed : AnswerChipState.rest,
    semanticLabel: stopSemantics(task, agentLabel, primed: primed),
    onTap: onActivate,
    onHeld: onHold,
  ),
};

/// The line under a row after a stop that did not go through (`Couldn’t
/// confirm`, `Already done`); null otherwise.
Widget? stopNote(BuildContext context, TaskStop? stop) {
  final ds = context.ds;
  final note = switch (stop?.phase) {
    StopPhase.unconfirmed => ('Couldn’t confirm', ds.dangerText, stop?.reason),
    StopPhase.finished => ('Already done', ds.done, null),
    _ => null,
  };
  if (note == null) return null;
  return Text(
    [note.$1, ?note.$3].join(' \u00b7 '),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: Type.captionStrong.copyWith(color: note.$2),
  );
}

/// `Stop all`, held: the one bulk stop. [count] is for the screen reader; the
/// sheet says how many in the header above it.
class StopAllChip extends StatelessWidget {
  const StopAllChip({super.key, required this.count, required this.primed, required this.onTap, required this.onHeld});

  final int count;
  final bool primed;
  final VoidCallback onTap;
  final VoidCallback onHeld;

  @override
  Widget build(BuildContext context) => AnswerChip(
    label: context.l10n.uiStopAll,
    tone: AnswerChipTone.danger,
    hold: true,
    holdVerb: 'Hold to stop all',
    state: primed ? AnswerChipState.primed : AnswerChipState.rest,
    maxLines: 1,
    semanticLabel: primed
        ? context.l10n.messageConfirmStopAllActivateAgainToConfirm('$count')
        : context.l10n.messageStopAllHoldToConfirm('$count'),
    onTap: onTap,
    onHeld: onHeld,
  );
}

/// `Running · 6`: a section header of a sheet's list.
class SectionHead extends StatelessWidget {
  const SectionHead(this.title, this.count, {super.key});

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.md, Gap.md, Gap.xs),
    child: Semantics(
      header: true,
      child: Text(
        '$title · $count',
        style: Type.labelStrong.copyWith(color: context.ds.textSecondary, fontFeatures: Type.tabular),
      ),
    ),
  );
}

/// `Show 50 more` / `Show less` under a capped section.
class ShowMoreRow extends StatelessWidget {
  const ShowMoreRow({super.key, required this.hidden, required this.open, required this.onTap});

  final int hidden;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: Gap.md),
    child: Align(
      alignment: Alignment.centerLeft,
      child: TextAction(
        label: open ? context.l10n.uiShowLess : context.l10n.messageShowMore('$hidden'),
        tone: TextActionTone.quiet,
        onTap: onTap,
      ),
    ),
  );
}

/// The quiet lines at the end of a sheet's list.
class SheetFooter extends StatelessWidget {
  const SheetFooter({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Gap.md, Gap.xs, Gap.md, Gap.md),
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

/// Why the phone asks instead of stopping: omp has no key that stops one job.
String messageRouteNote(String agentLabel) =>
    '$agentLabel has no stop key for this. The phone sends $agentLabel a message asking it to.';

const _chipHeight = 36.0;
const _chipMinWidth = 104.0;

/// 44 dp to touch around a chip that paints [_chipHeight].
Widget _touchBox(Widget chip) => ConstrainedBox(
  constraints: const BoxConstraints(minWidth: kMinTap, minHeight: kMinTap),
  child: Align(widthFactor: 1, heightFactor: 1, child: chip),
);

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
          decoration: BoxDecoration(color: ds.fill, borderRadius: BorderRadius.circular(Radii.sm)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const BusySpinner(),
              const SizedBox(width: Gap.sm),
              Text(label, maxLines: 1, style: Type.labelStrong.copyWith(color: ds.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
