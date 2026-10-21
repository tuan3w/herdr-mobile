// The log channel drops and comes back: the chat must say so while it is down
// and go back to live once it is up again (it used to stay on "Reconnecting"
// for as long as the session was open, with the log flowing).
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/services/herdr_transport.dart' show HerdrTransportException;
import 'package:herdr_mobile/data/repositories/observed_session.dart';

import 'support/fake_log_source.dart';
import 'support/fake_transport.dart' show eventually;

Future<(ObservedRig, ObservedAgentSession)> _open() async {
  final rig = await ObservedRig.create();
  addTearDown(rig.dispose);
  rig.source.write([sessionLine(), userLine('u1', 'hello')]);
  final session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    kind: ompKind,
    source: rig.source,
    mapper: OmpLogMapper.new,
    previews: rig.previews,
    backoff: (_) => const Duration(milliseconds: 10),
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live, reason: 'log followed');
  return (rig, session);
}

void main() {
  test('a log channel that drops and comes back is live again, not "reconnecting" for good', () async {
    final (rig, session) = await _open();

    rig.source.drop();
    await eventually(() => rig.source.calls.length == 2, reason: 'followed again after the drop');
    await eventually(() => session.link == AgentLink.live, reason: 'live again once the new channel caught up');

    rig.source.push([userLine('u2', 'still here')]);
    await eventually(() => session.state.items.length == 2, reason: 'the new line is shown');
    expect(session.link, AgentLink.live);
  });

  test('a channel that keeps dropping shows reconnecting while it is down', () async {
    final (rig, session) = await _open();

    rig.source.openError = const HerdrTransportException('no route');
    rig.source.drop();
    await eventually(() => session.link == AgentLink.reconnecting, reason: 'down');
    await eventually(() => session.link == AgentLink.live, reason: 'up again after the failed attempt');
  });
}
