@TestOn('linux || mac-os')
library;

// Opening a chat the phone already holds asks the keeper for its newest turns,
// not its whole log. The REAL keeper script and the app's real session object
// (only the agent is scripted: test/support/fake_acp_agent.py), with the saved
// copy of an earlier open in a memory cache.
//
// What matters to a person: the transcript is exactly what a whole replay
// gives, whatever the chat did in between, and nothing is shown twice or lost.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart' show AcpTransport;
import 'package:herdr_mobile/data/acp/acp_client.dart' show foldLines;
import 'package:herdr_mobile/data/acp/past_session.dart';
import 'package:herdr_mobile/data/acp/replay_since.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/transcript_log.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'support/fake_transport.dart';
import 'support/keeper_process_host.dart';
import 'support/memory_transcript_cache.dart';

Future<void> _until(bool Function() check, String what, {Duration timeout = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// A host that counts the characters the keeper's channels deliver.
class _Counting implements AgentHost {
  _Counting(this.inner);

  final KeeperProcessHost inner;
  var chars = 0;

  @override
  Future<AcpTransport> attach(String keeperId) async => _Counted(await inner.attach(keeperId), (n) => chars += n);

  @override
  Future<Set<String>> available() => inner.available();

  @override
  Future<List<KeeperInfo>> list() => inner.list();

  @override
  Future<KeeperInfo> start({required String agent, required String cwd}) => inner.start(agent: agent, cwd: cwd);

  @override
  Future<void> kill(String keeperId) => inner.kill(keeperId);

  @override
  Future<PastSessions> history({required String agent, String? cwd}) => inner.history(agent: agent, cwd: cwd);
}

class _Counted implements AcpTransport {
  _Counted(this._inner, void Function(int) count) : lines = _inner.lines.map((l) {
        count(l.length);
        return l;
      });

  final AcpTransport _inner;

  @override
  final Stream<String> lines;

  @override
  void send(String line) => _inner.send(line);

  @override
  Future<void> close() => _inner.close();
}

List<String> _shape(AgentSessionState s) => AgentSessionState.signaturesOf(s.items);

void main() {
  late KeeperProcessHost host;
  late _Counting counting;
  late MachineConnection machine;
  late MemoryTranscriptCache cache;
  late KeeperInfo info;

  AcpAgentSession open({MemoryTranscriptCache? withCache}) {
    final s = AcpAgentSession(
      machine: machine,
      host: counting,
      info: info,
      backoff: (_) => const Duration(milliseconds: 30),
      jitter: () => 1,
      cache: withCache,
    );
    addTearDown(s.dispose);
    return s;
  }

  /// Opens the chat, waits until its replay is whole and returns it with the
  /// characters that cost.
  Future<(AcpAgentSession, int)> opened({MemoryTranscriptCache? withCache}) async {
    final before = counting.chars;
    final s = open(withCache: withCache)..acquire();
    await _until(() => s.attached && !s.state.replaying, 'the session to be live');
    return (s, counting.chars - before);
  }

  Future<void> say(AcpAgentSession s, String prompt) async {
    await s.send(prompt);
    await _until(() => !s.state.turnActive, 'the turn "$prompt" to end');
  }

  /// The keeper, the machine and a chat of a few turns started on this phone.
  /// [keeperEnv] is the keeper's environment (`HERDR_KEEPER_*`).
  Future<void> boot([Map<String, String> keeperEnv = const {}]) async {
    host = await KeeperProcessHost.create();
    host.env.addAll(keeperEnv);
    counting = _Counting(host);
    cache = MemoryTranscriptCache();
    machine = MachineConnection(
      profile: const MachineProfile(id: 'm1', label: 'studio', host: 'm1.local', username: 'u'),
      api: HerdrApi(FakeTransport()),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    )..start();
    addTearDown(() async {
      machine.dispose();
      await host.dispose();
    });
    await _until(() => machine.isLive, 'the machine to be live');
    info = await host.start(agent: 'omp', cwd: host.work);

    // A chat of a few heavy turns, started on this phone.
    final first = open(withCache: cache)..acquire();
    await _until(() => first.attached, 'the first attach');
    for (var i = 0; i < 4; i++) {
      await say(first, 'heavy:6:8:20:t$i');
    }
    // The last turn is a short one, as the last of a chat usually is: the
    // keeper repeats the turn the copy ends in.
    await say(first, 'reply:settled');
    first.release();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    first.dispose();
    // What the board lists now: the keeper knows the session.
    info = (await host.list()).single;
  }

  void bootTest(String name, Future<void> Function() body, {Map<String, String> env = const {}}) =>
      test(name, () async {
        await boot(env);
        await body();
      }, timeout: const Timeout(Duration(minutes: 3)));

  /// One open that sees the keeper's whole log, then lets go: the copy it
  /// leaves is what a replay stamps.
  Future<void> stampedCopy() async {
    final (s, _) = await opened(withCache: cache);
    s.release();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    s.dispose();
    final lines = cache.stored.values.single.lines;
    expect(replaySinceOf(lines), isNotNull, reason: 'a replay stamps its turns: the copy can be cut');
  }

  bootTest('a copy the keeper stamped is replayed from its last turn: the same transcript for a fraction of the bytes', () async {
    // The first replay is a whole one (what the phone saw so far came live and
    // carries no stamp).
    await stampedCopy();

    // Meanwhile the chat goes on, from another device.
    final other = open()..acquire();
    await _until(() => other.attached && !other.state.replaying, 'the other device to attach');
    await say(other, 'reply:another');
    await say(other, 'reply:and one more');
    other.release();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    other.dispose();

    final (full, fullChars) = await opened();
    final (delta, deltaChars) = await opened(withCache: cache);

    expect(_shape(delta.state), _shape(full.state), reason: 'what the person reads is what a whole replay gives');
    expect(delta.state.items.whereType<TranscriptMessage>().last.text, 're: and one more');
    expect(deltaChars, lessThan(fullChars ~/ 3), reason: 'only the newest turns came again ($deltaChars of $fullChars)');
    expect(delta.state.items.length, full.state.items.length);

    // The next copy holds everything: the part the keeper did not repeat too.
    delta.release();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final lines = cache.stored.values.single.lines;
    final again = foldLines(delta.sessionId!, lines);
    expect(_shape(again), _shape(full.state), reason: 'the saved copy is whole again');
  });

  bootTest('a copy from another keeper log is replayed whole, and is still right', () async {
    await stampedCopy();
    final key = cache.stored.keys.single;
    final snapshot = cache.stored[key]!;
    cache.stored[key] = TranscriptSnapshot(
      sessionId: snapshot.sessionId,
      asOf: snapshot.asOf,
      setup: snapshot.setup,
      partial: snapshot.partial,
      lines: [for (final l in snapshot.lines) l.replaceAllMapped(RegExp(r'"epoch"\s*:\s*"[0-9a-f]+"'), (_) => '"epoch":"000000000000"')],
    );

    final (full, fullChars) = await opened();
    final (again, againChars) = await opened(withCache: cache);

    expect(_shape(again.state), _shape(full.state));
    expect(againChars, greaterThan(fullChars ~/ 2), reason: 'nothing was left out: the keeper had no such epoch');
  });

  bootTest('a copy with no stamp (the chat only ever came live) is replayed whole', () async {
    final lines = cache.stored.values.single.lines;
    expect(replaySinceOf(lines), isNull, reason: 'live lines carry no stamp');
    final (full, fullChars) = await opened();
    final (again, againChars) = await opened(withCache: cache);
    expect(_shape(again.state), _shape(full.state));
    expect(againChars, greaterThan(fullChars ~/ 2));
  });

  bootTest('a stamp for a turn the keeper no longer has is replayed whole', () async {
    await stampedCopy();
    final key = cache.stored.keys.single;
    final snapshot = cache.stored[key]!;
    // Turn numbers of a log that never had so many.
    cache.stored[key] = TranscriptSnapshot(
      sessionId: snapshot.sessionId,
      asOf: snapshot.asOf,
      setup: snapshot.setup,
      partial: snapshot.partial,
      lines: [for (final l in snapshot.lines) l.replaceAllMapped(RegExp(r'"turn"\s*:\s*\d+'), (_) => '"turn":9999')],
    );
    final (full, _) = await opened();
    final (again, _) = await opened(withCache: cache);
    expect(_shape(again.state), _shape(full.state));
    expect(jsonEncode(again.state.items.length), jsonEncode(full.state.items.length));
  });

  bootTest(
    'older turns the keeper trimmed since the copy do not change what the person reads',
    () async {
      await stampedCopy();

      // The chat goes on from another device, heavily: the keeper's budget is
      // small, so it cuts the detail of turns the phone's copy holds in full.
      final other = open()..acquire();
      await _until(() => other.attached && !other.state.replaying, 'the other device to attach');
      await say(other, 'heavy:6:8:20:u0');
      await say(other, 'heavy:6:8:20:u1');
      await say(other, 'reply:the end');
      other.release();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      other.dispose();

      final (full, fullChars) = await opened();
      final (delta, deltaChars) = await opened(withCache: cache);

      expect(
        full.state.items.whereType<TranscriptTool>().any((t) => t.call.detailTrimmed),
        isTrue,
        reason: 'the keeper did cut detail of older turns: this is the case the test is about',
      );
      expect(_shape(delta.state), _shape(full.state), reason: 'every row is there, the same ones, in the same order');
      expect(
        [for (final m in delta.state.items.whereType<TranscriptMessage>()) m.text],
        [for (final m in full.state.items.whereType<TranscriptMessage>()) m.text],
      );
      expect(deltaChars, lessThan(fullChars), reason: 'and it cost less ($deltaChars of $fullChars)');
    },
    env: {'HERDR_KEEPER_LOG_SOFT_BYTES': '150000', 'HERDR_KEEPER_FULL_TURNS': '1'},
  );
}
