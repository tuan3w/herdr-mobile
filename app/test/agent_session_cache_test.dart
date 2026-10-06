// The transcript cache at work in a session: a restart opens on the saved
// transcript before the keeper has answered, the keeper's replay then replaces
// it without a duplicate row, nothing of a saved copy can be answered, and the
// repository starts attaching when a finger goes down on a row (never in the
// background, never past the machine's channel limit). All time is fake; the
// file cache itself is tested in transcript_cache_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart' show KeeperState;
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/transcript_log.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/transcript_cache.dart';

import 'support/fake_agent_host.dart';
import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_stores.dart';
import 'support/memory_transcript_cache.dart';

final _t0 = DateTime.utc(2026, 3, 1, 12);

MachineProfile _profile(String id) => MachineProfile(id: id, label: 'studio-$id', host: '$id.local', username: 'u');

/// A machine that is online and a session over [host]'s [keeper].
class _Rig {
  _Rig(this.async, {MemoryTranscriptCache? cache, FakeAgentHost? host, FakeKeeper? keeper})
    : cache = cache ?? MemoryTranscriptCache(),
      host = host ?? FakeAgentHost(clock: () => _t0.add(async.elapsed)) {
    machine = MachineConnection(
      profile: _profile('m1'),
      api: HerdrApi(FakeTransport()),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    )..start();
    async.flushMicrotasks();
    expect(machine.isLive, isTrue);
    this.keeper = keeper ?? this.host.add(id: 'k1', sessionId: 'sess-k1');
  }

  final FakeAsync async;
  final MemoryTranscriptCache cache;
  final FakeAgentHost host;
  late final MachineConnection machine;
  late final FakeKeeper keeper;

  DateTime get now => _t0.add(async.elapsed);

  /// A session of the keeper, as the app builds it on a start: a new object
  /// each time (a restart has none of the old one's memory).
  AcpAgentSession session({TranscriptCache? cache}) => AcpAgentSession(
    machine: machine,
    host: host,
    info: keeper.info,
    clock: () => now,
    jitter: () => 1,
    cache: cache ?? this.cache,
  );

  void pump([int ms = 40]) => async.elapse(Duration(milliseconds: ms));

  void dispose() => machine.dispose();
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

void _rigTest(String name, void Function(_Rig r, FakeAsync async) body) {
  test(name, () {
    fakeAsync((async) {
      final r = _Rig(async);
      addTearDown(r.dispose);
      body(r, async);
    });
  });
}

void main() {
  group('a restart opens on the saved transcript', () {
    _rigTest('it shows before the keeper answers, and the replay replaces it without a duplicate row', (r, async) {
      _talk(r.keeper, 4);
      // First run: open, replay, leave. Leaving saves.
      final before = r.session()..acquire();
      r.pump();
      expect(before.attached, isTrue);
      final live = _texts(before.state);
      expect(live, hasLength(8));
      expect(before.cachedAsOf, isNull);
      before.release();
      expect(r.cache.saves.last, ('m1/k1', true), reason: 'leaving saves at once');
      before.dispose();

      // Second run: a new object over the same cache; the keeper is slow.
      r.host.attachGate = Completer<void>();
      final loadsBefore = r.keeper.loadCount;
      final after = r.session()..acquire();
      r.pump();
      expect(after.attached, isFalse);
      expect(r.keeper.loadCount, loadsBefore, reason: 'the keeper has not answered');
      expect(_texts(after.state), live, reason: 'the saved transcript is on screen already');
      expect(after.cachedAsOf, isNotNull);
      expect(after.state.pending, isEmpty);
      expect(after.state.items.every((i) => !i.timed), isTrue, reason: 'history carries no times, as in a replay');
      final keys = [for (final i in after.state.items) i.key];

      // The keeper answers: the real replay takes over.
      r.host.attachGate!.complete();
      r.pump();
      expect(after.attached, isTrue);
      expect(after.cachedAsOf, isNull);
      expect(_texts(after.state), live, reason: 'no row twice, none lost');
      expect([for (final i in after.state.items) i.key], keys, reason: 'rows keep their keys: the list keeps its place');
      expect(after.state.disconnected, isFalse);
      after.dispose();
    });

    _rigTest('while the replay arrives the saved transcript stays: it is swapped once, when the replay is whole', (r, async) {
      _talk(r.keeper, 3);
      final first = r.session()..acquire();
      r.pump();
      final all = _texts(first.state);
      first
        ..release()
        ..dispose();

      // The keeper replays slowly: two lines now, the rest later.
      r.keeper.loadGate = Completer<void>();
      r.keeper.loadSplit = 2;
      final second = r.session();
      final seen = <int>[];
      second.addListener(() => seen.add(second.state.items.length));
      second.acquire();
      r.pump();
      expect(r.keeper.loadCount, 2, reason: 'the replay is under way');
      expect(second.attached, isFalse);
      expect(_texts(second.state), all, reason: 'two lines of replay must not shrink the transcript on screen');
      expect(second.cachedAsOf, isNotNull);

      r.keeper.loadGate!.complete();
      r.pump();
      expect(second.attached, isTrue);
      expect(second.cachedAsOf, isNull);
      expect(_texts(second.state), all);
      expect(seen.where((n) => n != 6), isEmpty, reason: 'saved transcript, then the replay: 6 rows throughout');
      second.dispose();
    });

    _rigTest('a keeper that is slower than the cache read: nothing saved overwrites the real replay', (r, async) {
      _talk(r.keeper, 2);
      final first = r.session()..acquire();
      r.pump();
      first
        ..release()
        ..dispose();
      // More happens on the keeper while the phone is away.
      r.keeper.update(userChunk('question 2', messageId: 'u2'));
      r.keeper.update(agentChunk('answer 2', messageId: 'a2'));

      r.cache.readGate = Completer<void>();
      final second = r.session()..acquire();
      r.pump();
      expect(second.attached, isTrue, reason: 'the disk is slow, the keeper is not');
      final real = _texts(second.state);
      expect(real, hasLength(6));

      r.cache.readGate!.complete();
      r.pump();
      expect(_texts(second.state), real, reason: 'a late saved copy never replaces what the keeper said');
      expect(second.cachedAsOf, isNull);
      second.dispose();
    });

    _rigTest('the user\'s own message is in the saved copy though the keeper never echoed it to this phone', (r, async) {
      final first = r.session()..acquire();
      r.pump();
      unawaited(first.send('please fix the build'));
      r.pump();
      expect(_texts(first.state), contains('user:please fix the build'));
      first.release();
      first.dispose();

      r.host.attachGate = Completer<void>();
      final second = r.session()..acquire();
      r.pump();
      expect(_texts(second.state), contains('user:please fix the build'));
      expect(_texts(second.state).last, startsWith('agent:ok: please fix'));
      second.dispose();
    });

    _rigTest('what a session has not got a copy of opens as before: Connecting, then the replay', (r, async) {
      _talk(r.keeper, 2);
      r.host.attachGate = Completer<void>();
      final s = r.session()..acquire();
      r.pump();
      expect(s.state.items, isEmpty);
      expect(s.cachedAsOf, isNull);
      expect(s.link, AgentLink.connecting);
      r.host.attachGate!.complete();
      r.pump();
      expect(s.state.items, hasLength(4));
      s.dispose();
    });

    _rigTest('a copy of another session (the keeper started over) is not shown', (r, async) {
      _talk(r.keeper, 2);
      final first = r.session()..acquire();
      r.pump();
      first
        ..release()
        ..dispose();
      final stale = r.cache.stored['m1/k1']!;
      r.cache.stored['m1/k1'] = snapshotWith(stale, sessionId: 'sess-other');

      r.host.attachGate = Completer<void>();
      final second = r.session()..acquire();
      r.pump();
      expect(second.state.items, isEmpty);
      expect(second.cachedAsOf, isNull);
      second.dispose();
    });
  });

  group('a saved copy is not a live request', () {
    _rigTest('a permission that waited when the copy was saved cannot be answered until the attach confirms it', (r, async) {
      _talk(r.keeper, 1);
      final request = r.keeper.askPermission();
      final first = r.session()..acquire();
      r.pump();
      final id = first.state.pending.single.id;
      expect(first.phase, AgentPhase.blockedOnPermission);
      first.release();
      first.dispose();
      expect(request.answered, isFalse);

      // The restart: the keeper is slow to answer, the copy is on screen.
      r.host.attachGate = Completer<void>();
      final second = r.session()..acquire();
      r.pump();
      expect(second.cachedAsOf, isNotNull);
      expect(second.state.items, isNotEmpty);
      expect(second.state.pending, isEmpty, reason: 'requests are not part of a saved copy');
      second.answerPermission(id, const PermissionSelected('allow'));
      r.pump();
      expect(request.answered, isFalse, reason: 'nothing was answered from a saved copy');

      // The attach confirms it: now it is a live request and can be answered.
      r.host.attachGate!.complete();
      r.pump();
      expect(second.cachedAsOf, isNull);
      final live = second.state.pending.single;
      expect(live, isA<PendingPermission>());
      second.answerPermission(live.id, const PermissionSelected('allow'));
      r.pump();
      expect(request.answered, isTrue);
      second.dispose();
    });

    _rigTest('a request id from before the restart answers nothing even if it matches a live one', (r, async) {
      final request = r.keeper.askPermission();
      final first = r.session()..acquire();
      r.pump();
      final id = first.state.pending.single.id;
      first
        ..release()
        ..dispose();

      r.host.attachGate = Completer<void>();
      final second = r.session()..acquire();
      r.pump();
      // Whatever the screen of a saved copy would hand over, it is refused.
      second.answerPermission(id, const PermissionSelected('always'));
      second.answerQuestion(id, const ElicitationCancel());
      r.host.attachGate!.complete();
      r.pump();
      expect(request.answered, isFalse);
      expect(second.state.pending, hasLength(1), reason: 'still waiting for the person');
      second.dispose();
    });
  });

  group('what is saved, and when', () {
    _rigTest('never per chunk: a long answer saves once, when the turn ends', (r, async) {
      final s = r.session()..acquire();
      r.pump();
      r.keeper.turn = Completer<String>();
      unawaited(s.send('go'));
      r.pump();
      final before = r.cache.saves.length;
      for (var i = 0; i < 300; i++) {
        r.keeper.say('chunk $i ', messageId: 'long');
        if (i % 20 == 0) r.pump(20);
      }
      r.pump();
      expect(r.cache.saves.length, before, reason: '300 chunks asked for no save');

      r.keeper.finishTurn();
      r.pump();
      expect(r.cache.saves.length, before + 1, reason: 'the turn ended: one save');
      expect(r.cache.saves.last.$2, isFalse, reason: 'left to the cache\'s debounce');
      final lines = r.cache.stored['m1/k1']!.lines;
      expect(lines.length, greaterThan(300), reason: 'the lines are the raw updates received');
      expect(lines.every((l) => l.contains('"session/update"')), isTrue);
      s.dispose();
    });

    _rigTest('leaving the screen saves at once; leaving unchanged saves nothing more', (r, async) {
      _talk(r.keeper, 1);
      final s = r.session()..acquire();
      r.pump();
      expect(r.cache.saves, isEmpty, reason: 'attaching alone asks nothing');
      s.release();
      expect(r.cache.saves, [('m1/k1', true)]);
      s
        ..acquire()
        ..release();
      expect(r.cache.saves, hasLength(1), reason: 'nothing changed since the last save');
      s.dispose();
    });

    _rigTest('the app going to the background saves at once, and hurries a save still waiting', (r, async) {
      final s = r.session()..acquire();
      r.pump();
      r.keeper.turn = Completer<String>();
      unawaited(s.send('go'));
      r.pump();
      r.keeper.finishTurn();
      r.pump();
      expect(r.cache.saves.last.$2, isFalse);
      final waiting = r.cache.saves.length;

      s.onLifecycleState(AppLifecycleState.paused);
      expect(r.cache.saves.length, waiting + 1);
      expect(r.cache.saves.last, ('m1/k1', true));
      s.dispose();
    });

    _rigTest('a second attach starts the kept lines over: the copy is the keeper\'s log once, not twice', (r, async) {
      _talk(r.keeper, 3);
      final s = r.session()..acquire();
      r.pump();
      s.release();
      final first = r.cache.stored['m1/k1']!.lines.length;
      expect(first, 6);

      // The screen opens again (the channel went with the last one): the
      // keeper replays its whole log, and one more thing happens.
      s.acquire();
      r.pump();
      r.keeper.update(agentChunk('and more', messageId: 'a9'));
      r.pump();
      s.release();
      expect(r.cache.stored['m1/k1']!.lines.length, first + 1);
      s.dispose();
    });

    _rigTest('the session ending (the agent exits, or the person ends it) keeps its copy: it is what an ended session shows', (r, async) {
      _talk(r.keeper, 1);
      final s = r.session()..acquire();
      r.pump();
      s.release();
      expect(r.cache.stored, contains('m1/k1'));

      unawaited(s.end());
      r.pump();
      expect(s.link, AgentLink.ended);
      expect(r.cache.stored, contains('m1/k1'));
      expect(r.cache.deleted, isEmpty);
      s.dispose();
    });

    _rigTest('what the agent said before it exited is in the copy the ended session keeps', (r, async) {
      _talk(r.keeper, 1);
      final s = r.session()..acquire();
      r.pump();
      expect(r.cache.stored['m1/k1']?.lines.length, isNull, reason: 'nothing is saved while the screen holds it');

      r.keeper.update(agentChunk('last words', messageId: 'a9'));
      r.pump();
      r.keeper.exit(code: 1);
      r.pump();
      expect(s.link, AgentLink.ended);
      final saved = r.cache.stored['m1/k1']!;
      expect(saved.lines, hasLength(3), reason: 'the exit saves at once, not at the next release');
      expect(saved.lines.last, contains('last words'));
      s.dispose();
    });

    _rigTest('a keeper that exited while the app was closed: its copy is shown, read-only, and kept', (r, async) {
      _talk(r.keeper, 1);
      final s = r.session()..acquire();
      r.pump();
      final live = _texts(s.state);
      s.release();
      s.dispose();
      r.keeper.exit(code: 0);

      final restarted = r.session()..acquire();
      r.pump();
      expect(restarted.link, AgentLink.ended);
      expect(_texts(restarted.state), live);
      expect(restarted.cachedAsOf, isNotNull, reason: 'the screen can say when the copy was saved');
      expect(restarted.state.pending, isEmpty);
      expect(r.cache.stored, contains('m1/k1'));
      expect(r.cache.deleted, isEmpty);
      restarted.dispose();
    });

    _rigTest('without a cache nothing changes', (r, async) {
      _talk(r.keeper, 1);
      final s = AcpAgentSession(machine: r.machine, host: r.host, info: r.keeper.info, clock: () => r.now)..acquire();
      r.pump();
      expect(s.attached, isTrue);
      expect(s.state.items, hasLength(2));
      expect(s.cachedAsOf, isNull);
      s.release();
      s.dispose();
    });
  });

  group('a replay shorter than what the phone holds', () {
    /// The keeper's log cut the way its bound cuts it: [turns] whole turns
    /// gone from the start (`_talk` writes two entries per turn).
    void cut(FakeKeeper keeper, int turns) {
      keeper.log.removeRange(0, turns * 2);
      keeper.droppedTurns = turns;
    }

    _rigTest('a re-attach keeps the older turns once: the thread never gets shorter', (r, async) {
      _talk(r.keeper, 6);
      final s = r.session()..acquire();
      r.pump();
      final whole = _texts(s.state);
      expect(whole, hasLength(12));
      final sizes = <int>[];
      s.addListener(() => sizes.add(s.state.items.length));

      cut(r.keeper, 3);
      r.keeper.dropLink();
      r.async.flushMicrotasks();
      r.async.elapse(const Duration(seconds: 2));
      expect(s.link, AgentLink.live);
      expect(r.keeper.loadCount, 2, reason: 'it re-attached and was replayed the short log');

      expect(_texts(s.state).first, hostDroppedKey, reason: 'one quiet line at the top');
      expect(_texts(s.state).skip(1), whole, reason: 'every turn, once, in order');
      expect(s.state.items.where((i) => i.key == hostDroppedKey), hasLength(1));
      expect(s.state.items.where((i) => i.key == phoneEarlierKey), isEmpty, reason: 'the overlap is proven: no divider');
      expect(sizes.where((n) => n < 12), isEmpty, reason: 'never shorter on screen, not even while the replay arrives');
      final keys = [for (final i in s.state.items) i.key];
      expect(keys.toSet(), hasLength(keys.length));

      // And it goes on from there: a new answer lands at the end.
      r.keeper.update(agentChunk('after', messageId: 'a9'));
      r.pump();
      expect(_texts(s.state).last, 'agent:after');
      expect(_texts(s.state).where((t) => t == 'user:question 0'), hasLength(1));
      s.dispose();
    });

    _rigTest('the saved copy keeps the older turns too, through the next restart', (r, async) {
      _talk(r.keeper, 6);
      final first = r.session()..acquire();
      r.pump();
      final whole = _texts(first.state);
      first
        ..release()
        ..dispose();

      // The keeper has dropped three turns meanwhile; the restart shows the
      // saved copy, then the (shorter) replay.
      cut(r.keeper, 3);
      r.host.attachGate = Completer<void>();
      final second = r.session()..acquire();
      r.pump();
      expect(_texts(second.state), whole);
      r.host.attachGate!.complete();
      r.pump();
      expect(second.attached, isTrue);
      expect(_texts(second.state).first, hostDroppedKey);
      expect(_texts(second.state).skip(1), whole, reason: 'what the copy had is kept, once');
      second.release();
      final lines = r.cache.stored['m1/k1']!.lines;
      expect([for (final n in [0, 2, 5]) lines.where((l) => l.contains('question $n')).length], [1, 1, 1], reason: 'the copy has them, once');
      expect(lines, hasLength(12));
      second.dispose();

      // The keeper is unreachable on the next start: the copy alone shows it all.
      r.host.attachGate = Completer<void>();
      final third = r.session()..acquire();
      r.pump();
      expect(_texts(third.state).first, hostDroppedKey, reason: 'the line is part of the copy\'s answer');
      expect(_texts(third.state).skip(1), whole);
      third.dispose();
    });

    _rigTest('a replay that has nothing in common with what the phone holds: the phone\'s part stays above a divider', (r, async) {
      _talk(r.keeper, 3);
      final s = r.session()..acquire();
      r.pump();
      final before = _texts(s.state);

      // The link drops, and the keeper has started over meanwhile (say its log
      // was lost): other turns, other ids.
      r.keeper.dropLink();
      r.async.flushMicrotasks();
      r.keeper.log.clear();
      for (var i = 10; i < 12; i++) {
        r.keeper.update(userChunk('new question $i', messageId: 'nu$i'));
        r.keeper.update(agentChunk('new answer $i', messageId: 'na$i'));
      }
      r.async.elapse(const Duration(seconds: 2));
      expect(s.link, AgentLink.live);

      expect(_texts(s.state), [
        ...before,
        phoneEarlierKey,
        'user:new question 10',
        'agent:new answer 10',
        'user:new question 11',
        'agent:new answer 11',
      ]);
      expect(
        s.state.items.firstWhere((i) => i.key == phoneEarlierKey),
        isA<TranscriptNote>().having((n) => n.text, 'text', 'Earlier, from this phone'),
      );
      s.dispose();
    });

    _rigTest('a replay as long as what the phone holds changes nothing: no divider, no note, the same keys', (r, async) {
      _talk(r.keeper, 4);
      final s = r.session()..acquire();
      r.pump();
      final keys = [for (final i in s.state.items) i.key];
      final texts = _texts(s.state);

      r.keeper.dropLink();
      r.async.flushMicrotasks();
      r.async.elapse(const Duration(seconds: 2));
      expect(s.link, AgentLink.live);
      expect(_texts(s.state), texts);
      expect([for (final i in s.state.items) i.key], keys);
      s.dispose();
    });
  });

  group('pre-connect', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('precon'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a finger down attaches once and shows nothing different; letting go releases', () {
      fakeAsync((async) {
        final h = _Fleet(async, recentAttached: 0);
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a')..add(id: 'k1', sessionId: 's1');
        h.refresh();
        final s = h.repo.byKey('a/k1')! as AcpAgentSession;
        final attached = host.attachCalls;
        expect(s.attached, isFalse);
        var notified = 0;
        h.repo.addListener(() => notified++);

        final hold = h.repo.preconnect('a/k1');
        async.elapse(const Duration(milliseconds: 50));
        expect(s.attached, isTrue, reason: 'attaching since the finger went down');
        expect(host.attachCalls, attached + 1);
        expect(s.link, AgentLink.live, reason: 'the board shows a healthy, unwatched session; not Connecting');
        expect(notified, 0, reason: 'the board is told nothing');

        hold.cancel();
        hold.cancel();
        async.elapse(const Duration(milliseconds: 50));
        expect(s.attached, isFalse, reason: 'the finger slid away: the channel is given back');
        expect(host.attachCalls, attached + 1, reason: 'no second attach');
      });
    });

    test('a tap: the screen takes its own hold, then the finger-down hold goes; the attach is never redone', () {
      fakeAsync((async) {
        final h = _Fleet(async, recentAttached: 0);
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a')..add(id: 'k1', sessionId: 's1');
        h.refresh();
        final s = h.repo.byKey('a/k1')! as AcpAgentSession;
        final attached = host.attachCalls;

        final hold = h.repo.preconnect('a/k1');
        async.elapse(const Duration(milliseconds: 30));
        s.acquire(); // the route builds the screen
        hold.cancel();
        async.elapse(const Duration(milliseconds: 30));
        expect(s.attached, isTrue);
        expect(host.attachCalls, attached + 1, reason: 'one attach for the finger and the screen together');
        s.release();
        async.elapse(const Duration(milliseconds: 30));
        expect(s.attached, isFalse);
      });
    });

    test('a hold nobody cancels lets go by itself', () {
      fakeAsync((async) {
        final h = _Fleet(async, recentAttached: 0, preconnectHold: const Duration(seconds: 6));
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a')..add(id: 'k1', sessionId: 's1');
        h.refresh();
        final s = h.repo.byKey('a/k1')! as AcpAgentSession;
        h.repo.preconnect('a/k1');
        async.elapse(const Duration(seconds: 5));
        expect(s.attached, isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(s.attached, isFalse);
        expect(host.openLinks, 0);
      });
    });

    test('nothing in the background', () {
      fakeAsync((async) {
        final h = _Fleet(async, recentAttached: 0);
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a')..add(id: 'k1', sessionId: 's1');
        h.refresh();
        final attached = host.attachCalls;

        h.repo.onLifecycleState(AppLifecycleState.paused);
        final hold = h.repo.preconnect('a/k1');
        async.elapse(const Duration(milliseconds: 100));
        expect(identical(hold, Preconnect.none), isTrue);
        expect(host.attachCalls, attached);

        h.repo.onLifecycleState(AppLifecycleState.resumed);
        async.elapse(const Duration(milliseconds: 100));
        final back = h.repo.preconnect('a/k1');
        async.elapse(const Duration(milliseconds: 100));
        expect(identical(back, Preconnect.none), isFalse);
        expect(host.attachCalls, attached + 1);
        back.cancel();
      });
    });

    test('never past the machine\'s channel limit', () {
      fakeAsync((async) {
        final h = _Fleet(async, recentAttached: 0);
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a');
        // Four sessions are waiting for the person: they hold the four channels.
        for (var i = 0; i < 4; i++) {
          host.add(id: 'w$i', sessionId: 'sw$i').askPermission();
        }
        host.add(id: 'idle', sessionId: 'sidle');
        h.refresh();
        async.elapse(const Duration(seconds: 1));
        expect(host.openLinks, 4);

        final hold = h.repo.preconnect('a/idle');
        async.elapse(const Duration(milliseconds: 100));
        expect(identical(hold, Preconnect.none), isTrue, reason: 'it would cost a waiting session its channel');
        expect(host.openLinks, 4);
        expect({for (final k in host.keepers.values) if (k.linkOpen) k.info.id}, {'w0', 'w1', 'w2', 'w3'});

        // One of them is answered and frees a slot: now there is room.
        final w0 = h.repo.byKey('a/w0')! as AcpAgentSession;
        w0.answerPermission(w0.state.pending.single.id, const PermissionSelected('allow'));
        async.elapse(const Duration(seconds: 1));
        h.refresh();
        async.elapse(const Duration(seconds: 1));
        final room = h.repo.preconnect('a/idle');
        async.elapse(const Duration(milliseconds: 100));
        expect(identical(room, Preconnect.none), isFalse);
        expect(host.openLinks, lessThanOrEqualTo(4));
        expect(host.keepers['idle']!.linkOpen, isTrue);
        room.cancel();
      });
    });

    test('a session that is already attached costs nothing, whatever the limit', () {
      fakeAsync((async) {
        final h = _Fleet(async, recentAttached: 0);
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a');
        for (var i = 0; i < 4; i++) {
          host.add(id: 'w$i', sessionId: 'sw$i').askPermission();
        }
        h.refresh();
        async.elapse(const Duration(seconds: 1));
        final attached = host.attachCalls;
        final hold = h.repo.preconnect('a/w0');
        async.elapse(const Duration(milliseconds: 100));
        expect(host.attachCalls, attached);
        expect(host.openLinks, 4);
        hold.cancel();
        async.elapse(const Duration(milliseconds: 100));
        expect(host.openLinks, 4, reason: 'it is waiting: the board keeps it attached');
      });
    });

    test('a session that ended, or one the board does not have, gets no hold', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        addTearDown(h.dispose);
        h.addMachine('a');
        h.host('a').add(id: 'gone', state: KeeperState.exited, exitCode: 0);
        h.refresh();
        expect(identical(h.repo.preconnect('a/gone'), Preconnect.none), isTrue);
        expect(identical(h.repo.preconnect('a/nope'), Preconnect.none), isTrue);
      });
    });

    test('the copy is read when the finger goes down, before the route is pushed', () {
      fakeAsync((async) {
        final cache = MemoryTranscriptCache();
        final h = _Fleet(async, recentAttached: 0, cache: cache);
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a');
        final keeper = host.add(id: 'k1', sessionId: 's1');
        _talk(keeper, 2);
        h.refresh();
        final s = h.repo.byKey('a/k1')! as AcpAgentSession;
        s.acquire(); // a run earlier saved its transcript when the screen closed
        async.elapse(const Duration(milliseconds: 50));
        s.release();
        async.elapse(const Duration(milliseconds: 50));
        final saved = cache.stored['a/k1']!;
        // The restart: a repository with no memory of it.
        h.repo.dispose();
        final again = _Fleet(async, recentAttached: 0, cache: cache);
        addTearDown(again.dispose);
        again._hosts['a'] = host;
        again.addMachine('a');
        host.attachGate = Completer<void>();
        again.refresh();
        final fresh = again.repo.byKey('a/k1')! as AcpAgentSession;
        expect(fresh.state.items, isEmpty);

        final hold = again.repo.preconnect('a/k1');
        async.elapse(const Duration(milliseconds: 50));
        expect(fresh.state.items, hasLength(4), reason: 'read at finger-down, with the attach still on its way');
        expect(fresh.cachedAsOf, saved.asOf);
        expect(fresh.attached, isFalse);
        hold.cancel();
      });
    });
  });

  group('a finished turn nobody has seen is not attached by the board, its copy is read', () {
    test('the copies of waiting and finished sessions are read when the board lists them; the rest are not', () {
      fakeAsync((async) {
        final cache = MemoryTranscriptCache();
        final h = _Fleet(async, recentAttached: 0, cache: cache);
        addTearDown(h.dispose);
        h.addMachine('a');
        final host = h.host('a');
        final seeded = <String>['done', 'plain'];
        for (final id in seeded) {
          final k = host.add(id: id, sessionId: 's$id');
          _talk(k, 1);
        }
        host.keepers['done']!.unseenDone = true;
        // Both have a saved copy from an earlier run.
        for (final id in seeded) {
          final line = jsonEncode({
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': {'sessionId': 's$id', 'update': agentChunk('old $id', messageId: 'o')},
          });
          cache.stored['a/$id'] = TranscriptSnapshot(sessionId: 's$id', asOf: _t0, lines: [line]);
        }
        h.refresh();
        async.elapse(const Duration(seconds: 1));

        expect(cache.reads, 1, reason: 'only the finished one: the plain one nobody asked about');
        final done = h.repo.byKey('a/done')! as AcpAgentSession;
        expect(done.attached, isFalse, reason: 'attaching would clear the keeper\'s "to review" for every device');
        expect(done.unseenDone, isTrue);
        expect(done.cachedAsOf, isNotNull);
        expect(done.state.items, hasLength(1));
        expect((h.repo.byKey('a/plain')! as AcpAgentSession).cachedAsOf, isNull);
      });
    });
  });

  group('the repository forgets copies of what the host forgot', () {
    test('a listing without a keeper, and a machine that is removed', () {
      fakeAsync((async) {
        final cache = MemoryTranscriptCache();
        final h = _Fleet(async, recentAttached: 0, cache: cache);
        addTearDown(h.dispose);
        final host = h.host('a');
        host.add(id: 'k1', sessionId: 's1');
        host.add(id: 'k2', sessionId: 's2');
        h.addMachine('a'); // connecting lists the host: the first listing of the run
        expect(cache.retained.last.$2, {'k1', 'k2'}, reason: 'the first listing of the run sweeps what is left of keepers that went while the app was closed');
        final sweeps = cache.retained.length;

        host.keepers.remove('k2');
        h.refresh();
        expect(cache.deleted, ['a/k2'], reason: 'the host no longer has k2: its copy goes with the session');
        expect(cache.retained.length, sweeps, reason: 'one sweep per machine per run, not one per listing');

        unawaited(h.machines.remove('a'));
        async.elapse(const Duration(seconds: 1));
        expect(cache.machinesDeleted, ['a'], reason: 'a machine the person removed takes its transcripts along');
      });
    });
  });
}

/// A copy of [s] with other fields (a snapshot is immutable).
TranscriptSnapshot snapshotWith(TranscriptSnapshot s, {String? sessionId}) => TranscriptSnapshot(
  sessionId: sessionId ?? s.sessionId,
  asOf: s.asOf,
  lines: s.lines,
  setup: s.setup,
  partial: s.partial,
);

class _Fleet {
  _Fleet(this.async, {int recentAttached = 3, MemoryTranscriptCache? cache, Duration preconnectHold = const Duration(seconds: 6)}) {
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
      recentAttached: recentAttached,
      cache: cache,
      preconnectHold: preconnectHold,
    );
  }

  final FakeAsync async;
  late final MachineRepository machines;
  late final FleetRepository fleet;
  late final AgentSessionRepository repo;
  final _hosts = <String, FakeAgentHost>{};

  FakeAgentHost host(String machineId) =>
      _hosts.putIfAbsent(machineId, () => FakeAgentHost(clock: () => _t0.add(async.elapsed)));

  void addMachine(String id) {
    unawaited(machines.save(_profile(id), secrets: const MachineSecrets(password: 'x')));
    async.elapse(const Duration(seconds: 1));
    expect(fleet.connection(id)!.isLive, isTrue);
  }

  /// A listing now.
  void refresh() {
    unawaited(repo.refresh());
    async.elapse(const Duration(milliseconds: 100));
  }

  void dispose() {
    repo.dispose();
    fleet.dispose();
  }
}
