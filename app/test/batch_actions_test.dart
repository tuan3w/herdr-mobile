// What a batch action touches and skips, and how a run goes: sequential per
// machine, machines side by side, one failure never stops the rest.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/batch_actions.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';

import 'support/fake_agent_session.dart';

/// A target whose three actions write to [log] (`start a1`, `done a1`, ...),
/// wait for [gate] when given, and throw [fail] when given.
BatchTarget _t(
  String key, {
  String machine = 'a',
  AgentStatus status = AgentStatus.working,
  BatchKind kind = BatchKind.terminal,
  String? unreachable,
  required List<String> log,
  Future<void>? gate,
  Object? fail,
  Future<void> Function()? settle,
  String title = 'refactor',
}) {
  Future<void> act(String what) async {
    log.add('start $what $key');
    if (gate != null) await gate;
    if (fail != null) throw fail;
    log.add('done $what $key');
  }

  return BatchTarget(
    key: key,
    kind: kind,
    machineId: machine,
    machineLabel: 'machine-$machine',
    title: title,
    agent: 'claude',
    status: status,
    unreachable: unreachable,
    interrupt: () => act('interrupt'),
    message: (text) => act('message[$text]'),
    close: () => act('close'),
    settle: settle,
  );
}

List<String> _keys(Iterable<BatchTarget> ts) => [for (final t in ts) t.key];

BatchPlan _plan(
  BatchAction action,
  AgentStatus status, {
  BatchKind kind = BatchKind.terminal,
  String? unreachable,
  bool sendAnyway = false,
}) =>
    BatchPlan.of(
      action,
      [_t('x', status: status, kind: kind, unreachable: unreachable, log: [])],
      sendAnyway: sendAnyway,
    );

void main() {
  group('interrupt', () {
    test('touches only working agents and says why the others are left', () {
      final reasons = {
        for (final s in AgentStatus.values)
          s: _plan(BatchAction.interrupt, s),
      };
      expect(reasons[AgentStatus.working]!.run, hasLength(1));
      expect(reasons[AgentStatus.idle]!.skipped.single.reason, 'not working');
      expect(reasons[AgentStatus.done]!.skipped.single.reason, 'not working');
      expect(reasons[AgentStatus.unknown]!.skipped.single.reason, 'status unknown');
      // Esc at a permission prompt would answer it, so a blocked agent is
      // left alone and listed as waiting.
      final blocked = reasons[AgentStatus.blocked]!;
      expect(blocked.run, isEmpty);
      expect(blocked.skipped.single.kind, SkipKind.waiting);
      expect(blocked.skipped.single.reason, 'waiting for an answer');
    });
  });

  group('close', () {
    test('touches only finished or idle agents', () {
      expect(_plan(BatchAction.close, AgentStatus.done).run, hasLength(1));
      expect(_plan(BatchAction.close, AgentStatus.idle).run, hasLength(1));
      expect(_plan(BatchAction.close, AgentStatus.working).skipped.single.reason, 'still working');
      expect(_plan(BatchAction.close, AgentStatus.unknown).skipped.single.reason, 'status unknown');
      final blocked = _plan(BatchAction.close, AgentStatus.blocked);
      expect(blocked.run, isEmpty);
      expect(blocked.skipped.single.kind, SkipKind.waiting);
    });
  });

  group('message', () {
    test('a terminal agent that shows a prompt is skipped unless "send anyway"', () {
      final off = _plan(BatchAction.message, AgentStatus.blocked);
      expect(off.run, isEmpty);
      expect(off.waiting.single.canSendAnyway, isTrue);
      expect(off.others, isEmpty);

      final on = _plan(BatchAction.message, AgentStatus.blocked, sendAnyway: true);
      expect(_keys(on.run), ['x']);
      expect(on.skipped, isEmpty);
    });

    test('every other status of a terminal agent gets the message, working included', () {
      for (final s in [AgentStatus.working, AgentStatus.idle, AgentStatus.done, AgentStatus.unknown]) {
        expect(_plan(BatchAction.message, s).run, hasLength(1), reason: '$s');
      }
    });

    test('"send anyway" never reaches an offline agent', () {
      final plan = _plan(BatchAction.message, AgentStatus.blocked, unreachable: 'offline', sendAnyway: true);
      expect(plan.run, isEmpty);
      expect(plan.skipped.single.kind, SkipKind.unreachable);
      expect(plan.skipped.single.reason, 'offline');
      expect(plan.waiting, isEmpty);
    });

    test('an agent session takes a prompt only when idle: it refuses one while a request is open', () {
      expect(_plan(BatchAction.message, AgentStatus.idle, kind: BatchKind.session).run, hasLength(1));
      expect(_plan(BatchAction.message, AgentStatus.done, kind: BatchKind.session).run, hasLength(1));
      final working = _plan(BatchAction.message, AgentStatus.working, kind: BatchKind.session);
      expect(working.run, isEmpty);
      expect(working.skipped.single.reason, 'still working');
      // The switch does not open a blocked session either.
      final blocked = _plan(BatchAction.message, AgentStatus.blocked, kind: BatchKind.session, sendAnyway: true);
      expect(blocked.run, isEmpty);
      expect(blocked.waiting.single.canSendAnyway, isFalse);
    });
  });

  test('unreachable targets are skipped first, whatever the action', () {
    for (final a in BatchAction.values) {
      final plan = _plan(a, AgentStatus.working, unreachable: 'offline');
      expect(plan.run, isEmpty, reason: '$a');
      expect(plan.skipped.single.kind, SkipKind.unreachable);
    }
  });

  test('a plan keeps the order it was given and splits the skipped', () {
    final log = <String>[];
    final plan = BatchPlan.of(BatchAction.close, [
      _t('1', status: AgentStatus.done, log: log),
      _t('2', status: AgentStatus.blocked, log: log),
      _t('3', status: AgentStatus.idle, log: log),
      _t('4', status: AgentStatus.working, log: log),
      _t('5', status: AgentStatus.done, unreachable: 'offline', log: log),
    ]);
    expect(_keys(plan.run), ['1', '3']);
    expect([for (final s in plan.skipped) s.target.key], ['2', '4', '5']);
    expect(_keys([for (final s in plan.waiting) s.target]), ['2']);
    expect(_keys([for (final s in plan.others) s.target]), ['4', '5']);
  });

  group('running', () {
    test('one machine in order, machines side by side', () async {
      final log = <String>[];
      final gateA = Completer<void>();
      final plan = BatchPlan.of(BatchAction.interrupt, [
        _t('a1', machine: 'a', log: log, gate: gateA.future),
        _t('b1', machine: 'b', log: log),
        _t('a2', machine: 'a', log: log),
        _t('b2', machine: 'b', log: log),
      ]);
      final run = runBatch(plan);
      await Future<void>.delayed(Duration.zero);
      // b ran to the end while a's first is still waiting, and a2 has not started.
      expect(log, contains('done interrupt b2'));
      expect(log, contains('start interrupt a1'));
      expect(log, isNot(contains('start interrupt a2')));
      expect(log.indexOf('done interrupt b1'), lessThan(log.indexOf('start interrupt b2')));

      gateA.complete();
      final result = await run;
      expect(log.indexOf('done interrupt a1'), lessThan(log.indexOf('start interrupt a2')));
      expect(_keys(result.done), ['a1', 'b1', 'a2', 'b2']);
      expect(result.failed, isEmpty);
    });

    test('a failure is recorded and the rest of the machine still runs', () async {
      final log = <String>[];
      final plan = BatchPlan.of(BatchAction.close, [
        _t('a1', status: AgentStatus.done, log: log),
        _t('a2', status: AgentStatus.done, log: log, fail: const HerdrTransportException('connection lost')),
        _t('a3', status: AgentStatus.idle, log: log),
        _t('b1', machine: 'b', status: AgentStatus.idle, log: log),
      ]);
      final result = await runBatch(plan);
      expect(_keys(result.done), ['a1', 'a3', 'b1']);
      expect(result.failed.single.target.key, 'a2');
      expect(result.failed.single.message, 'connection lost');
      expect(log, contains('done close a3'));
    });

    test('words for each kind of failure', () async {
      final log = <String>[];
      final plan = BatchPlan.of(BatchAction.interrupt, [
        _t('1', log: log, fail: const HerdrApiException('pane_busy', 'the pane is busy')),
        _t('2', log: log, fail: const HerdrUnsupportedException('pane.send_keys')),
        _t('3', log: log, fail: const AgentHostException('Could not end the session: no route')),
        _t('4', log: log, fail: TimeoutException('slow')),
        _t('5', log: log, fail: const HerdrTransportException('')),
      ]);
      final messages = [for (final f in (await runBatch(plan)).failed) f.message];
      expect(messages, [
        'the pane is busy',
        'this herdr cannot do that, update it',
        'Could not end the session: no route',
        'no answer in time',
        'failed',
      ]);
    });

    test('offline targets are listed as skipped and never called', () async {
      final log = <String>[];
      final plan = BatchPlan.of(BatchAction.message, [
        _t('on', log: log),
        _t('off', machine: 'b', log: log, unreachable: 'offline'),
      ], sendAnyway: true);
      final result = await runBatch(plan, text: 'hi');
      expect(log.where((l) => l.contains('off')), isEmpty);
      expect(_keys(result.done), ['on']);
      expect(result.skipped.single.target.key, 'off');
    });

    test('the text reaches each target exactly as typed', () async {
      final log = <String>[];
      const text = '  Chạy lại các bài kiểm thử\n\nrồi báo kết quả  \n';
      final plan = BatchPlan.of(BatchAction.message, [
        _t('1', log: log),
        _t('2', machine: 'b', log: log, status: AgentStatus.idle),
      ]);
      await runBatch(plan, text: text);
      expect(log.where((l) => l.startsWith('start')), containsAll(['start message[$text] 1', 'start message[$text] 2']));
    });

    test('a very long text is passed whole', () async {
      final log = <String>[];
      final text = List.filled(5000, 'đã xong việc').join(' ');
      await runBatch(BatchPlan.of(BatchAction.message, [_t('1', log: log)]), text: text);
      expect(log.first, 'start message[$text] 1');
    });

    test('a message needs some text', () {
      final plan = BatchPlan.of(BatchAction.message, [_t('1', log: [])]);
      expect(() => runBatch(plan, text: ' \n '), throwsArgumentError);
      expect(() => runBatch(plan), throwsArgumentError);
    });

    test('nothing to do runs nothing and says so', () async {
      final result = await runBatch(BatchPlan.of(BatchAction.close, const []));
      expect(result.summary, 'Closed 0');
    });

    test('each machine is settled once, after its own targets, and a failing settle is ignored', () async {
      final log = <String>[];
      var settledA = 0;
      var settledB = 0;
      final plan = BatchPlan.of(BatchAction.interrupt, [
        _t('a1', log: log, settle: () async {
          settledA++;
          log.add('settle a');
        }),
        _t('a2', log: log),
        _t('b1', machine: 'b', log: log, settle: () async {
          settledB++;
          throw const HerdrTransportException('offline');
        }),
      ]);
      final result = await runBatch(plan);
      expect([settledA, settledB], [1, 1]);
      expect(log.indexOf('settle a'), greaterThan(log.indexOf('done interrupt a2')));
      expect(result.failed, isEmpty);
    });
  });

  group('the summary', () {
    BatchResult result({
      BatchAction action = BatchAction.interrupt,
      int done = 3,
      List<BatchFailure> failed = const [],
      int skipped = 0,
    }) {
      final log = <String>[];
      return BatchResult(
        action: action,
        done: [for (var i = 0; i < done; i++) _t('d$i', log: log)],
        failed: failed,
        skipped: [for (var i = 0; i < skipped; i++) BatchSkip(_t('s$i', log: log), SkipKind.ineligible, 'not working')],
      );
    }

    BatchFailure failure(String machine, String message) =>
        BatchFailure(_t('f$machine$message', machine: machine, log: []), message);

    test('names what was done, what failed and where, and how many were left alone', () {
      expect(result().summary, 'Interrupted 3');
      expect(result(action: BatchAction.message, done: 1).summary, 'Messaged 1');
      expect(result(action: BatchAction.close, skipped: 2).summary, 'Closed 3 · 2 skipped');
      expect(
        result(failed: [failure('a', 'offline')]).summary,
        'Interrupted 3 · 1 failed: machine-a: offline',
      );
      expect(
        result(done: 0, failed: [failure('a', 'offline')], skipped: 1).summary,
        'Interrupted 0 · 1 failed: machine-a: offline · 1 skipped',
      );
    });

    test('the same cause on one machine is said once; many causes are cut', () {
      expect(
        result(failed: [failure('a', 'offline'), failure('a', 'offline'), failure('a', 'offline')]).summary,
        'Interrupted 3 · 3 failed: machine-a: offline',
      );
      expect(
        result(failed: [failure('a', 'x'), failure('b', 'y'), failure('c', 'z'), failure('d', 'w')]).summary,
        'Interrupted 3 · 4 failed: machine-a: x; machine-b: y (+2 more)',
      );
    });
  });

  group('an agent session as a target', () {
    test('goes through cancel, send and end', () async {
      final s = FakeAgentSession(key: 'm/k1', title: 'payments');
      final target = BatchTarget.session(session: s, status: AgentStatus.idle);
      expect(target.title, 'payments');
      expect(target.detail, 'Claude Code · devbox');
      await target.interrupt();
      await target.message('go on');
      await target.close();
      expect(s.cancelCount, 1);
      expect(s.sent, ['go on']);
      expect(s.link, AgentLink.ended);
    });

    test('a machine that is not online makes it unreachable', () {
      final s = FakeAgentSession();
      expect(BatchTarget.session(session: s, status: AgentStatus.idle).unreachable, 'offline');
    });
  });
}
