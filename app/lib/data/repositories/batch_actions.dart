import 'dart:async';

import '../acp/agent_host.dart' show AgentHostException;
import '../models/herdr_models.dart';
import '../services/herdr_api.dart';
import '../services/herdr_transport.dart';
import 'agent_session.dart';
import 'machine_connection.dart';

/// What the board can do to several agents at once.
enum BatchAction {
  /// A terminal agent gets the `esc` key (what the pane's Esc chip sends), an
  /// agent session its `cancel()`. Working agents only.
  interrupt('Interrupted'),

  /// One text to everyone: `pane.send_input` for a terminal (the way the pane
  /// composer sends a line), a prompt for an agent session.
  message('Messaged'),

  /// Closes the pane, ends the session. Finished or idle agents only.
  close('Closed');

  const BatchAction(this.past);

  /// "Interrupted", for the result line.
  final String past;
}

enum BatchKind { terminal, session }

/// One agent a batch may touch, as it is right now, with the three things that
/// can be done to it. The closures are the only code that talks to a machine,
/// so a plan and its run can be tested without one.
class BatchTarget {
  const BatchTarget({
    required this.key,
    required this.kind,
    required this.machineId,
    required this.machineLabel,
    required this.title,
    required this.agent,
    required this.status,
    required this.interrupt,
    required this.message,
    required this.close,
    this.unreachable,
    this.settle,
  });

  /// A herdr pane. [status] is what the board shows (a reviewed finished
  /// agent is idle).
  factory BatchTarget.terminal({
    required MachineConnection machine,
    required String paneId,
    required String title,
    required String agent,
    required AgentStatus status,
  }) =>
      BatchTarget(
        key: '${machine.profile.id}/$paneId',
        kind: BatchKind.terminal,
        machineId: machine.profile.id,
        machineLabel: machine.profile.label,
        title: title,
        agent: agent,
        status: status,
        unreachable: machine.isLive ? null : 'offline',
        interrupt: () => machine.api.sendKeys(paneId, const ['esc']),
        message: (text) async {
          await machine.api.sendLine(paneId, text);
          machine.markReviewed(paneId);
        },
        close: () async {
          try {
            await machine.api.closePane(paneId);
          } on HerdrApiException catch (e) {
            // Already gone is what the person wanted.
            if (!e.isNotFound) rethrow;
          }
        },
        settle: machine.refresh,
      );

  /// An agent session. [status] is the board's status for it.
  ///
  /// A prompt is started, not awaited: `send` returns when the turn is over,
  /// which would hold every later target of the machine for minutes. It never
  /// throws, and only a live, idle session is sent one (see [BatchPlan.of]).
  factory BatchTarget.session({
    required AgentSessionView session,
    required AgentStatus status,
  }) {
    final machine = session.machine;
    return BatchTarget(
      key: session.key,
      kind: BatchKind.session,
      machineId: machine.profile.id,
      machineLabel: machine.profile.label,
      title: session.title,
      agent: session.agentLabel,
      status: status,
      unreachable: !machine.isLive
          ? 'offline'
          : switch (session.link) {
              AgentLink.live => null,
              AgentLink.connecting => 'connecting',
              AgentLink.reconnecting => 'reconnecting',
              AgentLink.ended => 'ended',
              AgentLink.failed => 'not connected',
            },
      interrupt: () async => session.cancel(),
      message: (text) async => unawaited(session.send(text)),
      close: session.end,
    );
  }

  /// Stable across refreshes: `<machineId>/<paneId>` or the session's key.
  final String key;
  final BatchKind kind;
  final String machineId;
  final String machineLabel;
  final String title;

  /// `claude`, `Claude Code`.
  final String agent;
  final AgentStatus status;

  /// Why nothing can reach it (`offline`, `ended`, ...), null when it can.
  final String? unreachable;

  /// `agent · machine`.
  String get detail => agent.isEmpty ? machineLabel : '$agent · $machineLabel';

  final Future<void> Function() interrupt;
  final Future<void> Function(String text) message;
  final Future<void> Function() close;

  /// Run once when the machine's targets are done (a fresh listing, so the
  /// board shows what is really there). Failures are ignored.
  final Future<void> Function()? settle;
}

enum SkipKind {
  /// The machine or the session cannot be reached. Never attempted.
  unreachable,

  /// A prompt or a question is open: typed text would answer it.
  waiting,

  /// The status does not suit the action.
  ineligible,
}

/// A selected agent that an action leaves alone, and why.
class BatchSkip {
  const BatchSkip(this.target, this.kind, this.reason, {this.canSendAnyway = false});

  final BatchTarget target;
  final SkipKind kind;

  /// "offline", "not working", "waiting for an answer".
  final String reason;

  /// A message may still be typed into it, on the person's say so.
  final bool canSendAnyway;
}

/// Which of the [targets] an [action] touches and which it skips. Order is
/// kept: it is the order the board shows, and the order each machine is run.
class BatchPlan {
  const BatchPlan._(this.action, this.run, this.skipped);

  /// [sendAnyway] lets a message reach terminal agents that show a prompt
  /// (they are skipped otherwise). Agent sessions waiting for a permission or
  /// a question never take one: the session refuses a prompt while a request
  /// is open.
  factory BatchPlan.of(BatchAction action, Iterable<BatchTarget> targets, {bool sendAnyway = false}) {
    final run = <BatchTarget>[];
    final skipped = <BatchSkip>[];
    for (final t in targets) {
      final skip = _skip(action, t, sendAnyway);
      if (skip == null) {
        run.add(t);
      } else {
        skipped.add(skip);
      }
    }
    return BatchPlan._(action, run, skipped);
  }

  final BatchAction action;
  final List<BatchTarget> run;
  final List<BatchSkip> skipped;

  /// The skipped agents that wait for an answer.
  List<BatchSkip> get waiting => [for (final s in skipped) if (s.kind == SkipKind.waiting) s];

  /// The skipped agents that are not [waiting].
  List<BatchSkip> get others => [for (final s in skipped) if (s.kind != SkipKind.waiting) s];

  static BatchSkip? _skip(BatchAction action, BatchTarget t, bool sendAnyway) {
    final why = t.unreachable;
    if (why != null) return BatchSkip(t, SkipKind.unreachable, why);
    const waiting = 'waiting for an answer';
    switch (action) {
      case BatchAction.interrupt:
        return switch (t.status) {
          AgentStatus.working => null,
          AgentStatus.blocked => BatchSkip(t, SkipKind.waiting, waiting),
          AgentStatus.unknown => BatchSkip(t, SkipKind.ineligible, 'status unknown'),
          AgentStatus.idle || AgentStatus.done => BatchSkip(t, SkipKind.ineligible, 'not working'),
        };
      case BatchAction.close:
        return switch (t.status) {
          AgentStatus.idle || AgentStatus.done => null,
          AgentStatus.working => BatchSkip(t, SkipKind.ineligible, 'still working'),
          AgentStatus.blocked => BatchSkip(t, SkipKind.waiting, waiting),
          AgentStatus.unknown => BatchSkip(t, SkipKind.ineligible, 'status unknown'),
        };
      case BatchAction.message:
        switch (t.kind) {
          case BatchKind.terminal:
            if (t.status == AgentStatus.blocked && !sendAnyway) {
              return BatchSkip(t, SkipKind.waiting, waiting, canSendAnyway: true);
            }
            return null;
          case BatchKind.session:
            return switch (t.status) {
              AgentStatus.blocked => BatchSkip(t, SkipKind.waiting, waiting),
              AgentStatus.working => BatchSkip(t, SkipKind.ineligible, 'still working'),
              _ => null,
            };
        }
    }
  }
}

/// One target that failed, with words for the person.
class BatchFailure {
  const BatchFailure(this.target, this.message);

  final BatchTarget target;
  final String message;
}

/// What a run did.
class BatchResult {
  const BatchResult({
    required this.action,
    required this.done,
    required this.failed,
    required this.skipped,
  });

  final BatchAction action;
  final List<BatchTarget> done;
  final List<BatchFailure> failed;
  final List<BatchSkip> skipped;

  /// `Interrupted 3 · 1 failed: studio-mac: connection lost · 2 skipped`.
  String get summary {
    final parts = ['${action.past} ${done.length}'];
    if (failed.isNotEmpty) {
      final causes = <String>{
        for (final f in failed) '${f.target.machineLabel}: ${f.message}',
      }.toList();
      final shown = causes.take(2).join('; ');
      final more = causes.length > 2 ? ' (+${causes.length - 2} more)' : '';
      parts.add('${failed.length} failed: $shown$more');
    }
    if (skipped.isNotEmpty) parts.add('${skipped.length} skipped');
    return parts.join(' · ');
  }
}

/// Runs [plan]: the targets of one machine one after the other in plan order,
/// the machines side by side. A target that fails is recorded and the rest go
/// on. [text] is the message, passed on as it is.
Future<BatchResult> runBatch(BatchPlan plan, {String text = ''}) async {
  if (plan.action == BatchAction.message && text.trim().isEmpty) {
    throw ArgumentError.value(text, 'text', 'a message needs some text');
  }
  final run = plan.run;
  final errors = List<String?>.filled(run.length, null);
  final lanes = <String, List<int>>{};
  for (final (i, t) in run.indexed) {
    lanes.putIfAbsent(t.machineId, () => []).add(i);
  }

  Future<void> lane(List<int> indexes) async {
    for (final i in indexes) {
      try {
        await switch (plan.action) {
          BatchAction.interrupt => run[i].interrupt(),
          BatchAction.message => run[i].message(text),
          BatchAction.close => run[i].close(),
        };
      } on Exception catch (e) {
        errors[i] = _words(e);
      }
    }
    final settle = [for (final i in indexes) run[i].settle].nonNulls.firstOrNull;
    if (settle == null) return;
    try {
      await settle().timeout(const Duration(seconds: 5));
    } on Exception {
      // Offline or slow: the machine's events bring the lists up to date.
    }
  }

  await Future.wait([for (final indexes in lanes.values) lane(indexes)]);

  return BatchResult(
    action: plan.action,
    done: [for (final (i, t) in run.indexed) if (errors[i] == null) t],
    failed: [
      for (final (i, t) in run.indexed)
        if (errors[i] case final message?) BatchFailure(t, message),
    ],
    skipped: plan.skipped,
  );
}

String _words(Exception e) {
  final text = switch (e) {
    HerdrUnsupportedException() => 'this herdr cannot do that, update it',
    HerdrApiException(:final message) => message,
    HerdrTransportException(:final message) => message,
    AgentHostException(:final message) => message,
    TimeoutException() => 'no answer in time',
    _ => e.toString(),
  };
  return text.isEmpty ? 'failed' : text;
}
