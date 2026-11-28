// The subagent roster polls the host's artifact folder while a screen lists it.
// With the app in the background nobody looks, so the poll must not touch the
// radio (the keep-alive profile keeps the machine live, so `isLive` alone does
// not stop it).
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/observed/observed_kind.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink, SubagentState;
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';

import 'support/fake_log_source.dart';
import 'support/fake_transport.dart' show eventually;

/// Counts the remote listings the roster asks for.
class _CountingLogs implements SubagentLogs {
  int refines = 0;

  @override
  Future<String?> pathOf(MachineConnection machine, String parentLogPath, SubagentInfo info) async => null;

  @override
  Future<Map<String, SubagentState>?> refine(
    MachineConnection machine,
    String parentLogPath,
    List<SubagentInfo> infos, {
    required Duration running,
  }) async {
    refines++;
    return const {};
  }
}

void main() {
  const poll = Duration(seconds: 4);

  Future<(ObservedAgentSession, _CountingLogs)> open() async {
    final rig = await ObservedRig.create();
    addTearDown(rig.dispose);
    rig.source.write([sessionLine(), userLine('u1', 'hello')]);
    final logs = _CountingLogs();
    final session = ObservedAgentSession(
      machine: rig.machine,
      paneId: 'w1:p1',
      kind: ObservedKind(
        id: ompKind.id,
        label: ompKind.label,
        newMapper: OmpLogMapper.new,
        locator: ompKind.locator,
        subagents: logs,
      ),
      source: rig.source,
      mapper: OmpLogMapper.new,
      previews: rig.previews,
      subagentPoll: poll,
    );
    addTearDown(session.dispose);
    session.acquire();
    await eventually(() => session.link == AgentLink.live && session.logPath != null, reason: 'log followed');
    return (session, logs);
  }

  test('the roster poll lists nothing while the app is in the background and resumes in front', () async {
    final (session, logs) = await open();
    // Fake time: the poll's period is virtual, so no wall clock is raced.
    fakeAsync((async) {
      session.watchSubagents(true);
      async.flushMicrotasks();
      async.elapse(poll * 2);
      final inFront = logs.refines;
      expect(inFront, greaterThanOrEqualTo(3), reason: 'the open and one per tick while the roster is open');

      session.background();
      async.elapse(poll * 5);
      expect(logs.refines, inFront, reason: 'a hidden app asks the host for nothing, even with the machine live');

      session.foreground();
      async.elapse(poll);
      async.flushMicrotasks();
      expect(logs.refines, greaterThan(inFront), reason: 'back in front the roster looks again');

      session.watchSubagents(false);
    });
  });
}
