import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart' show AgentPhase;
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/data/observed/background_view.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;

import 'support/fake_log_source.dart';
import 'support/fake_transport.dart';

/// The fake log's own entry time (`_stamp` of fake_log_source.dart).
final _logTime = DateTime.utc(2026, 10, 4, 10);

BackgroundTask _task(
  String id, {
  BackgroundKind kind = BackgroundKind.shell,
  BackgroundStatus status = BackgroundStatus.running,
  Duration? deadline,
  DateTime? startedAt,
  int epoch = 0,
}) => BackgroundTask(
  id: id,
  epoch: epoch,
  kind: kind,
  status: status,
  title: 'job $id',
  startedAt: startedAt,
  deadline: deadline,
  stop: StopRoute.message,
);

BackgroundView _derive(
  AgentStatus? herdr, {
  required bool turnEnded,
  List<BackgroundTask> tasks = const [],
  DateTime? now,
  Set<String> watched = const {},
}) => BackgroundView.derive(
  herdr: herdr,
  turnEnded: turnEnded,
  tasks: tasks,
  now: now ?? DateTime.utc(2026, 10, 4, 12),
  wakeLabel: 'omp',
  watchedRunning: watched,
);

/// A bash call that went to the background, as omp logs it.
List<String> _bgStart(String n, String command, {Object? timeout}) => [
  toolCallLine('a$n', 'c$n', 'bash', {'command': command}),
  toolResultLine(
    'r$n',
    'c$n',
    'bash',
    'Backgrounded as job bg_$n',
    details: {
      'async': {'state': 'running', 'jobId': 'bg_$n', 'type': 'bash'},
      'timeoutSeconds': ?timeout,
    },
  ),
];

void main() {
  group('a background terminal outlives the agent\'s turn', () {
    final proc = [_task('proc27850', kind: BackgroundKind.terminal)];

    test('an idle agent does not make it ended; a gone agent does', () {
      final alive = BackgroundView.derive(herdr: AgentStatus.idle, turnEnded: true, tasks: proc, now: DateTime.utc(2026, 10, 4, 12), wakeLabel: 'Codex', wakes: false);
      expect(alive.work.running.map((t) => t.id), ['proc27850']);

      final gone = BackgroundView.derive(herdr: AgentStatus.idle, turnEnded: true, tasks: proc, now: DateTime.utc(2026, 10, 4, 12), wakeLabel: 'Codex', wakes: false, agentGone: true);
      expect(gone.work.running, isEmpty);
    });
  });

  group('BackgroundView.derive: herdr status x turnEnded x tasks (the States table)', () {
    final running = [_task('bg_6')];

    test('turn over, herdr working, a job runs: waiting; omp wakes by itself', () {
      final v = _derive(AgentStatus.working, turnEnded: true, tasks: running);
      expect(v.waiting, isTrue);
      expect(v.work.running.map((t) => t.id), ['bg_6']);
      expect((v.work.wakes, v.work.wakeLabel, v.work.unknownRunning), (true, 'omp', false));
    });

    test('turn over, herdr working, nothing listed: waiting with details unavailable', () {
      for (final tasks in [<BackgroundTask>[], [_task('bg_1', status: BackgroundStatus.finished)]]) {
        final v = _derive(AgentStatus.working, turnEnded: true, tasks: tasks);
        expect(v.waiting, isTrue);
        expect(v.work.unknownRunning, isTrue);
        expect(v.work.hasRunning, isTrue);
        expect(v.work.running, isEmpty);
        expect(v.work.tasks.length, tasks.length);
      }
    });

    test('a normal turn (herdr working, the log mid-turn): tasks listed, not waiting', () {
      final v = _derive(AgentStatus.working, turnEnded: false, tasks: running);
      expect(v.waiting, isFalse);
      expect(v.work.running.length, 1);
      expect(v.work.unknownRunning, isFalse);
      expect(_derive(AgentStatus.working, turnEnded: false).work, same(BackgroundWork.empty));
    });

    test('herdr idle or done and the turn over: nothing can wake the agent, so a running task is ended?', () {
      for (final s in [AgentStatus.idle, AgentStatus.done]) {
        final v = _derive(s, turnEnded: true, tasks: running);
        expect(v.waiting, isFalse, reason: '$s');
        expect(v.work.running, isEmpty);
        expect(v.work.hasRunning, isFalse);
        final t = v.work.tasks.single;
        expect((t.id, t.status, t.stop, t.endedAt), ('bg_6', BackgroundStatus.stopped, StopRoute.none, null));
        expect(v.work.stoppable, isEmpty);
      }
    });

    test('herdr idle but the log has not caught up (turn not over): left as the log says', () {
      final v = _derive(AgentStatus.idle, turnEnded: false, tasks: running);
      expect(v.waiting, isFalse);
      expect(v.work.running.length, 1);
    });

    test('blocked, unknown and out of reach never wait and keep the list', () {
      for (final s in [AgentStatus.blocked, AgentStatus.unknown, null]) {
        for (final ended in [true, false]) {
          final v = _derive(s, turnEnded: ended, tasks: running);
          expect(v.waiting, isFalse, reason: '$s $ended');
          expect(v.work.running.length, 1, reason: '$s $ended');
        }
      }
    });

    test('a subagent the roster confirms running is not ended? even with herdr idle', () {
      final agents = [_task('Alpha', kind: BackgroundKind.agent), _task('Beta', kind: BackgroundKind.agent), _task('bg_2')];
      final v = _derive(AgentStatus.idle, turnEnded: true, tasks: agents, watched: {'Alpha', 'bg_2'});
      expect(v.work.running.map((t) => t.id), ['Alpha'], reason: 'only a subagent can be vouched for');
      expect(v.work.byId('Beta')!.status, BackgroundStatus.stopped);
      expect(v.work.byId('bg_2')!.status, BackgroundStatus.stopped);
    });

    test('past its deadline plus grace is ended?, whatever herdr says; before it, running', () {
      final start = DateTime.utc(2026, 10, 4, 10);
      final t = _task('bg_1', startedAt: start, deadline: const Duration(seconds: 60));
      for (final s in [AgentStatus.working, AgentStatus.blocked, null]) {
        final late = _derive(s, turnEnded: false, tasks: [t], now: start.add(const Duration(seconds: 121)));
        expect(late.work.running, isEmpty, reason: '$s');
        expect(late.work.byId('bg_1')!.status, BackgroundStatus.stopped);
        final early = _derive(s, turnEnded: false, tasks: [t], now: start.add(const Duration(seconds: 119)));
        expect(early.work.running.length, 1, reason: '$s');
      }
      final waiting = _derive(AgentStatus.working, turnEnded: true, tasks: [t], now: start.add(const Duration(hours: 1)));
      expect(waiting.waiting, isTrue);
      expect(waiting.work.unknownRunning, isTrue, reason: 'herdr still says working: something is awaited');
    });

    test('tasks that did not change stay the same list; sameAs compares content', () {
      final tasks = [_task('bg_1'), _task('bg_2', status: BackgroundStatus.finished)];
      final a = _derive(AgentStatus.working, turnEnded: false, tasks: tasks);
      expect(a.work.tasks, same(tasks));
      final b = _derive(AgentStatus.working, turnEnded: false, tasks: [...tasks]);
      expect(a.sameAs(b), isTrue);
      expect(a.sameAs(_derive(AgentStatus.working, turnEnded: true, tasks: tasks)), isFalse, reason: 'waiting differs');
      expect(a.sameAs(_derive(AgentStatus.working, turnEnded: false, tasks: [tasks.first])), isFalse);
      expect(BackgroundView.none.sameAs(_derive(null, turnEnded: false)), isTrue);
    });

    test('many tasks and a hostile title do not matter to the decision', () {
      final many = [for (var i = 0; i < 40; i++) _task('bg_$i')];
      final v = _derive(AgentStatus.working, turnEnded: true, tasks: many);
      expect((v.work.running.length, v.work.stoppable.length, v.waiting), (40, 40, true));
    });
  });

  group('ObservedAgentSession: the log, herdr and the clock', () {
    Future<(ObservedRig, ObservedAgentSession)> open(
      List<String> lines, {
      String status = 'working',
      DateTime Function()? clock,
    }) async {
      final rig = await ObservedRig.create(status: status);
      addTearDown(rig.dispose);
      rig.source.write(lines);
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: ompKind,
        source: rig.source,
        mapper: OmpLogMapper.new,
        previews: rig.previews,
        clock: clock ?? DateTime.now,
      );
      addTearDown(session.dispose);
      session.acquire();
      await eventually(() => session.link == AgentLink.live, reason: 'log followed');
      return (rig, session);
    }

    // The screenshot case: bg_6 started, the turn ended with stop, herdr says
    // working because omp keeps its loader up while it waits for the job.
    final waitingLog = [
      sessionLine(),
      userLine('u1', 'run it'),
      ..._bgStart('6', 'while [ ! -s \$F ]; do sleep 120; done'),
      assistantLine('a9', 'bg_6 runs; I will wait.'),
    ];

    test('the first batch of an open reaches the screen at once, whatever the notify interval', () async {
      final rig = await ObservedRig.create(status: 'idle');
      addTearDown(rig.dispose);
      rig.source.write(waitingLog);
      // With the old trailing timer nothing could be told before 5 s.
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: ompKind,
        source: rig.source,
        mapper: OmpLogMapper.new,
        previews: rig.previews,
        notifyEvery: const Duration(seconds: 5),
      );
      addTearDown(session.dispose);
      var shown = 0;
      session.addListener(() {
        if (session.state.items.isNotEmpty && session.link == AgentLink.live) shown++;
      });
      session.acquire();
      await eventually(() => shown > 0, timeout: const Duration(seconds: 2), reason: 'the transcript told to the screen');
    });

    test('herdr working, turn over, bg_6 running: waiting, phase still working, wakes', () async {
      final (_, s) = await open(waitingLog);
      expect(s.phase, AgentPhase.working, reason: 'phase stays herdr-derived');
      expect(s.waitingOnBackground, isTrue);
      final w = s.backgroundWork;
      expect(w.running.map((t) => t.key), ['0/bg_6']);
      expect((w.wakes, w.wakeLabel, w.unknownRunning), (true, 'omp', false));
      expect(w.running.single.title, 'while [ ! -s \$F ]; do sleep 120; done');
      expect(w.running.single.startedAt, _logTime);
      expect(w.stoppable.length, 1);
    });

    test('the same instance until something changes', () async {
      final (rig, s) = await open(waitingLog);
      final first = s.backgroundWork;
      expect(s.backgroundWork, same(first));
      await rig.setStatus('working');
      expect(s.backgroundWork, same(first), reason: 'a status that did not change');
      rig.source.push([finishedLine('f1', 'bg_6')]);
      await eventually(() => s.backgroundWork.running.isEmpty, reason: 'async-result applied');
      final second = s.backgroundWork;
      expect(second, isNot(same(first)));
      expect(s.backgroundWork, same(second));
      expect(second.tasks.single.status, BackgroundStatus.finished);
    });

    test('herdr working and the log mid-turn (the notice woke the agent): a normal turn', () async {
      final (_, s) = await open([...waitingLog, finishedLine('f1', 'bg_6')]);
      expect(s.waitingOnBackground, isFalse);
      expect(s.phase, AgentPhase.working);
      expect(s.backgroundWork.running, isEmpty);
      final (_, other) = await open([...waitingLog, userLine('u2', 'and then?')]);
      expect(other.waitingOnBackground, isFalse, reason: 'a message from the person starts a turn');
      expect(other.backgroundWork.running.length, 1, reason: 'the job is still listed');
    });

    test('herdr idle and the turn over: the job is ended?, not counted, nothing waits', () async {
      final (_, s) = await open(waitingLog, status: 'idle');
      expect(s.phase, AgentPhase.idle);
      expect(s.waitingOnBackground, isFalse);
      expect(s.backgroundWork.running, isEmpty);
      expect(s.backgroundWork.hasRunning, isFalse);
      expect(s.backgroundWork.tasks.single.status, BackgroundStatus.stopped);
      expect(await s.stopBackground('bg_6'), isA<BackgroundAlreadyDone>());
    });

    test('herdr blocked: not waiting', () async {
      final (_, s) = await open(waitingLog, status: 'blocked');
      expect(s.waitingOnBackground, isFalse);
      expect(s.backgroundWork.running.length, 1);
    });

    test('nothing in the log but herdr working after a finished turn: waiting, details unavailable', () async {
      final (_, s) = await open([sessionLine(), userLine('u1', 'hi'), assistantLine('a1', 'done')]);
      expect(s.waitingOnBackground, isTrue);
      expect(s.backgroundWork.tasks, isEmpty);
      expect(s.backgroundWork.unknownRunning, isTrue);
      expect(s.backgroundWork.wakeLabel, 'omp');
    });

    test('nothing in the log, a turn in progress: no work at all', () async {
      final (_, s) = await open([sessionLine(), userLine('u1', 'hi')]);
      expect(s.waitingOnBackground, isFalse);
      expect(s.backgroundWork, same(BackgroundWork.empty));
    });

    test('a herdr status change recomputes both answers and tells the listeners', () async {
      final (rig, s) = await open(waitingLog);
      expect(s.waitingOnBackground, isTrue);
      var told = 0;
      s.addListener(() => told++);

      await rig.setStatus('idle');
      await eventually(() => told > 0, reason: 'listeners told');
      expect(s.waitingOnBackground, isFalse);
      expect(s.backgroundWork.running, isEmpty);

      final before = told;
      await rig.setStatus('working');
      await eventually(() => told > before, reason: 'told again');
      expect(s.waitingOnBackground, isTrue);
      expect(s.backgroundWork.running.length, 1, reason: 'the log still lists it: the stop was a guess');
    });

    test('a new log line that changes only the task list tells the listeners', () async {
      final (rig, s) = await open([sessionLine(), userLine('u1', 'go'), ..._bgStart('1', 'sleep 1')]);
      var told = 0;
      s.addListener(() => told++);
      rig.source.push([waitLine('w1', {'bg_1': 'completed'})]);
      await eventually(() => told > 0, reason: 'told');
      expect(s.backgroundWork.tasks.single.status, BackgroundStatus.finished);
    });

    test('a job past its deadline is expired by the injected clock', () async {
      var now = _logTime.add(const Duration(seconds: 30));
      final (_, s) = await open([
        sessionLine(),
        userLine('u1', 'go'),
        ..._bgStart('1', 'sleep 40', timeout: 60),
        assistantLine('a9', 'waiting'),
      ], clock: () => now);
      expect(s.backgroundWork.running.length, 1);
      final before = s.backgroundWork;
      now = _logTime.add(const Duration(seconds: 119));
      expect(s.backgroundWork, same(before));
      now = _logTime.add(const Duration(seconds: 121));
      expect(s.backgroundWork.running, isEmpty);
      expect(s.backgroundWork.unknownRunning, isTrue, reason: 'herdr still says working');
      expect(s.waitingOnBackground, isTrue);
    });

    test('the session of a subagent has no background work', () async {
      final (rig, parent) = await open(waitingLog);
      final sub = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: ompKind,
        source: FakeLogSource(),
        mapper: OmpLogMapper.new,
        parent: parent,
        subagentName: 'Alpha',
      );
      addTearDown(sub.dispose);
      expect(sub.backgroundWork, same(BackgroundWork.empty));
      expect(sub.waitingOnBackground, isFalse);
      expect(await sub.stopBackground('bg_6'), isA<BackgroundAlreadyDone>());
    });

    group('stopBackground', () {
      test('asks omp, in the composer\'s way, with exactly the stop message; no key goes', () async {
        final (rig, s) = await open(waitingLog);
        final result = await s.stopBackground('bg_6');
        expect(result, isA<BackgroundStopped>().having((r) => r.asked, 'asked', isTrue));
        expect(rig.sent('pane.send_input'), [
          {
            'pane_id': 'w1:p1',
            'text': 'Stop these background job now: bg_6 (write proc://bg_6/kill). Do nothing else.',
            'keys': ['enter'],
          },
        ]);
        expect(rig.sent('pane.send_keys'), isEmpty);
        expect(rig.sent('pane.send_text'), isEmpty);
        expect(s.waitingOnBackground, isTrue, reason: 'nothing is confirmed until the log says so');
      });

      test('an id the log does not list, or that has ended, is already done and sends nothing', () async {
        final (rig, s) = await open([...waitingLog, finishedLine('f1', 'bg_6')]);
        expect(await s.stopBackground('bg_6'), isA<BackgroundAlreadyDone>());
        expect(await s.stopBackground('bg_77'), isA<BackgroundAlreadyDone>());
        expect(await s.stopBackground(''), isA<BackgroundAlreadyDone>());
        expect(rig.sent('pane.send_input'), isEmpty);
      });

      test('a hostile id from the log is listed but never sent', () async {
        final (rig, s) = await open([
          sessionLine(),
          userLine('u1', 'go'),
          ..._bgStart('1', 'sleep 1'),
          toolCallLine('ax', 'cx', 'bash', {'command': 'x'}),
          toolResultLine('rx', 'cx', 'bash', 'Backgrounded', details: {
            'async': {'state': 'running', 'jobId': 'bg_1; rm -rf ~', 'type': 'bash'},
          }),
          assistantLine('a9', 'waiting'),
        ]);
        expect(s.backgroundWork.running.map((t) => t.id), ['bg_1', 'bg_1; rm -rf ~']);
        expect(await s.stopBackground('bg_1; rm -rf ~'), isA<BackgroundNotStoppable>());
        expect(rig.sent('pane.send_input'), isEmpty);

        final all = await s.stopAllBackground();
        expect(all, isA<BackgroundStopped>());
        final text = rig.sent('pane.send_input').single['text'] as String;
        expect(text, 'Stop these background job now: bg_1 (write proc://bg_1/kill). Do nothing else.');
        expect(text, isNot(contains('rm -rf')));
      });

      test('stop all: one message naming every running job, in order', () async {
        final (rig, s) = await open([
          sessionLine(),
          userLine('u1', 'go'),
          ..._bgStart('1', 'a'),
          ..._bgStart('2', 'b'),
          ..._bgStart('3', 'c'),
          waitLine('w1', {'bg_2': 'completed'}),
          assistantLine('a9', 'waiting'),
        ]);
        final result = await s.stopAllBackground();
        expect(result, isA<BackgroundStopped>());
        expect(rig.sent('pane.send_input').map((p) => p['text']), [
          'Stop these background jobs now: bg_1 (write proc://bg_1/kill), bg_3 (write proc://bg_3/kill). Do nothing else.',
        ]);
      });

      test('stop all with nothing running is already done', () async {
        final (rig, s) = await open([sessionLine(), userLine('u1', 'go'), assistantLine('a1', 'ok')]);
        expect(await s.stopAllBackground(), isA<BackgroundAlreadyDone>());
        expect(rig.sent('pane.send_input'), isEmpty);
      });

      test('a pane that waits for the person refuses, and the reason comes back', () async {
        final (rig, s) = await open(waitingLog, status: 'blocked');
        final result = await s.stopBackground('bg_6');
        expect(result, isA<BackgroundStopFailed>().having((r) => r.reason, 'reason', isNotEmpty));
        expect(rig.sent('pane.send_input'), isEmpty);
      });

      test('an unreachable machine fails with the transport\'s reason, never throws', () async {
        final (rig, s) = await open(waitingLog);
        rig.transport.failure = const HerdrTransportException('The link dropped.');
        final result = await s.stopBackground('bg_6');
        expect(result, isA<BackgroundStopFailed>().having((r) => r.reason, 'reason', 'The link dropped.'));
      });

      test('cancel() still sends Esc only', () async {
        final (rig, s) = await open(waitingLog);
        s.cancel();
        await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'esc sent');
        expect(rig.sent('pane.send_keys').single['keys'], ['esc']);
        expect(rig.sent('pane.send_input'), isEmpty);
      });
    });
  });
}

/// An `async-result` notice for [job] (shape of the real log).
String finishedLine(String id, String job) => _line({
  'type': 'custom_message',
  'id': id,
  'customType': 'async-result',
  'content': '<system-notice>\nBackground job $job has completed. Resume your work using the result below.\nok\n</system-notice>',
  'timestamp': '2026-10-04T10:05:00.000Z',
  'details': {
    'jobs': [
      {'jobId': job, 'type': 'bash', 'label': job, 'durationMs': 5},
    ],
  },
});

/// A `wait` result that reports [jobs] (id -> status).
String waitLine(String id, Map<String, String> jobs) => toolResultLine(
  id,
  'w$id',
  'wait',
  '## Completed',
  details: {
    'op': 'wait',
    'jobs': [for (final e in jobs.entries) {'id': e.key, 'type': 'bash', 'status': e.value}],
  },
);

String _line(Map<String, Object?> e) => jsonEncode(e);
