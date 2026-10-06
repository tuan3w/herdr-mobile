@TestOn('linux || mac-os')
library;

// The agent, not the keeper, is the record of a conversation. When the host
// reboots (or a keeper is killed) the keeper and its agent die, the session is
// `ended`, and the thread must still come back: `AgentSessions.resume` starts a
// NEW keeper and has the agent replay the old session into it (`session/load`;
// `session/resume` for an agent that can only do that). An ended session keeps
// its saved transcript copy until the host forgets the keeper, so it reads in
// the meantime and after an app restart.
//
// The first groups run the repository and the sessions over a scripted host on
// a fake clock (`FakeAgentHost`, whose `restart()` and agent store stand for a
// reboot); the last runs the REAL keeper script and proves that a fresh keeper
// forwards `session/load` for an id it does not hold.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'acp/support/fake_agent.dart' show ompInitialize;
import 'support/fake_agent_host.dart';
import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/keeper_process_host.dart';
import 'support/memory_stores.dart';
import 'support/memory_transcript_cache.dart';

final _t0 = DateTime.utc(2026, 3, 1, 12);

/// A future's outcome, readable without awaiting (the tests run on a fake
/// clock).
class _Outcome<T> {
  _Outcome(Future<T> f) {
    f.then((v) {
      value = v;
      done = true;
    }, onError: (Object e) {
      error = e;
      done = true;
    });
  }

  T? value;
  Object? error;
  bool done = false;
}

/// A conversation of [turns] user/agent pairs in the keeper's log.
void _talk(FakeKeeper keeper, int turns) {
  for (var i = 0; i < turns; i++) {
    keeper.update(userChunk('question $i', messageId: 'u$i'));
    keeper.update(agentChunk('answer $i', messageId: 'a$i'));
  }
}

List<String> _texts(AgentSessionState s) => [
  for (final item in s.items)
    if (item is TranscriptMessage) '${item.role.name}:${item.text}' else item.key,
];

/// The agent's `initialize` answer without `loadSession`.
Json _resumeOnly() {
  final init = ompInitialize();
  (init['agentCapabilities']! as Map)['loadSession'] = false;
  return init;
}

/// ... and without `session/resume` either.
Json _neither() {
  final init = _resumeOnly();
  (init['agentCapabilities']! as Map)['sessionCapabilities'] = <String, Object?>{};
  return init;
}

/// Machines `a` (and more) over scripted hosts, with one transcript cache.
class _Fleet {
  _Fleet(this.async, {Map<String, FakeAgentHost>? hosts, MemoryTranscriptCache? cache})
    : hosts = hosts ?? {},
      cache = cache ?? MemoryTranscriptCache() {
    machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    fleet = FleetRepository(
      machines: machines,
      network: FakeNetwork(),
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(FakeTransport(snapshotJson())),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      ),
    );
    repo = AgentSessionRepository(
      fleet: fleet,
      hostFor: (c) => host(c.profile.id),
      clock: () => _t0.add(async.elapsed),
      jitter: () => 1,
      cache: this.cache,
    );
  }

  final FakeAsync async;
  final Map<String, FakeAgentHost> hosts;
  final MemoryTranscriptCache cache;
  late final MachineRepository machines;
  late final FleetRepository fleet;
  late final AgentSessionRepository repo;

  FakeAgentHost host(String machineId) =>
      hosts.putIfAbsent(machineId, () => FakeAgentHost(clock: () => _t0.add(async.elapsed)));

  MachineConnection conn(String id) => fleet.connection(id)!;

  void addMachine(String id) {
    unawaited(
      machines.save(
        MachineProfile(id: id, label: 'studio-$id', host: '$id.local', username: 'u'),
        secrets: const MachineSecrets(password: 'x'),
      ),
    );
    async.elapse(const Duration(seconds: 1));
    expect(conn(id).isLive, isTrue);
  }

  /// A listing now.
  void refresh() {
    unawaited(repo.refresh());
    async.elapse(const Duration(milliseconds: 100));
  }

  /// Opens [key] the way a screen does and lets it attach (or show its copy);
  /// the hold stays.
  AcpAgentSession open(String key) {
    final s = repo.byKey(key)! as AcpAgentSession..acquire();
    async.elapse(const Duration(milliseconds: 200));
    return s;
  }

  Future<AgentSessionView> resume(ResumeTargetOf s) => repo.resume(
    machine: conn('a'),
    agent: s.agent,
    cwd: s.cwd,
    sessionId: s.sessionId,
    replaces: s.replaces,
  );

  void dispose() {
    repo.dispose();
    fleet.dispose();
  }
}

/// What [AgentSessionRepository.resume] is asked for an ended session.
class ResumeTargetOf {
  ResumeTargetOf(AgentSessionView s)
    : agent = s.resumeTarget!.agent,
      cwd = s.resumeTarget!.cwd,
      sessionId = s.resumeTarget!.sessionId,
      replaces = s.key;

  final String agent;
  final String cwd;
  final String sessionId;
  final String replaces;
}

void main() {
  /// A fleet with machine `a` and a keeper `old1` that talked for two turns,
  /// listed and opened once (so the phone holds its copy), then the host
  /// restarts.
  ({_Fleet h, FakeAgentHost host, AcpAgentSession old, List<String> original}) afterReboot(FakeAsync async) {
    final h = _Fleet(async);
    final host = h.host('a');
    h.addMachine('a');
    final k = host.add(id: 'old1', cwd: '/work/app', sessionId: 'sess-1', title: 'Fix the parser');
    _talk(k, 2);
    h.refresh();
    final old = h.open('a/old1');
    expect(old.attached, isTrue);
    final original = _texts(old.state);
    expect(original, hasLength(4));
    old.release();
    host.restart();
    h.refresh();
    return (h: h, host: host, old: old, original: original);
  }

  group('an ended session', () {
    test('after a host restart it is ended, keeps its copy, and offers to be continued', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);

        expect(r.old.link, AgentLink.ended);
        final target = r.old.resumeTarget!;
        expect((target.agent, target.cwd, target.sessionId), ('omp', '/work/app', 'sess-1'));
        expect(r.h.cache.stored, contains('a/old1'), reason: 'the copy outlives the keeper while the host lists it');
        expect(r.h.cache.deleted, isEmpty);
      });
    });

    test('a live one, one without an id and one another device took over have no way to be continued', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        addTearDown(h.dispose);
        final host = h.host('a');
        h.addMachine('a');
        host.add(id: 'live', sessionId: 'sess-live');
        host.add(id: 'noid', state: KeeperState.exited, exitCode: 1);
        host.add(id: 'gone', sessionId: 'sess-gone', state: KeeperState.exited, exitCode: 0);
        h.refresh();

        expect((h.repo.byKey('a/live')! as AcpAgentSession).resumeTarget, isNull, reason: 'it lives');
        expect((h.repo.byKey('a/noid')! as AcpAgentSession).resumeTarget, isNull, reason: 'no session to ask the agent for');
        expect((h.repo.byKey('a/gone')! as AcpAgentSession).resumeTarget, isNotNull);

        // Another device attaches: this one is told it was taken over.
        final taken = h.open('a/live');
        expect(taken.attached, isTrue);
        host.keepers['live']!.attach();
        async.elapse(const Duration(milliseconds: 200));
        expect(taken.link, AgentLink.ended);
        expect(taken.evicted, isTrue);
        expect(taken.resumeTarget, isNull, reason: 'Take over is its way back; a second keeper would fight for the thread');
      });
    });

    test('an app restart opens an ended session on its saved copy, read-only', () {
      fakeAsync((async) {
        final first = afterReboot(async);
        final hosts = first.h.hosts;
        final cache = first.h.cache;
        first.h.dispose();

        // The app starts again: new repository, same host, same cache.
        final h = _Fleet(async, hosts: hosts, cache: cache);
        addTearDown(h.dispose);
        h.addMachine('a');
        h.refresh();
        final s = h.repo.byKey('a/old1')! as AcpAgentSession;
        expect(s.link, AgentLink.ended);
        expect(s.state.items, isEmpty, reason: 'nothing read yet');

        s.acquire();
        async.elapse(const Duration(milliseconds: 100));
        expect(_texts(s.state), first.original);
        expect(s.cachedAsOf, isNotNull, reason: 'the screen says when the copy was saved');
        expect(s.state.pending, isEmpty);
        expect(s.resumeTarget, isNotNull);
        expect(cache.deleted, isEmpty);
        s.release();
      });
    });

    test('a keeper the host forgot still takes its copy with it', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        expect(r.h.cache.stored, contains('a/old1'));

        r.host.keepers.remove('old1'); // the 24 h of an exited record passed
        r.h.refresh();

        expect(r.h.repo.byKey('a/old1'), isNull);
        expect(r.h.cache.stored, isNot(contains('a/old1')));
        expect(r.h.cache.deleted, contains('a/old1'));
      });
    });
  });

  group('continuing an ended session', () {
    test('the thread comes back in a new keeper with the same transcript, and the ended row is gone', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        final startsBefore = r.host.startCalls;

        final resumed = _Outcome(r.h.resume(ResumeTargetOf(r.old)));
        async.elapse(const Duration(seconds: 1));

        expect(resumed.error, isNull);
        final live = resumed.value! as AcpAgentSession;
        expect(live.link, AgentLink.live);
        expect(live.attached, isTrue);
        expect(live.key, isNot(r.old.key));
        expect(live.agent, 'omp');
        expect(live.cwd, '/work/app');
        expect(_texts(live.state), r.original, reason: 'the same rows the ended session had');
        expect(live.cachedAsOf, isNull);
        expect(live.resumeTarget, isNull);

        expect(r.host.startCalls, startsBefore + 1);
        final fresh = r.host.keepers.values.singleWhere((k) => k.info.id == live.keeperId);
        expect((fresh.loadCount, fresh.newCount), (1, 0), reason: 'the agent replayed the old session, no new one');
        expect(r.h.repo.byKey(r.old.key), isNull);
        expect(r.h.repo.sessions, [live]);
        expect(r.h.cache.deleted, contains(r.old.key));
        expect(r.host.killed, contains('old1'), reason: 'the exited record is removed from the host');

        r.h.refresh();
        expect(r.h.repo.sessions, [live], reason: 'the old row does not come back with the next listing');
      });
    });

    test('the conversation goes on in the same agent session, and the copy keeps what it had', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        final resumed = _Outcome(r.h.resume(ResumeTargetOf(r.old)));
        async.elapse(const Duration(seconds: 1));
        final live = resumed.value! as AcpAgentSession;

        unawaited(live.send('and then?'));
        async.elapse(const Duration(milliseconds: 200));

        expect(_texts(live.state).sublist(0, 4), r.original);
        expect(_texts(live.state), contains('user:and then?'));
        expect(r.host.agentStore, hasLength(1), reason: 'no second session in the agent\'s store');
        expect(
          r.host.agentStore['sess-1']!.updates.map((u) => jsonEncode(u)).join(),
          contains('and then?'),
          reason: 'the agent\'s own record has the new turn',
        );
        live.acquire();
        live.release();
        expect(r.h.cache.stored[live.key]!.lines, hasLength(greaterThanOrEqualTo(5)));
      });
    });

    test('a load the agent refuses leaves the ended session as it was and kills the new keeper', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        r.host.agentStore.remove('sess-1'); // the agent lost it (the folder was cleaned)

        final resumed = _Outcome(r.h.resume(ResumeTargetOf(r.old)));
        async.elapse(const Duration(seconds: 1));

        final error = resumed.error! as AgentHostException;
        expect(error.message, 'unknown session', reason: 'the agent\'s own words');
        expect(error.fatal, isTrue);
        expect(r.host.killed, hasLength(1), reason: 'the new keeper, and not the old one');
        expect(r.host.killed, isNot(contains('old1')));
        expect(r.h.repo.sessions, [r.old]);
        expect(r.old.link, AgentLink.ended);
        expect(r.old.resumeTarget, isNotNull, reason: 'it can be tried again');
        expect(_texts(r.old.state), r.original);
        expect(r.h.cache.stored, contains('a/old1'));
        expect(r.h.cache.deleted, isEmpty);
      });
    });

    test('asking twice (a double tap, or after it worked) gives the same live session and starts one keeper', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        final startsBefore = r.host.startCalls;
        final target = ResumeTargetOf(r.old);

        final first = _Outcome(r.h.resume(target));
        final second = _Outcome(r.h.resume(target));
        async.elapse(const Duration(seconds: 1));
        expect(first.error, isNull);
        expect(second.value, same(first.value));
        expect(r.host.startCalls, startsBefore + 1);

        // Later, from a screen that still holds the old key.
        final third = _Outcome(r.h.resume(target));
        async.elapse(const Duration(seconds: 1));
        expect(third.value, same(first.value));
        expect(r.host.startCalls, startsBefore + 1);
        expect(r.h.repo.sessions, [first.value]);
      });
    });

    test('a session a keeper holds already is returned as it is, never loaded twice', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        addTearDown(h.dispose);
        final host = h.host('a');
        h.addMachine('a');
        // The same conversation twice: an exited record and a live keeper.
        host.add(id: 'old', agent: 'codex', cwd: '/work/app', sessionId: 'sess-9', state: KeeperState.exited, exitCode: 1);
        host.add(id: 'now', agent: 'codex', cwd: '/work/app', sessionId: 'sess-9');
        h.refresh();
        final ended = h.repo.byKey('a/old')! as AcpAgentSession;
        expect(ended.link, AgentLink.ended);
        final startsBefore = host.startCalls;

        final resumed = _Outcome(h.resume(ResumeTargetOf(ended)));
        async.elapse(const Duration(seconds: 1));

        expect(resumed.value, same(h.repo.byKey('a/now')));
        expect(host.startCalls, startsBefore, reason: 'codex refuses a second client on the thread');
        expect(h.repo.byKey('a/old'), isNull, reason: 'the ended duplicate is dropped');
        expect(host.killed, ['old']);
      });
    });

    test('an agent that can only resume keeps the phone\'s transcript, which the agent will not replay', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        r.host.startInitialize = _resumeOnly;

        final resumed = _Outcome(r.h.resume(ResumeTargetOf(r.old)));
        async.elapse(const Duration(seconds: 1));

        expect(resumed.error, isNull);
        final live = resumed.value! as AcpAgentSession;
        expect(live.attached, isTrue);
        final fresh = r.host.keepers.values.singleWhere((k) => k.info.id == live.keeperId);
        expect((fresh.resumeCount, fresh.loadCount), (1, 0));
        expect(_texts(live.state), r.original, reason: 'the old transcript, kept from the ended session');
        expect(live.state.disconnected, isFalse);
        expect(r.h.repo.byKey(r.old.key), isNull);

        unawaited(live.send('next'));
        async.elapse(const Duration(milliseconds: 200));
        expect(_texts(live.state).sublist(0, 4), r.original);
        expect(_texts(live.state), contains('user:next'));
        live.acquire();
        live.release();
        expect(
          r.h.cache.stored[live.key]!.lines.length,
          greaterThanOrEqualTo(5),
          reason: 'the copy has the old turns too, not only what came after',
        );
      });
    });

    test('an agent that can neither load nor resume says so and nothing is left behind', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        r.host.startInitialize = _neither;

        final resumed = _Outcome(r.h.resume(ResumeTargetOf(r.old)));
        async.elapse(const Duration(seconds: 1));

        final error = resumed.error! as AgentHostException;
        expect(error.message, 'omp cannot reopen past sessions.');
        expect(error.fatal, isTrue);
        expect(r.host.killed, hasLength(1));
        expect(r.host.killed, isNot(contains('old1')));
        expect(r.h.repo.sessions, [r.old]);
        expect(r.old.resumeTarget, isNotNull);
        expect(r.h.cache.stored, contains('a/old1'));
      });
    });

    test('an app restart, then Continue: the transcript the person read is the one that carries on', () {
      fakeAsync((async) {
        final first = afterReboot(async);
        final hosts = first.h.hosts;
        final cache = first.h.cache;
        first.h.dispose();

        final h = _Fleet(async, hosts: hosts, cache: cache);
        addTearDown(h.dispose);
        h.addMachine('a');
        h.refresh();
        final ended = h.open('a/old1');
        expect(_texts(ended.state), first.original);
        expect(ended.cachedAsOf, isNotNull);

        final resumed = _Outcome(h.resume(ResumeTargetOf(ended)));
        async.elapse(const Duration(seconds: 1));

        expect(resumed.error, isNull);
        final live = resumed.value! as AcpAgentSession;
        expect(_texts(live.state), first.original);
        expect(live.cachedAsOf, isNull);
        expect(h.repo.sessions, [live]);
      });
    });

    test('machine and agent errors keep their words; an agent nobody installed is refused before any keeper starts', () {
      fakeAsync((async) {
        final r = afterReboot(async);
        addTearDown(r.h.dispose);
        final startsBefore = r.host.startCalls;

        r.host.installed = {};
        var out = _Outcome(r.h.resume(ResumeTargetOf(r.old)));
        async.elapse(const Duration(seconds: 1));
        expect((out.error! as AgentHostException).message, 'omp is not installed on studio-a.');
        expect(r.host.startCalls, startsBefore);

        r.host.installed = {'omp'};
        r.host.startFailure = const AgentHostException('/work/app does not exist on studio-a.', fatal: true);
        out = _Outcome(r.h.resume(ResumeTargetOf(r.old)));
        async.elapse(const Duration(seconds: 1));
        final error = out.error! as AgentHostException;
        expect(error.message, '/work/app does not exist on studio-a.');
        expect(error.fatal, isTrue);
        expect(r.h.repo.sessions, [r.old]);
        expect(r.old.resumeTarget, isNotNull);
      });
    });
  });

  group('history', () {
    test('asks the machine\'s host for the agent and folder, and says why when it cannot', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        addTearDown(h.dispose);
        final host = h.host('a');
        h.addMachine('a');
        host.remember(sessionId: 'old-1', cwd: '/work/app', title: 'Earlier', updates: [userChunk('hi')]);
        host.remember(sessionId: 'old-2', cwd: '/elsewhere');

        final asked = _Outcome(h.repo.history(machine: h.conn('a'), agent: 'omp', cwd: '/work/app'));
        async.elapse(const Duration(milliseconds: 100));
        expect(asked.value!.sessions.map((s) => s.sessionId), ['old-1']);
        expect(host.historyRequests.single, (agent: 'omp', cwd: '/work/app'));

        host.historyFailure = const AgentHostException('omp did not answer.');
        final failed = _Outcome(h.repo.history(machine: h.conn('a'), agent: 'omp'));
        async.elapse(const Duration(milliseconds: 100));
        expect((failed.error! as AgentHostException).message, 'omp did not answer.');
      });
    });
  });

  group('through the real keeper script', () {
    late KeeperProcessHost host;
    late MachineConnection machine;

    setUp(() async {
      host = await KeeperProcessHost.create();
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
    });

    AcpAgentSession session(KeeperInfo info) {
      final s = AcpAgentSession(
        machine: machine,
        host: host,
        info: info,
        backoff: (_) => const Duration(milliseconds: 30),
        jitter: () => 1,
      );
      addTearDown(s.dispose);
      return s;
    }

    /// The methods the fake agent received, in order.
    List<String> agentMethods() {
      final log = File(host.env['FAKE_ACP_LOG']!);
      if (!log.existsSync()) return [];
      return [
        for (final line in log.readAsLinesSync())
          if (line.trim().isNotEmpty && (jsonDecode(line) as Map)['recv'] is Map)
            '${((jsonDecode(line) as Map)['recv'] as Map)['method']}',
      ];
    }

    test('a new keeper forwards session/load for an id it does not hold and the stored conversation replays', () async {
      host.useAgentStore(
        sessions: [
          {
            'sessionId': 'old-1',
            'cwd': host.work,
            'title': 'Before the reboot',
            'updates': [
              userChunk('what does the parser do?', messageId: 'u0'),
              agentChunk('It splits the input.', messageId: 'a0'),
              userChunk('and the lexer?', messageId: 'u1'),
              agentChunk('It makes the tokens.', messageId: 'a1'),
            ],
          },
        ],
      );
      // A brand new keeper: it holds no session, the agent process is new.
      final info = await host.start(agent: 'omp', cwd: host.work);
      expect(info.sessionId, isNull);
      final s = session(info)..openPast('old-1');
      s.acquire();
      await _until(() => s.attached, 'the attach and the replay');

      expect(_texts(s.state), [
        'user:what does the parser do?',
        'agent:It splits the input.',
        'user:and the lexer?',
        'agent:It makes the tokens.',
      ]);
      expect(s.sessionId, 'old-1');
      expect(s.link, AgentLink.live);
      expect(agentMethods(), contains('session/load'));
      expect(agentMethods(), isNot(contains('session/new')), reason: 'the agent made no new session');

      // The keeper noted the session: the listing carries its id from now on.
      final listed = (await host.list()).singleWhere((k) => k.id == info.id);
      expect(listed.sessionId, 'old-1');

      // A later attach is the keeper's own business: no second load reaches the agent.
      final loads = agentMethods().where((m) => m == 'session/load').length;
      final before = host.attachCount;
      await host.dropLinks();
      await _until(() => host.attachCount > before && s.attached, 'the re-attach');
      expect(agentMethods().where((m) => m == 'session/load').length, loads);
      expect(_texts(s.state), hasLength(4));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('an id the agent does not know fails the attach with the agent\'s words, not a new empty session', () async {
      host.useAgentStore();
      final info = await host.start(agent: 'omp', cwd: host.work);
      final s = session(info)..openPast('never-existed');
      s.acquire();
      await _until(() => s.link == AgentLink.failed, 'the failure');

      expect(s.error, isNotEmpty);
      expect(s.attached, isFalse);
      expect(agentMethods(), isNot(contains('session/new')));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}

Future<void> _until(bool Function() check, String what, {Duration timeout = const Duration(seconds: 40)}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
