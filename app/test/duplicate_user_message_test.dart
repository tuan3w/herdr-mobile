@TestOn('linux || mac-os')
library;

// One message the person typed must show once. The scenario of the bug report,
// end to end, with the REAL keeper script and the app's real session object
// (only the agent is scripted: test/support/fake_acp_agent.py):
//
//   a long turn runs; the person types a message (omp has no steering: it
//   queues); the link drops and re-attaches; the turn ends; omp is busy with a
//   turn of its own (its background subagents) and refuses the prompt with
//   -32003 while the person taps Resume again and again; at last omp takes it.
//
// The agent takes the message once. The transcript must show it once: live,
// after every re-attach (the keeper's replay), and when the app restarts from
// its saved copy. A refused attempt left a user message behind in the keeper's
// log, and one in the live transcript, so every attempt showed up as one more
// identical bubble.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart' show KeeperInfo;
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/transcript_log.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';
import 'support/keeper_process_host.dart';
import 'support/memory_transcript_cache.dart';

const _message =
    'reply: please check the fifth subagent as well and tell me which of the eight is still running';

Future<void> _until(
  bool Function() check,
  String what, {
  Duration timeout = const Duration(seconds: 40),
}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// The user bubbles that show [_message] (the agent's reply says it too, as a
/// message of the agent's, which does not count).
int _bubbles(AgentSessionState s) => s.items
    .whereType<TranscriptMessage>()
    .where((m) => m.role == MessageRole.user && m.text == _message)
    .length;

List<String> _userRows(AgentSessionState s) => [
  for (final m in s.items.whereType<TranscriptMessage>())
    if (m.role == MessageRole.user) m.text,
];

void main() {
  late KeeperProcessHost host;
  late MachineConnection machine;
  late MemoryTranscriptCache cache;

  AcpAgentSession newSession(KeeperInfo info) {
    final s = AcpAgentSession(
      machine: machine,
      host: host,
      info: info,
      backoff: (_) => const Duration(milliseconds: 30),
      jitter: () => 1,
      cache: cache,
    );
    addTearDown(s.dispose);
    return s;
  }

  setUp(() async {
    host = await KeeperProcessHost.create();
    cache = MemoryTranscriptCache();
    machine = MachineConnection(
      profile: const MachineProfile(
        id: 'm1',
        label: 'studio',
        host: 'm1.local',
        username: 'u',
      ),
      api: HerdrApi(FakeTransport()),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    )..start();
    addTearDown(() async {
      machine.dispose();
      await host.dispose();
    });
    await _until(() => machine.isLive, 'the machine to be live');
  });

  test('one typed message shows once: refused as busy again and again, re-attached, restarted', () async {
    final info = await host.start(agent: 'omp', cwd: host.work);
    final session = newSession(info)..acquire();
    await _until(() => session.attached, 'the first attach');

    // A long turn runs; omp's background work keeps it busy afterwards.
    unawaited(session.send('sleep:6'));
    await _until(() => session.state.turnActive, 'the turn to run');
    host.busy = true;

    // The person types the message: no steering on omp, it queues.
    unawaited(session.send(_message));
    await _until(() => session.queued.length == 1, 'the message to queue');
    expect(_bubbles(session.state), 0);

    // The link drops and comes back three times during the turn.
    for (var i = 0; i < 3; i++) {
      final before = host.attachCount;
      await host.dropLinks();
      await _until(
        () => host.attachCount > before && session.attached,
        're-attach #${i + 1}',
      );
      expect(
        session.queued.length,
        1,
        reason: 'the queue survives a re-attach',
      );
      expect(
        _bubbles(session.state),
        0,
        reason:
            'queued, not sent: nothing in the transcript (re-attach ${i + 1})',
      );
    }

    // The turn ends; the queue sends the message; omp is busy and refuses it.
    int attempts() =>
        host.promptsSeenByAgent().where((p) => p == _message).length;
    await _until(
      () => attempts() == 1,
      'the first refused attempt',
      timeout: const Duration(seconds: 40),
    );
    await _until(
      () => session.queued.length == 1 && session.queued.single.held,
      'the refused message to wait, held',
    );
    expect(
      _bubbles(session.state),
      0,
      reason: 'refused: not in the transcript',
    );

    // The person taps Resume again and again; omp keeps refusing.
    for (var i = 2; i <= 4; i++) {
      session.resumeQueue();
      await _until(() => attempts() == i, 'refused attempt #$i');
      await _until(
        () => session.queued.length == 1 && session.queued.single.held,
        'held again after attempt #$i',
      );
      expect(
        _bubbles(session.state),
        0,
        reason: 'refused attempt #$i left a bubble',
      );
    }

    // A re-attach replays the keeper's log: the refused attempts are not in it.
    {
      final before = host.attachCount;
      await host.dropLinks();
      await _until(
        () => host.attachCount > before && session.attached,
        're-attach after the refusals',
      );
      expect(
        _bubbles(session.state),
        0,
        reason: 'the keeper logged a refused prompt',
      );
      expect(session.queued.length, 1);
    }

    // omp is free: the message is taken, once.
    host.busy = false;
    session.resumeQueue();
    await _until(
      () =>
          _bubbles(session.state) == 1 &&
          session.state.items.whereType<TranscriptMessage>().any(
            (m) => m.text.startsWith('re: '),
          ),
      'the message to be answered',
    );
    await _until(() => !session.state.turnActive, 'the turn to end');
    expect(session.queued, isEmpty);
    expect(_bubbles(session.state), 1, reason: 'live');
    expect(attempts(), 5);

    // Re-attach three more times: the replay shows it once each time.
    for (var i = 0; i < 3; i++) {
      final before = host.attachCount;
      await host.dropLinks();
      await _until(
        () => host.attachCount > before && session.attached,
        'final re-attach #${i + 1}',
      );
      expect(
        _bubbles(session.state),
        1,
        reason: 'after re-attach ${i + 1}: ${_userRows(session.state)}',
      );
    }
    expect(_userRows(session.state), ['sleep:6', _message]);

    // Restart from the saved copy: the cached lines alone, then a new
    // session object over the same cache and the live keeper.
    session.background();
    final saved = await cache.read(session.key);
    expect(saved, isNotNull);
    expect(
      _bubbles(replayCachedTranscript(saved!)),
      1,
      reason: 'the saved copy',
    );
    expect(_userRows(replayCachedTranscript(saved)), ['sleep:6', _message]);

    session.dispose();
    final restarted = newSession((await host.list()).single)..acquire();
    await _until(() => restarted.attached, 'the restarted session to attach');
    expect(
      _bubbles(restarted.state),
      1,
      reason: 'after the restart: ${_userRows(restarted.state)}',
    );
    expect(_userRows(restarted.state), ['sleep:6', _message]);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a person who sends the same words twice still sees two messages, on every path', () async {
    final info = await host.start(agent: 'omp', cwd: host.work);
    final session = newSession(info)..acquire();
    await _until(() => session.attached, 'the first attach');

    for (var i = 1; i <= 2; i++) {
      await session.send('reply: continue');
      await _until(() => !session.state.turnActive, 'turn $i to end');
    }
    const twice = ['reply: continue', 'reply: continue'];
    expect(_userRows(session.state), twice, reason: 'live');

    final before = host.attachCount;
    await host.dropLinks();
    await _until(
      () => host.attachCount > before && session.attached,
      're-attach',
    );
    expect(_userRows(session.state), twice, reason: 'after a re-attach');

    session.background();
    expect(
      _userRows(replayCachedTranscript((await cache.read(session.key))!)),
      twice,
      reason: 'the saved copy',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
