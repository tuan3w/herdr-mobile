// Agent sessions: one AcpAgentSession over a scripted keeper, and the
// repository that keeps one per keeper of every connected machine, with only a
// few of them attached. All time is fake: backoff, the 90 s detach and the
// board's listing are asserted to the millisecond.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/acp/json_rpc.dart';
import 'package:herdr_mobile/data/acp/prompt_queue.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_run.dart' show SubagentLogStatus, SubagentStatus;
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/agent_session_repository.dart';
import 'package:herdr_mobile/data/repositories/attention_set.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/reviewed_state.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import 'acp/support/fake_agent.dart' show claudeInitialize, codexInitialize, ompInitialize;
import 'support/fake_agent_host.dart';
import 'support/fake_fs.dart';
import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_stores.dart';

final _t0 = DateTime.utc(2026, 3, 1, 12);

MachineProfile _profile(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.local', username: 'u');

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

// -- one session -------------------------------------------------------------

class _Rig {
  _Rig(
    this.async, {
    FakeKeeper Function(FakeAgentHost host)? seed,
    ReviewedState? reviewed,
    int maxAttempts = 12,
    FakeFs? fs,
  })  : host = FakeAgentHost(clock: () => _t0.add(async.elapsed)),
        reviewed = reviewed ?? ReviewedState() {
    // A machine that is online: sessions only retry against one.
    machine = MachineConnection(
      profile: _profile('m1', 'studio-mac'),
      api: HerdrApi(FakeTransport()..fs = fs),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    )..start();
    async.flushMicrotasks();
    expect(machine.isLive, isTrue);
    machineTimers = _timers(async);
    keeper = seed == null ? host.add() : seed(host);
    session = AcpAgentSession(
      machine: machine,
      host: host,
      info: keeper.info,
      reviewed: this.reviewed,
      clock: () => now,
      jitter: () => jitterFactor,
      maxAttempts: maxAttempts,
    )..addListener(() => notifications++);
  }

  final FakeAsync async;
  final FakeAgentHost host;
  final ReviewedState reviewed;
  late final MachineConnection machine;
  late final FakeKeeper keeper;
  late final AcpAgentSession session;
  var notifications = 0;

  /// The retry spread the session draws (1 = none).
  double jitterFactor = 1;

  /// Timers the live machine itself keeps: a session adds none when idle.
  late final int machineTimers;

  DateTime get now => _t0.add(async.elapsed);

  /// Enough time for the listeners' coalescing timer (16 ms) to fire.
  void pump([int ms = 20]) => async.elapse(Duration(milliseconds: ms));

  void connect() {
    unawaited(session.connect());
    pump();
  }

  PendingPermission get permission => session.state.pending.whereType<PendingPermission>().single;

  /// The listing says this about the keeper (a session nobody has attached
  /// shows it).
  void listed({int pending = 0, bool turnActive = false, bool unseenDone = false, DateTime? lastEventAt}) {
    final i = keeper.info;
    session.update(KeeperInfo(
      id: i.id,
      agent: i.agent,
      cwd: i.cwd,
      state: i.state,
      startedAt: i.startedAt,
      sessionId: i.sessionId,
      title: i.title,
      pending: pending,
      turnActive: turnActive,
      unseenDone: unseenDone,
      lastEventAt: lastEventAt,
    ));
  }

  void dispose() {
    session.dispose();
    machine.dispose();
  }
}

void _rigTest(
  String name,
  void Function(_Rig r) body, {
  FakeKeeper Function(FakeAgentHost host)? seed,
  ReviewedState? reviewed,
  int maxAttempts = 12,
  FakeFs? fs,
}) =>
    test(name, () {
      fakeAsync((async) {
        final r = _Rig(async, seed: seed, reviewed: reviewed, maxAttempts: maxAttempts, fs: fs);
        body(r);
        r.dispose();
      });
    });

/// How many sessions wait for the person, and how many finished turns nobody
/// looked at, as the repository holds them (the board's counts come from
/// `AttentionSet`, which also asks for reachability).
extension on AgentSessionRepository {
  int get blockedCount => sessions.where(AttentionSet.sessionBlocked).length;
  int get reviewCount => sessions.where((s) => s.unseenDone).length;
}

void main() {
  group('attaching', () {
    _rigTest('a keeper without a session gets a new one', (r) {
      r.connect();

      expect(r.session.link, AgentLink.live);
      expect(r.session.error, isNull);
      expect(r.keeper.newCount, 1);
      expect(r.keeper.loadCount, 0);
      expect(r.session.state.sessionId, r.keeper.sessionId);
      expect(r.session.key, 'm1/${r.keeper.info.id}');
      expect(r.session.agentLabel, 'omp');
      expect(r.session.title, 'proj', reason: 'no title yet: the folder');
    });

    _rigTest('a keeper that holds a session is loaded and its replay builds the transcript', (r) {
      r.connect();

      expect(r.keeper.loadCount, 1);
      expect(r.keeper.newCount, 0);
      final items = r.session.state.items.whereType<TranscriptMessage>().toList();
      expect([for (final m in items) m.text], ['fix the login', 'done']);
      expect(r.session.link, AgentLink.live);
    }, seed: (h) => h.add(sessionId: 's1')..log.addAll([userChunk('fix the login'), agentChunk('done')]));

    _rigTest('a request the keeper still holds comes back after the load and can be answered', (r) {
      final request = r.keeper.askPermission(command: 'rm -rf build');
      r.connect();

      expect(r.session.phase, AgentPhase.blockedOnPermission);
      r.session.answerPermission(r.permission.id, const PermissionSelected('deny'));
      r.pump();
      expect(request.answer, {
        'outcome': {'outcome': 'selected', 'optionId': 'deny'},
      });
      expect(r.session.phase, AgentPhase.idle);
    }, seed: (h) => h.add(sessionId: 's1'));

    _rigTest('a keeper that already exited is ended from the start and never attached', (r) {
      r.connect();
      r.async.elapse(const Duration(minutes: 5));

      expect(r.session.link, AgentLink.ended);
      expect(r.session.error, 'omp exited with code 2.');
      expect(r.host.attachCalls, 0);
    }, seed: (h) => h.add(state: KeeperState.exited, exitCode: 2));

    _rigTest('the session title is the agent\'s, else the folder\'s name', (r) {
      r.connect();
      expect(r.session.title, 'bảng điều khiển');

      r.keeper.update({'sessionUpdate': 'session_info_update', 'title': 'Sửa lỗi đăng nhập'});
      r.pump();
      expect(r.session.title, 'Sửa lỗi đăng nhập');
    }, seed: (h) => h.add(cwd: '/home/u/Dự án thử nghiệm/bảng điều khiển/'));

    _rigTest('the root folder is its own name', (r) {
      expect(r.session.title, '/');
    }, seed: (h) => h.add(cwd: '/'));
  });

  group('requests from the agent', () {
    _rigTest('a permission is answered exactly once', (r) {
      r.connect();
      final request = r.keeper.askPermission();
      r.pump();
      expect(r.session.phase, AgentPhase.blockedOnPermission);

      final id = r.permission.id;
      r.session.answerPermission(id, const PermissionSelected('allow'));
      r.session.answerPermission(id, const PermissionSelected('always'));
      r.pump();

      expect(r.keeper.answers, hasLength(1));
      expect(request.answer, {
        'outcome': {'outcome': 'selected', 'optionId': 'allow'},
      });
      expect(r.session.phase, AgentPhase.idle);
    });

    _rigTest('an option the request did not offer is not an allow', (r) {
      r.connect();
      final request = r.keeper.askPermission();
      r.pump();

      r.session.answerPermission(r.permission.id, const PermissionSelected('allow-everything'));
      r.pump();

      expect(request.answer, {
        'outcome': {'outcome': 'cancelled'},
      });
    });

    _rigTest('nothing is allowed by default, by timeout, or when the link drops', (r) {
      r.connect();
      final request = r.keeper.askPermission();
      r.pump();
      expect(r.session.phase, AgentPhase.blockedOnPermission);

      r.async.elapse(const Duration(hours: 2));
      expect(request.answered, isFalse, reason: 'no timeout answers for the person');
      expect(r.session.phase, AgentPhase.blockedOnPermission);

      r.keeper.dropLink();
      r.async.flushMicrotasks();
      expect(r.session.state.pending, isEmpty, reason: 'nobody can answer on a dead link');
      expect(request.answered, isFalse, reason: 'the keeper keeps the request; it was not answered');

      // The next attach brings it back, still unanswered.
      r.async.elapse(const Duration(seconds: 2));
      expect(r.session.link, AgentLink.live);
      expect(r.session.phase, AgentPhase.blockedOnPermission);
      expect(request.answered, isFalse);
    });

    _rigTest('ending the session never answers a waiting permission', (r) {
      r.connect();
      final request = r.keeper.askPermission();
      r.pump();

      unawaited(r.session.end());
      r.pump();

      expect(r.session.link, AgentLink.ended);
      expect(r.session.error, 'Ended from this phone.');
      expect(request.answered, isFalse);
      expect(r.session.state.pending, isEmpty);
      expect(r.host.killed, [r.keeper.info.id]);
    });

    _rigTest('cancel answers what waits as cancelled and stops the turn', (r) {
      r.connect();
      r.keeper.turn = Completer<String>();
      unawaited(r.session.send('build it'));
      r.pump();
      expect(r.session.phase, AgentPhase.working);
      final request = r.keeper.askPermission();
      r.pump();
      expect(r.session.phase, AgentPhase.blockedOnPermission);

      r.session.cancel();
      r.pump();

      expect(request.answer, {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(r.keeper.cancelsReceived, 1);
      r.keeper.finishTurn('cancelled');
      r.pump();
      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.unseenDone, isFalse, reason: 'the person cancelled it, there is nothing to review');
    });

    _rigTest('a question is answered once, with the form the person filled', (r) {
      r.connect();
      final request = r.keeper.askQuestion();
      r.pump();
      expect(r.session.phase, AgentPhase.blockedOnQuestion);

      final id = r.session.state.pending.single.id;
      r.session.answerQuestion(id, const ElicitationAccept({'approach': 'safe'}));
      r.session.answerQuestion(id, const ElicitationDecline());
      r.pump();

      expect(r.keeper.answers, hasLength(1));
      expect(request.answer, {
        'action': 'accept',
        'content': {'approach': 'safe'},
      });
      expect(r.session.phase, AgentPhase.idle);
    });

    _rigTest('an answer for a request that is not waiting does nothing', (r) {
      r.connect();
      r.session.answerPermission(99, const PermissionSelected('allow'));
      r.session.answerQuestion(99, const ElicitationCancel());
      r.pump();
      expect(r.keeper.answers, isEmpty);
      expect(r.session.error, isNull);
    });
  });

  group('link drops', () {
    _rigTest('reconnects with 1, 2, 4, 8, 15, 30, 30 s backoff and keeps the transcript', (r) {
      r.connect();
      expect(r.session.state.items, hasLength(1));
      r.host.attachFailures.addAll([
        for (var i = 0; i < 7; i++) const AgentHostException('The host did not answer.'),
      ]);

      r.keeper.dropLink();
      r.async.flushMicrotasks();
      final droppedAt = r.now;
      expect(r.session.link, AgentLink.reconnecting);
      expect(r.session.state.disconnected, isTrue);
      expect(r.session.state.items, hasLength(1), reason: 'the old transcript stays on screen');

      r.async.elapse(const Duration(milliseconds: 999));
      expect(r.host.attachCalls, 1, reason: 'the first retry waits a full second');
      r.async.elapse(const Duration(milliseconds: 1));
      expect(r.host.attachCalls, 2);
      expect(r.session.error, 'The host did not answer.');
      expect(r.session.state.items, hasLength(1));

      r.async.elapse(const Duration(minutes: 5));
      expect(r.session.link, AgentLink.live);
      expect(r.session.error, isNull);
      expect(r.host.attachCalls, 9, reason: 'seven failures, then the attach that worked');
      final times = r.host.attachTimes;
      expect(times[1].difference(droppedAt), const Duration(seconds: 1));
      expect([
        for (var i = 1; i < 8; i++) times[i + 1].difference(times[i]).inSeconds,
      ], [2, 4, 8, 15, 30, 30, 30]);
      expect(r.session.state.disconnected, isFalse);
      expect(r.session.state.items, hasLength(1), reason: 'replayed, not doubled');
      expect(r.keeper.loadCount, 2);
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('hello')));

    _rigTest('a drop mid-conversation shows what the agent said meanwhile after the replay', (r) {
      r.connect();
      r.keeper.dropLink();
      r.async.flushMicrotasks();
      r.keeper.say('written while the phone was away', messageId: 'a2');

      r.async.elapse(const Duration(seconds: 2));

      final text = [for (final m in r.session.state.items.whereType<TranscriptMessage>()) m.text];
      expect(text, ['hello', 'written while the phone was away']);
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('hello')));

    _rigTest('the keeper exited meanwhile: the session ends with the reason and does not retry', (r) {
      r.connect();
      r.keeper.exit(code: 1, reason: 'The agent exited with code 1. out of credit');
      r.async.flushMicrotasks();
      r.pump();

      expect(r.session.link, AgentLink.ended);
      expect(r.session.error, 'The agent exited with code 1. out of credit');
      final attaches = r.host.attachCalls;
      r.async.elapse(const Duration(minutes: 5));
      expect(r.host.attachCalls, attaches);
    });

    _rigTest('a keeper gone from the host ends the session', (r) {
      r.connect();
      r.host.keepers.clear();
      r.keeper.dropLink();
      r.async.flushMicrotasks();
      r.pump();

      expect(r.session.link, AgentLink.ended);
      expect(r.session.error, 'The session is gone from studio-mac.');
    });

    _rigTest('a refusal that retrying cannot cure fails the session for good', (r) {
      r.host.attachFailures.add(const AgentHostException('Not allowed to attach.', fatal: true));
      r.connect();

      expect(r.session.link, AgentLink.failed);
      expect(r.session.error, 'Not allowed to attach.');
      r.async.elapse(const Duration(minutes: 10));
      expect(r.host.attachCalls, 1);
    });

    _rigTest('a first attach that fails softly retries and then goes live', (r) {
      r.host.attachFailures.add(const AgentHostException('ssh: connection reset'));
      r.connect();
      expect(r.session.link, AgentLink.reconnecting);
      expect(r.session.error, 'ssh: connection reset');

      r.async.elapse(const Duration(seconds: 1));
      expect(r.session.link, AgentLink.live);
    });

    _rigTest('an agent that refuses the session fails it with the agent\'s words', (r) {
      // The keeper's info names a session the agent no longer knows.
      r.keeper.sessionId = 'other';
      r.connect();

      expect(r.session.link, AgentLink.failed);
      expect(r.session.error, 'unknown session');
      r.async.elapse(const Duration(minutes: 5));
      expect(r.host.attachCalls, 1);
    }, seed: (h) => h.add(sessionId: 'stale'));
  });

  group('app lifecycle', () {
    _rigTest('detaches 90 s after the app is backgrounded, and nothing runs until it is back', (r) {
      r.connect();
      r.session.onLifecycleState(AppLifecycleState.paused);

      r.async.elapse(const Duration(seconds: 89));
      expect(r.session.link, AgentLink.live);
      expect(r.keeper.attached, isTrue);

      r.async.elapse(const Duration(seconds: 1));
      expect(r.session.link, AgentLink.reconnecting);
      expect(r.session.state.disconnected, isTrue);
      expect(r.keeper.attached, isFalse, reason: 'the transport is hung up at once; the keeper lives on');
      // The keeper lives on and writes; a detached session hears none of it.
      r.keeper.say('written while detached', messageId: 'a2');

      final attaches = r.host.attachCalls;
      final lists = r.host.listCalls;
      r.async.elapse(const Duration(minutes: 30));
      expect(r.host.attachCalls, attaches);
      expect(r.host.listCalls, lists);
      expect(r.session.state.items, hasLength(1), reason: 'a detached session hears nothing');
      expect(_timers(r.async), r.machineTimers, reason: 'a backgrounded session keeps no timer');

      r.session.onLifecycleState(AppLifecycleState.resumed);
      r.pump();
      expect(r.host.attachCalls, attaches + 1, reason: 'back at once, no backoff');
      expect(r.session.link, AgentLink.live);
      expect(r.session.state.disconnected, isFalse);
      expect(r.session.state.items, hasLength(2), reason: 'the replay brings what the keeper kept meanwhile');
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('hello')));

    _rigTest('coming back before 90 s keeps the transport', (r) {
      r.connect();
      r.session.onLifecycleState(AppLifecycleState.hidden);
      r.async.elapse(const Duration(seconds: 60));
      r.session.onLifecycleState(AppLifecycleState.resumed);
      r.async.elapse(const Duration(minutes: 10));

      expect(r.host.attachCalls, 1);
      expect(r.session.link, AgentLink.live);
    });

    _rigTest('hidden then paused does not restart the clock; inactive is not backgrounding', (r) {
      r.connect();
      r.session.onLifecycleState(AppLifecycleState.inactive);
      r.async.elapse(const Duration(minutes: 5));
      expect(r.session.link, AgentLink.live);

      r.session.onLifecycleState(AppLifecycleState.hidden);
      r.async.elapse(const Duration(seconds: 60));
      r.session.onLifecycleState(AppLifecycleState.paused);
      r.async.elapse(const Duration(seconds: 29));
      expect(r.session.link, AgentLink.live);
      r.async.elapse(const Duration(seconds: 1));
      expect(r.session.link, AgentLink.reconnecting);
    });

    _rigTest('a retry in the grace period stops at the detach and does not start again by itself', (r) {
      r.connect();
      r.host.attachFailures.addAll([for (var i = 0; i < 50; i++) const AgentHostException('down')]);
      r.session.onLifecycleState(AppLifecycleState.paused);
      r.keeper.dropLink();
      r.async.elapse(const Duration(seconds: 89));
      expect(r.host.attachCalls, greaterThan(1), reason: 'retries run while the grace lasts');

      r.async.elapse(const Duration(seconds: 1));
      final attaches = r.host.attachCalls;
      r.async.elapse(const Duration(minutes: 20));
      expect(r.host.attachCalls, attaches);
      expect(_timers(r.async), r.machineTimers);
    });
  });

  group('kept alive in the background', () {
    _rigTest('stays attached however long, and the usual clock starts when it is turned off', (r) {
      r.connect();
      r.session.keepAliveInBackground = true;
      r.session.onLifecycleState(AppLifecycleState.paused);

      r.async.elapse(const Duration(minutes: 30));
      expect(r.session.link, AgentLink.live);
      expect(r.keeper.attached, isTrue);
      expect(r.host.attachCalls, 1);

      // Past the grace period already: letting go is immediate.
      r.session.keepAliveInBackground = false;
      expect(r.session.link, AgentLink.reconnecting);
      expect(r.keeper.attached, isFalse);

      r.session.onLifecycleState(AppLifecycleState.resumed);
      r.pump();
      expect(r.session.link, AgentLink.live, reason: 'back in front, it attaches again');
    });

    _rigTest('turned off inside the grace period it detaches at 90 s, not before', (r) {
      r.connect();
      r.session.keepAliveInBackground = true;
      r.session.onLifecycleState(AppLifecycleState.paused);
      r.async.elapse(const Duration(seconds: 30));
      r.session.keepAliveInBackground = false;

      r.async.elapse(const Duration(seconds: 59));
      expect(r.session.link, AgentLink.live);
      r.async.elapse(const Duration(seconds: 1));
      expect(r.session.link, AgentLink.reconnecting);
    });

    _rigTest('turned on after the app left but inside the grace period it is not detached', (r) {
      r.connect();
      r.session.onLifecycleState(AppLifecycleState.paused);
      r.async.elapse(const Duration(seconds: 60));
      r.session.keepAliveInBackground = true;
      r.async.elapse(const Duration(minutes: 5));
      expect(r.session.link, AgentLink.live);
    });

    _rigTest('a link that drops in the background is still brought back', (r) {
      r.connect();
      r.session.keepAliveInBackground = true;
      r.session.onLifecycleState(AppLifecycleState.paused);
      r.async.elapse(const Duration(minutes: 5));

      r.keeper.dropLink();
      r.async.elapse(const Duration(seconds: 5));
      expect(r.session.link, AgentLink.live);
      expect(r.host.attachCalls, 2);
    });

    _rigTest('in the background the text that streams in notifies about once per 2 s; a request at once', (r) {
      r.connect();
      r.session.keepAliveInBackground = true;
      r.session.onLifecycleState(AppLifecycleState.paused);

      final before = r.notifications;
      for (var i = 0; i < 100; i++) {
        r.keeper.say('word $i ', messageId: 'a1');
        r.async.elapse(const Duration(milliseconds: 40));
      }
      expect(r.notifications - before, inInclusiveRange(1, 3), reason: '4 s of text');
      expect(r.session.state.items, isNotEmpty, reason: 'the text is not lost, only the telling is slower');

      final n = r.notifications;
      r.keeper.askPermission();
      r.pump(40);
      expect(r.notifications, greaterThan(n), reason: 'a request is news now, not in 2 s');
      expect(r.session.phase, AgentPhase.blockedOnPermission);
    }, seed: (h) => h.add(sessionId: 's1'));

    _rigTest('in the foreground, or when not kept alive, text notifies as before', (r) {
      r.connect();
      final before = r.notifications;
      for (var i = 0; i < 50; i++) {
        r.keeper.say('word $i ', messageId: 'a1');
        r.async.elapse(const Duration(milliseconds: 40));
      }
      expect(r.notifications - before, greaterThan(40), reason: 'one per frame-ish burst');

      // Away but not kept alive: the same.
      r.session.onLifecycleState(AppLifecycleState.paused);
      final away = r.notifications;
      for (var i = 0; i < 20; i++) {
        r.keeper.say('more $i ', messageId: 'a1');
        r.async.elapse(const Duration(milliseconds: 40));
      }
      expect(r.notifications - away, greaterThan(15));
    }, seed: (h) => h.add(sessionId: 's1'));

    _rigTest('what waits for the slow notification is told at once when the app is back', (r) {
      r.connect();
      r.session.keepAliveInBackground = true;
      r.session.onLifecycleState(AppLifecycleState.paused);
      r.async.elapse(const Duration(seconds: 3)); // the slow timer is idle
      r.keeper.say('late words', messageId: 'a1');
      r.pump(100);
      final n = r.notifications;

      r.session.onLifecycleState(AppLifecycleState.resumed);
      r.pump();
      expect(r.notifications, greaterThan(n));
    }, seed: (h) => h.add(sessionId: 's1'));

    test('the repository keeps its sessions and lists the online hosts every 90 s', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final a = h.host('a')..add(id: 'k1');
        final b = h.host('b')..add(id: 'k2');
        h.addMachine('a', 'alpha');
        h.addMachine('b', 'beta');
        expect(h.repo.backgroundRefreshEvery, const Duration(seconds: 90));
        h.repo.keepAliveInBackground = true;
        h.repo.onLifecycleState(AppLifecycleState.paused);
        h.conn('b').goOffline();
        final attaches = a.attachCalls;
        final listsA = a.listCalls;
        final listsB = b.listCalls;

        async.elapse(const Duration(seconds: 89));
        expect(a.listCalls, listsA);
        async.elapse(const Duration(seconds: 1));
        expect(a.listCalls, listsA + 1);
        async.elapse(const Duration(minutes: 9));
        expect(a.listCalls, listsA + 7);
        expect(b.listCalls, listsB, reason: 'an offline machine is not asked');

        expect(a.attachCalls, attaches, reason: 'nothing is attached again, nothing let go');
        expect(h.repo.byKey('a/k1')!.link, AgentLink.live);
        h.dispose();
      });
    });

    test('an unattached session that starts waiting is seen at the next listing, and gets a channel', () {
      fakeAsync((async) {
        final h = _Fleet(async, recentAttached: 0);
        final host = h.host('a');
        final idle = host.add(id: 'k1');
        h.addMachine('a', 'alpha');
        expect(_attached(h, 'a/k1'), isFalse);
        expect(h.repo.blockedCount, 0);

        h.repo.keepAliveInBackground = true;
        h.repo.onLifecycleState(AppLifecycleState.paused);
        idle.askPermission();
        async.elapse(const Duration(seconds: 91));

        expect(h.repo.blockedCount, 1);
        expect(_attached(h, 'a/k1'), isTrue, reason: 'waiting requests take a channel first');
        h.dispose();
      });
    });

    test('the attach cap and its order hold in the background', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h);
        h.addMachine('a', 'alpha');
        h.repo.keepAliveInBackground = true;
        h.repo.onLifecycleState(AppLifecycleState.paused);
        for (final id in ['k00', 'k01', 'k02', 'k03', 'k04']) {
          host.keepers[id]!.askPermission();
        }
        async.elapse(const Duration(minutes: 3));

        expect(host.peakOpenLinks, lessThanOrEqualTo(4));
        expect(_open(host), {'k00', 'k01', 'k02', 'k03'}, reason: 'waiting first, longest waiting first');
        h.dispose();
      });
    });

    test('turned off, the usual rules are back: detached at once when the grace is over, no more listing', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')..add(id: 'k1');
        h.addMachine('a', 'alpha');
        h.repo.keepAliveInBackground = true;
        h.repo.onLifecycleState(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 5));
        expect(h.repo.byKey('a/k1')!.link, AgentLink.live);

        h.repo.keepAliveInBackground = false;
        expect(h.repo.byKey('a/k1')!.link, AgentLink.reconnecting);
        final lists = host.listCalls;
        async.elapse(const Duration(minutes: 10));
        expect(host.listCalls, lists);
        h.dispose();
      });
    });

    test('resuming ends the background listing; the Agents tab rule is the only one left', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')..add(id: 'k1');
        h.addMachine('a', 'alpha');
        h.repo.keepAliveInBackground = true;
        h.repo.onLifecycleState(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 3));

        h.repo.onLifecycleState(AppLifecycleState.resumed);
        async.elapse(const Duration(seconds: 1));
        final lists = host.listCalls;
        async.elapse(const Duration(minutes: 10));
        expect(host.listCalls, lists, reason: 'board not visible, so no timer');
        h.dispose();
      });
    });

    test('a session that appears while the app is away and kept alive stays attached', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')..add(id: 'k1');
        h.addMachine('a', 'alpha');
        h.repo.keepAliveInBackground = true;
        h.repo.onLifecycleState(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 5));

        host.add(id: 'k2');
        async.elapse(const Duration(seconds: 90));
        expect(h.repo.byKey('a/k2')!.link, AgentLink.live);
        expect(_attached(h, 'a/k2'), isTrue);
        h.dispose();
      });
    });
  });

  group('the keeper\'s notices', () {
    _rigTest('another device attaching ends the session, retries stop, Take over comes back', (r) {
      r.connect();
      expect(r.session.evicted, isFalse);

      r.keeper.attach(); // another phone attaches; the keeper evicts this one
      r.async.flushMicrotasks();

      expect(r.session.link, AgentLink.ended);
      expect(r.session.evicted, isTrue);
      expect(r.session.error, 'Opened on another device.');
      r.async.elapse(const Duration(minutes: 10));
      expect(r.host.attachCalls, 1, reason: 'two phones must not evict each other for ever');
      expect(r.host.listCalls, 0);
      expect(_timers(r.async), r.machineTimers);

      unawaited(r.session.reattach());
      r.pump();
      expect(r.session.link, AgentLink.live);
      expect(r.session.evicted, isFalse);
      expect(r.host.attachCalls, 2);
      expect(r.keeper.attached, isTrue);
      expect(r.session.state.items, hasLength(1));
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('hello')));

    _rigTest('its own re-attach after a half-dead channel is not mistaken for another device', (r) {
      r.connect();
      for (var i = 0; i < 3; i++) {
        r.keeper.halfDie(); // the keeper evicts the dead channel when the new one attaches
        r.async.elapse(const Duration(seconds: 2));
        expect(r.session.link, AgentLink.live, reason: 'round $i');
        expect(r.session.evicted, isFalse);
      }
      expect(r.host.attachCalls, 4);
    });

    _rigTest('coming back from the background does not take a session that another device holds', (r) {
      r.connect();
      r.keeper.attach();
      r.async.flushMicrotasks();
      r.session.onLifecycleState(AppLifecycleState.paused);
      r.async.elapse(const Duration(minutes: 5));
      r.session.onLifecycleState(AppLifecycleState.resumed);
      r.async.elapse(const Duration(minutes: 1));

      expect(r.session.evicted, isTrue);
      expect(r.host.attachCalls, 1);
    });

    _rigTest('reattach does nothing on a live link or after the agent exited', (r) {
      r.connect();
      unawaited(r.session.reattach());
      r.pump();
      expect(r.host.attachCalls, 1);

      r.keeper.exit(code: 1, reason: 'out of credit');
      r.pump();
      expect(r.session.link, AgentLink.ended);
      expect(r.session.evicted, isFalse);
      unawaited(r.session.reattach());
      r.pump();
      expect(r.host.attachCalls, 1);
      expect(r.session.link, AgentLink.ended);
    });

    _rigTest('the agent exiting is told at once, with its exit code when it gives no reason', (r) {
      r.connect();
      r.keeper.exit(code: 137);
      r.async.flushMicrotasks();

      expect(r.session.link, AgentLink.ended);
      expect(r.session.error, 'omp exited with code 137.');
      expect(r.host.listCalls, 0, reason: 'the notice says it all');
      r.async.elapse(const Duration(minutes: 5));
      expect(r.host.attachCalls, 1);
    });
  });

  group('a session nobody has attached', () {
    _rigTest('shows the listing: a waiting request, a turn in flight, else idle; a listing opens no channel', (r) {
      expect(r.session.link, AgentLink.live);
      expect(r.session.attached, isFalse);
      expect(r.session.phase, AgentPhase.idle);

      r.listed(pending: 1);
      expect(r.session.phase, AgentPhase.blockedOnPermission);
      r.listed(turnActive: true);
      expect(r.session.phase, AgentPhase.working);
      r.listed(pending: 2, turnActive: true);
      expect(r.session.phase, AgentPhase.blockedOnPermission, reason: 'a waiting request wins');
      r.listed();
      expect(r.session.phase, AgentPhase.idle);
      expect(r.host.attachCalls, 0);
      expect(r.keeper.linkOpen, isFalse);
    });

    _rigTest('phaseSince follows the listing\'s phase, and a repeat of it changes nothing', (r) {
      r.async.elapse(const Duration(minutes: 1));
      r.listed(turnActive: true);
      expect(r.session.phaseSince, r.now);
      final since = r.session.phaseSince;

      r.async.elapse(const Duration(minutes: 5));
      r.listed(turnActive: true, lastEventAt: _t0.add(const Duration(minutes: 5)));
      expect(r.session.phaseSince, since);
    });

    _rigTest('a turn that ended unseen is a review until the person looks; another one is a review again', (r) {
      final first = _t0.add(const Duration(minutes: 1));
      r.listed(unseenDone: true, lastEventAt: first);
      expect(r.session.unseenDone, isTrue);

      r.session.markSeen();
      expect(r.session.unseenDone, isFalse);
      expect(r.reviewed.length, 1);
      r.listed(unseenDone: true, lastEventAt: first);
      expect(r.session.unseenDone, isFalse, reason: 'the same listing again is the same turn');

      r.listed(unseenDone: true, lastEventAt: _t0.add(const Duration(minutes: 9)));
      expect(r.session.unseenDone, isTrue, reason: 'a later turn');
      r.listed(turnActive: true, unseenDone: true, lastEventAt: _t0.add(const Duration(minutes: 9)));
      expect(r.session.unseenDone, isFalse, reason: 'it is working again, not waiting for a look');
    });

    _rigTest('a turn that ended unseen stays a review here after the load clears the keeper\'s, so an Undo holds', (r) {
      final ended = _t0.add(const Duration(minutes: 1));
      r.listed(unseenDone: true, lastEventAt: ended);
      r.session.acquire();
      r.pump();
      expect(r.session.attached, isTrue);

      r.session.markSeen(); // the person looked at the live replay
      expect(r.session.unseenDone, isFalse);
      expect(r.session.unmarkSeen(), isTrue); // and took it back
      r.listed(lastEventAt: ended); // the keeper forgot it when it was loaded
      expect(r.session.unseenDone, isTrue, reason: 'the Undo is not lost to the next listing');
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('done')));

    _rigTest('a person opening it attaches it; the link says connecting until the replay is done', (r) {
      r.session.acquire();
      expect(r.session.link, AgentLink.connecting);
      expect(r.session.held, isTrue);

      r.pump();
      expect(r.session.link, AgentLink.live);
      expect(r.session.attached, isTrue);
      expect(r.keeper.attached, isTrue);
      expect(r.session.state.items, hasLength(1));
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('hello')));

    _rigTest('closing the screen gives the channel back at once, and the listing speaks again', (r) {
      r.session.acquire();
      r.pump();
      expect(r.keeper.linkOpen, isTrue);

      r.session.release();
      expect(r.keeper.linkOpen, isFalse, reason: 'the host\'s channel is free again');
      r.pump();
      expect(r.session.attached, isFalse);
      expect(r.session.link, AgentLink.live);
      expect(r.session.state.disconnected, isTrue);
      expect(_timers(r.async), r.machineTimers);

      r.session.acquire();
      r.pump();
      expect(r.session.attached, isTrue);
      expect(r.keeper.loadCount, 2, reason: 'opening it again replays');
      expect(r.session.state.items, hasLength(1), reason: 'replayed, not doubled');
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('hello')));

    _rigTest('what the repository wants keeps it attached after the screen goes; a held one is not let go', (r) {
      r.session.want(true);
      r.pump();
      expect(r.session.attached, isTrue);

      r.session.acquire();
      r.session.release();
      r.pump();
      expect(r.session.attached, isTrue);

      r.session.acquire();
      r.session.want(false);
      r.pump();
      expect(r.session.attached, isTrue, reason: 'an open screen outranks the repository');

      r.session.release();
      r.pump();
      expect(r.session.attached, isFalse);
      expect(r.keeper.linkOpen, isFalse);
    });

    _rigTest('a dropped link keeps showing the phase it had, until the host is asked again', (r) {
      r.connect();
      r.keeper.askPermission();
      r.pump();
      expect(r.session.phase, AgentPhase.blockedOnPermission);

      r.machine.goOffline(); // so nobody can be asked
      r.keeper.dropLink();
      r.pump();
      expect(r.session.link, AgentLink.reconnecting);
      expect(r.session.state.pending, isEmpty, reason: 'nothing can be answered on a dead link');
      expect(r.session.phase, AgentPhase.blockedOnPermission);

      r.listed(); // the host says nothing waits any more
      expect(r.session.phase, AgentPhase.idle);
    });

    _rigTest('a session that was working keeps that until the host says otherwise, then follows it', (r) {
      r.keeper.turn = Completer<String>();
      r.session.acquire();
      r.pump();
      unawaited(r.session.send('long job'));
      r.pump();
      expect(r.session.phase, AgentPhase.working);

      r.session.release();
      r.pump();
      expect(r.session.attached, isFalse);
      expect(r.session.phase, AgentPhase.working, reason: 'not idle just because the channel went');

      r.keeper.finishTurn();
      r.listed(unseenDone: true); // the listing after the turn ended
      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.unseenDone, isTrue);
    });
  });

  group('retries', () {
    _rigTest('an offline machine is not asked: the session waits for it, without a timer, then tries once', (r) {
      r.connect();
      r.machine.goOffline();
      r.keeper.dropLink();
      r.pump();
      expect(r.session.link, AgentLink.reconnecting);
      final lists = r.host.listCalls;
      final attaches = r.host.attachCalls;
      final timers = _timers(r.async);

      r.async.elapse(const Duration(hours: 3));
      expect(r.host.listCalls, lists, reason: 'no questions to a machine that is not there');
      expect(r.host.attachCalls, attaches);
      expect(_timers(r.async), timers, reason: 'waiting for the machine costs no timer');

      r.machine.reconnect();
      r.async.flushMicrotasks();
      expect(r.machine.isLive, isTrue);
      r.async.elapse(const Duration(seconds: 5));
      expect(r.session.link, AgentLink.live);
      expect(r.host.attachCalls, attaches + 1, reason: 'one try when the machine is back');
    });

    _rigTest('the delays are spread by the jitter, so sessions that lost the link together do not knock together', (r) {
      r.connect();
      r.jitterFactor = 0.8;
      r.host.attachFailures.add(const AgentHostException('down'));
      r.keeper.dropLink();
      r.async.flushMicrotasks(); // the first retry is now scheduled at 1 s x 0.8
      r.jitterFactor = 1.2; // the second one at 2 s x 1.2
      expect(r.host.attachCalls, 1);

      r.async.elapse(const Duration(milliseconds: 799));
      expect(r.host.attachCalls, 1);
      r.async.elapse(const Duration(milliseconds: 1));
      expect(r.host.attachCalls, 2, reason: '0.8 s');

      r.async.elapse(const Duration(milliseconds: 2399));
      expect(r.host.attachCalls, 2);
      r.async.elapse(const Duration(milliseconds: 1));
      expect(r.host.attachCalls, 3, reason: '2.4 s later');
      expect(r.session.link, AgentLink.live);
    });

    _rigTest('gives up after the allowed attempts, says so, and Retry tries again', (r) {
      r.connect();
      r.host.attachFailures.addAll([for (var i = 0; i < 20; i++) const AgentHostException('ssh: timed out')]);
      r.keeper.dropLink();
      r.async.elapse(const Duration(minutes: 5));

      expect(r.session.link, AgentLink.failed);
      expect(r.session.error, contains('after 3 tries'));
      expect(r.session.evicted, isFalse);
      expect(r.host.attachCalls, 4, reason: 'the attach that worked, then three retries');
      r.async.elapse(const Duration(hours: 5));
      expect(r.host.attachCalls, 4, reason: 'it stays quiet');
      expect(_timers(r.async), r.machineTimers);

      r.host.attachFailures.clear();
      unawaited(r.session.reattach());
      r.pump();
      expect(r.session.link, AgentLink.live);
      expect(r.session.attached, isTrue);
    }, maxAttempts: 3);

    _rigTest('a session nobody wants any more stops retrying', (r) {
      r.connect();
      r.host.attachFailures.addAll([for (var i = 0; i < 20; i++) const AgentHostException('down')]);
      r.keeper.dropLink();
      r.async.elapse(const Duration(seconds: 10));
      final attaches = r.host.attachCalls;
      expect(attaches, greaterThan(1));

      r.session.want(false);
      r.async.elapse(const Duration(hours: 1));
      expect(r.host.attachCalls, attaches);
      expect(r.session.link, AgentLink.live, reason: 'unattached by choice, not broken');
      expect(_timers(r.async), r.machineTimers);
    });
  });

  group('updates', () {
    _rigTest('a burst of updates notifies once, after the frame', (r) {
      r.connect();
      final before = r.notifications;

      for (var i = 0; i < 50; i++) {
        r.keeper.say('chunk $i ', messageId: 'a9');
      }
      r.async.elapse(const Duration(milliseconds: 10));
      expect(r.notifications, before, reason: 'not per chunk');
      r.async.elapse(const Duration(milliseconds: 10));
      expect(r.notifications, before + 1);
      final text = (r.session.state.items.last as TranscriptMessage).text;
      expect(text, startsWith('chunk 0 chunk 1 '));
      expect(text, endsWith('chunk 49 '));

      r.keeper.say('more', messageId: 'a9');
      r.pump();
      expect(r.notifications, before + 2);
    });

    _rigTest('phaseSince moves with the phase and only then', (r) {
      r.connect();
      final started = r.session.phaseSince;
      expect(started, _t0);

      r.async.elapse(const Duration(minutes: 5));
      r.keeper.say('streaming', messageId: 'a1');
      r.pump();
      expect(r.session.phaseSince, started, reason: 'streaming text is not a phase change');

      r.keeper.askPermission();
      r.async.flushMicrotasks();
      expect(r.session.phase, AgentPhase.blockedOnPermission);
      expect(r.session.phaseSince, r.now);
      expect(r.session.phaseSince.difference(_t0), greaterThanOrEqualTo(const Duration(minutes: 5)));
    });
  });

  group('omp subagent transcripts', () {
    const sid = '01a10ae2-9247-7303-bcff-280a4fc94489';
    const project = '/home/u/.omp/agent/sessions/-proj';
    const logPath = '$project/2026-10-05T07-06-23-175Z_$sid/PongReply.jsonl';
    // The recorded `task` call of a real omp 18.4.12 ACP session: the call,
    // a running progress update, the final one.
    final calls = (jsonDecode(File('test/fixtures/omp_logs/acp_task_updates.json').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    final log = File('test/fixtures/omp_logs/subagent_artifact_acp.jsonl').readAsStringSync();

    FakeFs host() => FakeFs(home: '/home/u')
      ..addFile('$project/2026-10-05T07-06-23-175Z_$sid.jsonl', '{}\n')
      ..addFile(logPath, log);

    String runId(_Rig r) => r.session.subagentRuns.single.id;

    _rigTest('the drill-in reads the log; the transcript survives what the client publishes next', (r) {
      r.connect();
      r.keeper.update(calls[0]);
      r.keeper.update(calls[1]);
      r.pump();
      final id = runId(r);
      expect(r.session.subagentRun(id)!.hasTranscript, isFalse, reason: 'ACP sends a summary only');
      expect(r.session.subagentLogStatus(id), SubagentLogStatus.idle);
      final timers = _timers(r.async);

      r.session.watchSubagentLog(id, true);
      r.pump();
      final run = r.session.subagentRun(id)!;
      expect(r.session.subagentLogStatus(id), SubagentLogStatus.shown);
      expect(run.hasTranscript, isTrue);
      expect(run.log, isNotNull);
      expect(r.session.subagentRuns.single.hasTranscript, isTrue);
      expect(r.session.subagentsOfToolCall(run.parentToolCallId).single.hasTranscript, isTrue);
      expect(_timers(r.async), timers + 1, reason: 'one timer while the screen is open');

      r.keeper.update(calls[2]);
      r.pump();
      expect(r.session.subagentRun(id)!.status, SubagentStatus.finished);
      expect(r.session.subagentRun(id)!.hasTranscript, isTrue, reason: 'the client\'s next state did not drop it');

      r.session.watchSubagentLog(id, false);
      expect(_timers(r.async), timers);
    }, seed: (h) => h.add(sessionId: sid), fs: host());

    final untouched = host();
    _rigTest('a session nobody looked at reads nothing', (r) {
      r.connect();
      r.keeper.update(calls[1]);
      r.pump();
      r.async.elapse(const Duration(minutes: 2));
      expect(untouched.calls, isEmpty);
      expect(r.session.subagentLogStatus(runId(r)), SubagentLogStatus.idle);
      expect(r.session.subagentRun(runId(r))!.hasTranscript, isFalse);
    }, seed: (h) => h.add(sessionId: sid), fs: untouched);

    final watched = host();
    _rigTest('an open screen reads nothing while the app is in the background', (r) {
      r.connect();
      r.keeper.update(calls[1]);
      r.pump();
      final id = runId(r);
      r.session.watchSubagentLog(id, true);
      r.pump();
      r.session.onLifecycleState(AppLifecycleState.paused);
      watched.calls.clear();
      r.async.elapse(const Duration(seconds: 30));
      expect(watched.calls, isEmpty);

      r.session.onLifecycleState(AppLifecycleState.resumed);
      r.async.elapse(const Duration(seconds: 4));
      expect(watched.calls, isNotEmpty, reason: 'back in front: the running subagent is read again');
      r.session.watchSubagentLog(id, false);
    }, seed: (h) => h.add(sessionId: sid), fs: watched);

    _rigTest('a host without SFTP leaves the summary and says nothing', (r) {
      r.connect();
      r.keeper.update(calls[1]);
      r.pump();
      r.session.watchSubagentLog(runId(r), true);
      r.pump();
      expect(r.session.subagentLogStatus(runId(r)), SubagentLogStatus.unavailable);
      expect(r.session.subagentRun(runId(r))!.hasTranscript, isFalse);
      r.session.watchSubagentLog(runId(r), false);
    }, seed: (h) => h.add(sessionId: sid));

    _rigTest('a screen that closes after the session was disposed does nothing', (r) {
      r.connect();
      r.keeper.update(calls[1]);
      r.pump();
      final id = runId(r);
      r.session.watchSubagentLog(id, true);
      r.session.dispose();
      r.session.watchSubagentLog(id, false);
      r.session.watchSubagentLog(id, true);
      expect(_timers(r.async), r.machineTimers);
    }, seed: (h) => h.add(sessionId: sid), fs: host());
  });

  group('prompts', () {
    _rigTest('send adds the message, runs the turn and ends idle', (r) {
      r.connect();
      final sent = _Outcome(r.session.send('hello there'));
      r.pump();

      expect(sent.done, isTrue);
      expect(sent.error, isNull);
      expect(r.keeper.prompts, ['hello there']);
      final text = [for (final m in r.session.state.items.whereType<TranscriptMessage>()) m.text];
      expect(text, ['hello there', 'ok: hello there']);
      expect(r.session.phase, AgentPhase.idle);
    });

    const silent = 'The agent ended the turn without an answer. '
        'If this keeps happening, its login on the host may have expired.';

    _rigTest('a turn that ends with end_turn and not a word says the login may have expired', (r) {
      r.connect();
      r.keeper.onPrompt = (_) => {'stopReason': 'end_turn'};
      unawaited(r.session.send('hello'));
      r.pump();

      expect(r.session.error, silent);
      expect(r.session.link, AgentLink.live);
      expect(r.session.phase, AgentPhase.idle);
    });

    _rigTest('an answer, a tool call or a plan is not silence', (r) {
      r.connect();
      unawaited(r.session.send('hello'));
      r.pump();
      expect(r.session.error, isNull, reason: 'the default agent answers');

      r.keeper.onPrompt = (_) {
        r.keeper.update({'sessionUpdate': 'tool_call', 'toolCallId': 't1', 'title': 'ls', 'kind': 'execute', 'status': 'completed'});
        return {'stopReason': 'end_turn'};
      };
      unawaited(r.session.send('list files'));
      r.pump();
      expect(r.session.error, isNull, reason: 'a tool-only turn did something');

      r.keeper.onPrompt = (_) {
        r.keeper.update({
          'sessionUpdate': 'plan',
          'entries': [
            {'content': 'step', 'priority': 'high', 'status': 'pending'},
          ],
        });
        return {'stopReason': 'end_turn'};
      };
      unawaited(r.session.send('plan it'));
      r.pump();
      expect(r.session.error, isNull, reason: 'a plan counts');
    });

    _rigTest('only a plain end_turn is suspect: cancelled, refusal and max_tokens turns are not', (r) {
      r.connect();
      for (final reason in ['cancelled', 'refusal', 'max_tokens']) {
        r.keeper.onPrompt = (_) => {'stopReason': reason};
        unawaited(r.session.send('go $reason'));
        r.pump();
        expect(r.session.error, isNull, reason: reason);
      }
    });

    _rigTest('the warning goes away with the next send', (r) {
      r.connect();
      r.keeper.onPrompt = (_) => {'stopReason': 'end_turn'};
      unawaited(r.session.send('one'));
      r.pump();
      expect(r.session.error, silent);

      r.keeper.onPrompt = null;
      unawaited(r.session.send('two'));
      r.pump();
      expect(r.session.error, isNull);
    });

    _rigTest('a failing prompt lands in error and never throws', (r) {
      r.connect();
      r.keeper.onPrompt = (_) => throw const JsonRpcException(-32000, 'model overloaded');
      final sent = _Outcome(r.session.send('hello'));
      r.pump();

      expect(sent.done, isTrue);
      expect(sent.error, isNull);
      expect(r.session.error, 'model overloaded');
      expect(r.session.link, AgentLink.live);
      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.unseenDone, isFalse, reason: 'a failure is not a result to review');
    });

    _rigTest('send without a link says so and sends nothing', (r) {
      final sent = _Outcome(r.session.send('hello'));
      r.pump();

      expect(sent.done, isTrue);
      expect(sent.error, isNull);
      expect(r.session.error, 'Not connected. The message was not sent.');
      expect(r.keeper.prompts, isEmpty);
    });

    _rigTest('setMode goes to the agent and shows in the state', (r) {
      r.connect();
      unawaited(r.session.setMode('plan'));
      r.pump();
      expect(r.keeper.modes, ['plan']);
      expect(r.session.state.currentModeId, 'plan');
      expect(r.session.error, isNull);
    });
  });

  group('review', () {
    _rigTest('a finished turn is unseen until markSeen, which is remembered', (r) {
      r.connect();
      unawaited(r.session.send('hello'));
      r.pump();
      expect(r.session.unseenDone, isTrue);

      r.session.markSeen();
      r.pump();
      expect(r.session.unseenDone, isFalse);
      expect(r.reviewed.length, 1);
      r.session.markSeen();
      expect(r.reviewed.length, 1, reason: 'idempotent');
    });

    _rigTest('unmarkSeen takes markSeen back, and the stored review with it', (r) {
      r.connect();
      unawaited(r.session.send('hello'));
      r.pump();
      expect(r.session.unmarkSeen(), isFalse, reason: 'nothing was seen yet');

      r.session.markSeen();
      r.pump();
      expect(r.session.unseenDone, isFalse);
      expect(r.reviewed.length, 1);

      expect(r.session.unmarkSeen(), isTrue);
      expect(r.session.unseenDone, isTrue);
      expect(r.reviewed.length, 0, reason: 'a restart must not remember a review that was undone');
      expect(r.session.unmarkSeen(), isFalse, reason: 'once');
    });

    _rigTest('unmarkSeen leaves a turn that finished after the review alone', (r) {
      r.connect();
      unawaited(r.session.send('hello'));
      r.pump();
      r.session.markSeen();
      r.pump();

      r.keeper.update(runningUpdate());
      r.pump();
      r.async.elapse(const Duration(seconds: 1));
      r.keeper.update(idleUpdate('end_turn'));
      r.pump();
      expect(r.session.unseenDone, isTrue, reason: 'the second turn is news');
      r.session.markSeen();

      r.keeper.update(runningUpdate());
      r.pump();
      expect(r.session.unmarkSeen(), isFalse, reason: 'it works again: nothing to restore');
      expect(r.session.unseenDone, isFalse);
    });

    _rigTest('unmarkSeen restores a listed turn only while it is the listed one', (r) {
      final first = _t0.add(const Duration(minutes: 1));
      r.listed(unseenDone: true, lastEventAt: first);
      r.session.markSeen();
      expect(r.session.unseenDone, isFalse);

      r.listed(unseenDone: true, lastEventAt: _t0.add(const Duration(minutes: 9)));
      expect(r.session.unseenDone, isTrue, reason: 'a later turn');
      expect(r.session.unmarkSeen(), isFalse, reason: 'the undone review was of the earlier turn');

      r.session.markSeen();
      expect(r.session.unseenDone, isFalse);
      expect(r.session.unmarkSeen(), isTrue);
      expect(r.session.unseenDone, isTrue);
      expect(r.reviewed.length, 0);
    });

    _rigTest('a turn that ended while the screen was open is flagged again', (r) {
      r.connect();
      r.keeper.update(runningUpdate());
      r.pump();
      expect(r.session.phase, AgentPhase.working);
      expect(r.session.unseenDone, isFalse, reason: 'not done while it works');

      r.keeper.update(idleUpdate('end_turn'));
      r.pump();
      expect(r.session.unseenDone, isTrue);
    });

    _rigTest('history replayed on attach is not news', (r) {
      r.connect();
      expect(r.session.state.lastStopReason, StopReason.endTurn);
      expect(r.session.unseenDone, isFalse);
    }, seed: (h) => h.add(sessionId: 's1')..log.addAll([runningUpdate(), agentChunk('hi'), idleUpdate('end_turn')]));

    _rigTest('a turn still running at re-attach and finished later is flagged', (r) {
      r.connect();
      r.keeper.dropLink();
      r.async.flushMicrotasks();
      // The keeper reports the turn that ended meanwhile right after the load.
      r.keeper.log.add(runningUpdate());
      r.async.elapse(const Duration(seconds: 2));
      r.keeper.update(idleUpdate('end_turn'));
      r.pump();

      expect(r.session.unseenDone, isTrue);
    }, seed: (h) => h.add(sessionId: 's1')..log.add(agentChunk('hi')));
  });

  group('end', () {
    _rigTest('a host that cannot kill the keeper throws and leaves the session alone', (r) {
      r.connect();
      r.host.killFailure = const AgentHostException('permission denied');
      final ended = _Outcome(r.session.end());
      r.pump();

      expect(ended.error, isA<AgentHostException>());
      expect((ended.error! as AgentHostException).message, 'permission denied');
      expect(r.session.link, AgentLink.live);
    });

    _rigTest('update() with an exited keeper ends the session with its reason', (r) {
      r.connect();
      final exited = r.keeper.info;
      r.session.update(KeeperInfo(
        id: exited.id,
        agent: exited.agent,
        cwd: exited.cwd,
        state: KeeperState.exited,
        startedAt: exited.startedAt,
        exitCode: 137,
      ));
      r.pump();

      expect(r.session.link, AgentLink.ended);
      expect(r.session.error, 'omp exited with code 137.');
    });
  });

  group('sending while the agent works', () {
    /// A turn runs on the agent: [first] was sent and its answer waits.
    void working(_Rig r, {String first = 'first'}) {
      // The attach settles for a second before queued messages are sent.
      r.pump(1100);
      r.keeper.turn = Completer<String>();
      unawaited(r.session.send(first));
      r.pump();
      expect(r.session.state.turnActive, isTrue);
    }

    List<String> queuedText(_Rig r) => [for (final q in r.session.queued) q.text];

    // -- a route that cannot steer: omp and pi --------------------------------

    _rigTest('omp: a message sent mid-turn waits, is visible as queued, and goes out when the turn ends, and not before', (r) {
      r.connect();
      expect(r.session.delivery, SendDelivery.now);
      working(r);
      expect(r.session.canSteer, isFalse, reason: 'omp has no steering');
      expect(r.session.delivery, SendDelivery.queued);

      final sent = _Outcome(r.session.send('also, run the tests'));
      r.pump();

      expect(sent.done, isTrue, reason: 'queueing is immediate');
      expect(r.session.queued, hasLength(1));
      expect(r.session.queued.single.text, 'also, run the tests');
      expect(r.session.queued.single.state, QueuedState.waiting);
      expect(r.keeper.prompts, ['first'], reason: 'a prompt during a turn would cancel it in omp: never sent');
      expect(r.keeper.steers, isEmpty);
      expect(r.session.state.items.whereType<TranscriptMessage>().where((m) => m.text == 'also, run the tests'), isEmpty,
          reason: 'not in the transcript until it is sent');

      r.keeper.finishTurn();
      r.pump();

      expect(r.keeper.prompts, ['first', 'also, run the tests']);
      expect(r.session.queued, isEmpty);
      expect(r.session.phase, AgentPhase.idle);
      expect(r.keeper.maxPromptsInFlight, 1);
    });

    _rigTest('several queued messages go out one at a time, in order, after edits and removals', (r) {
      r.connect();
      working(r);
      for (final t in ['a', 'b', 'c', 'd']) {
        unawaited(r.session.send(t));
      }
      r.pump();
      expect(queuedText(r), ['a', 'b', 'c', 'd']);
      expect(r.session.delivery, SendDelivery.queued);

      r.session.removeQueued(r.session.queued[0].id);
      r.session.editQueued(r.session.queued[1].id, 'c, but shorter');
      r.session.removeQueued('no-such-id');
      expect(queuedText(r), ['b', 'c, but shorter', 'd']);

      r.keeper.finishTurn();
      r.pump();

      expect(r.keeper.prompts, ['first', 'b', 'c, but shorter', 'd']);
      expect(r.keeper.maxPromptsInFlight, 1, reason: 'never two prompts at once');
      expect(r.session.queued, isEmpty);
    });

    _rigTest('a queue change notifies, and the list is new each time', (r) {
      r.connect();
      working(r);
      final before = r.session.queued;
      final n = r.notifications;
      unawaited(r.session.send('later'));
      r.pump();
      expect(r.notifications, greaterThan(n));
      expect(identical(before, r.session.queued), isFalse);
      final one = r.session.queued;
      r.session.editQueued(one.single.id, 'later!');
      r.pump();
      expect(identical(one, r.session.queued), isFalse);
    });

    _rigTest('Stop keeps what waits, held; the person resumes it, or removes it', (r) {
      r.connect();
      working(r);
      unawaited(r.session.send('one'));
      unawaited(r.session.send('two'));
      r.pump();

      r.session.cancel();
      r.pump();
      expect(r.session.queued.map((q) => q.state), [QueuedState.held, QueuedState.held],
          reason: 'held at once, before the turn has even ended');
      expect(r.session.queued.first.heldReason, contains('stopped'));

      r.keeper.finishTurn('cancelled');
      r.pump();
      expect(r.keeper.prompts, ['first'], reason: 'nothing goes out by itself after a Stop');
      expect(queuedText(r), ['one', 'two']);
      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.delivery, SendDelivery.now, reason: 'held messages do not make a new one wait behind them');

      r.session.removeQueued(r.session.queued.first.id);
      r.session.resumeQueue();
      r.pump();
      expect(r.keeper.prompts, ['first', 'two']);
      expect(r.session.queued, isEmpty);
    });

    _rigTest('a turn that fails holds the queue as well', (r) {
      r.connect();
      r.keeper.onPrompt = (_) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        throw const JsonRpcException(-32603, 'model overloaded');
      };
      unawaited(r.session.send('first'));
      r.pump();
      unawaited(r.session.send('second'));
      r.pump();
      expect(r.session.queued.single.state, QueuedState.waiting);

      r.pump(1100);

      expect(r.session.error, 'model overloaded');
      expect(r.session.queued.single.state, QueuedState.held);
      expect(r.session.queued.single.heldReason, contains('failed'));
      expect(r.keeper.prompts, ['first']);
    });

    _rigTest('a link drop keeps the queue and a message sent meanwhile; nothing goes out until the agent is idle again', (r) {
      r.connect();
      working(r);
      unawaited(r.session.send('second'));
      r.pump();

      r.keeper.dropLink();
      r.pump();
      expect(r.session.link, AgentLink.reconnecting);
      expect(queuedText(r), ['second'], reason: 'kept in memory across the drop');
      expect(r.session.delivery, SendDelivery.queued);

      unawaited(r.session.send('third'));
      r.pump();
      expect(queuedText(r), ['second', 'third'], reason: 'sent while the link is being made again: it waits for it');

      r.async.elapse(const Duration(seconds: 3));
      expect(r.session.link, AgentLink.live);
      expect(r.session.state.turnActive, isTrue, reason: 'the keeper says the turn still runs');
      expect(queuedText(r), ['second', 'third']);
      expect(r.keeper.prompts, ['first'], reason: 'the agent is still working: nothing was sent');

      r.keeper.finishTurn();
      r.keeper.update(idleUpdate('end_turn'));
      r.pump();

      expect(r.keeper.prompts, ['first', 'second', 'third']);
      expect(r.keeper.maxPromptsInFlight, 1);
      expect(r.session.queued, isEmpty);
    });

    _rigTest('a queue of the same session survives a reattach after it was dropped to save a channel', (r) {
      r.connect();
      working(r);
      unawaited(r.session.send('later'));
      r.pump();
      r.session.acquire();
      r.session.release();
      r.session.want(false);
      r.pump();

      expect(queuedText(r), ['later']);
    });

    _rigTest('with no link at all (never attached, not being attached) a send says so and queues nothing', (r) {
      unawaited(r.session.send('hello'));
      r.pump();
      expect(r.session.error, 'Not connected. The message was not sent.');
      expect(r.session.queued, isEmpty);
    });

    _rigTest('omp refuses a prompt as busy (-32003): the row is taken back and the text waits, held', (r) {
      r.connect();
      r.keeper.onPrompt = (_) => throw const JsonRpcException(-32003, 'Session is busy');
      final sent = _Outcome(r.session.send('hello'));
      r.pump();

      expect(sent.done, isTrue);
      expect(sent.error, isNull);
      expect(r.session.state.items.whereType<TranscriptMessage>(), isEmpty, reason: 'it was not delivered');
      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.queued.single.text, 'hello');
      expect(r.session.queued.single.held, isTrue);
      expect(r.session.queued.single.heldReason, contains('busy'));
      expect(r.session.link, AgentLink.live);

      r.keeper.onPrompt = null;
      r.pump(1100);
      r.session.resumeQueue();
      r.pump();
      expect(r.session.queued, isEmpty);
      expect(r.keeper.prompts, ['hello', 'hello']);
      expect(r.session.state.items.whereType<TranscriptMessage>().map((m) => m.text), ['hello', 'ok: hello']);
    });

    // -- a route that steers: Claude Code, Codex ------------------------------

    _rigTest('Claude Code: a message sent mid-turn goes into the turn (_session/steering), not into a queue', (r) {
      r.keeper.initialize = claudeInitialize;
      r.connect();
      expect(r.session.canSteer, isTrue);
      working(r);
      expect(r.session.delivery, SendDelivery.steered);

      final sent = _Outcome(r.session.send('use the other table'));
      r.pump();

      expect(sent.done, isTrue);
      expect(r.keeper.steers, hasLength(1));
      expect(r.keeper.steers.single['prompt'], [
        {'type': 'text', 'text': 'use the other table'},
      ]);
      expect(r.keeper.steers.single['_meta'], {
        'steering': {'idleBehavior': 'promptRequired'},
      });
      expect(r.keeper.prompts, ['first'], reason: 'one prompt, one turn');
      expect(r.session.queued, isEmpty);
      final rows = [for (final m in r.session.state.items.whereType<TranscriptMessage>()) m.text];
      expect(rows, contains('use the other table'), reason: 'the person sees what they said');
      expect(r.session.phase, AgentPhase.working);
      expect(r.session.error, isNull);
    });

    _rigTest('a steering route queues on request: "when you are done, also..."', (r) {
      r.keeper.initialize = claudeInitialize;
      r.connect();
      working(r);

      unawaited(r.session.sendBlocks([const TextBlock('then update the docs')], queue: true));
      r.pump();

      expect(r.keeper.steers, isEmpty);
      expect(queuedText(r), ['then update the docs']);
      r.keeper.finishTurn();
      r.pump();
      expect(r.keeper.prompts, ['first', 'then update the docs']);
    });

    _rigTest('steering answers promptRequired (the turn ended on the way): it goes out as a prompt, after the turn', (r) {
      r.keeper.initialize = claudeInitialize;
      r.connect();
      working(r);
      r.keeper.onSteer = (_) => {'outcome': 'promptRequired', 'reason': 'noRunningTurn'};

      unawaited(r.session.send('too late for the turn'));
      r.pump();
      expect(queuedText(r), ['too late for the turn']);
      expect(r.keeper.prompts, ['first'], reason: 'the first turn has not been answered yet: one prompt at a time');

      r.keeper.finishTurn();
      r.pump();
      expect(r.keeper.prompts, ['first', 'too late for the turn']);
      expect(r.session.queued, isEmpty);
      expect(r.keeper.maxPromptsInFlight, 1);
    });

    _rigTest('steering answers startedNewTurn (Codex): the message shows and nothing is queued', (r) {
      r.keeper.initialize = codexInitialize;
      r.connect();
      working(r);
      r.keeper.onSteer = (_) => {'outcome': 'startedNewTurn'};

      unawaited(r.session.send('one more'));
      r.pump();

      expect(r.session.queued, isEmpty);
      expect(r.keeper.steers.single.containsKey('_meta'), isFalse, reason: 'Codex has no idleBehavior');
      expect([for (final m in r.session.state.items.whereType<TranscriptMessage>()) m.text], contains('one more'));
    });

    _rigTest('steering answers failed (Codex): the message waits for the end of the turn', (r) {
      r.keeper.initialize = codexInitialize;
      r.connect();
      working(r);
      r.keeper.onSteer = (_) => {'outcome': 'failed'};

      unawaited(r.session.send('please'));
      r.pump();
      expect(queuedText(r), ['please']);
      expect(r.session.queued.single.state, QueuedState.waiting);

      r.keeper.finishTurn();
      r.pump();
      expect(r.keeper.prompts, ['first', 'please']);
    });

    _rigTest('a steering refusal keeps the text, held, with the reason (Codex on a model with no vision)', (r) {
      r.keeper.initialize = codexInitialize;
      r.connect();
      working(r);
      r.keeper.onSteer = (_) => throw const JsonRpcException(-32600, 'The current model does not support image input');

      final sent = _Outcome(r.session.sendBlocks([
        const TextBlock('what is this?'),
        const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg'),
      ]));
      r.pump();

      expect(sent.done, isTrue);
      expect(sent.error, isNull, reason: 'a refusal is a message, not a crash');
      expect(r.session.error, contains('does not support image input'));
      expect(r.session.error, contains('without the picture'));
      final held = r.session.queued.single;
      expect(held.held, isTrue);
      expect(held.text, 'what is this?');
      expect(held.attachments, hasLength(1));
      expect(r.session.link, AgentLink.live);

      r.session.editQueued(held.id, 'what is this? (no picture)');
      r.session.removeQueued(held.id);
      expect(r.session.queued, isEmpty);
    });

    // -- pictures and files ---------------------------------------------------

    _rigTest('a picture goes in the prompt when the agent advertised promptCapabilities.image', (r) {
      r.connect();
      expect(r.session.acceptsImages, isTrue);
      expect(r.session.acceptsEmbeddedContext, isTrue);

      unawaited(r.session.sendBlocks([
        const TextBlock('what is this?'),
        const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg'),
        const ResourceLinkBlock(uri: 'file:///work/a.dart', name: 'a.dart'),
      ]));
      r.pump();

      expect(r.keeper.promptBlocks.single, [
        {'type': 'text', 'text': 'what is this?'},
        {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/jpeg'},
        {'type': 'resource_link', 'uri': 'file:///work/a.dart', 'name': 'a.dart'},
      ]);
      expect(r.session.error, isNull);
    });

    _rigTest('an agent that takes no pictures: nothing is sent, the text is kept, and the error says why', (r) {
      r.keeper.initialize = () {
        final init = ompInitialize();
        (init['agentCapabilities'] as Map)['promptCapabilities'] = <String, Object?>{};
        return init;
      };
      r.connect();
      expect(r.session.acceptsImages, isFalse);
      expect(r.session.acceptsEmbeddedContext, isFalse);

      unawaited(r.session.sendBlocks([
        const TextBlock('what is this?'),
        const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg'),
      ]));
      r.pump();

      expect(r.session.error, 'the agent does not take images');
      expect(r.keeper.prompts, isEmpty);
      expect(r.session.queued.single.text, 'what is this?');
      expect(r.session.queued.single.held, isTrue);
      expect(r.session.phase, AgentPhase.idle);
    });

    _rigTest('Codex refusing a picture at a prompt (text-only model) is a plain error message', (r) {
      r.keeper.initialize = codexInitialize;
      r.keeper.onPrompt = (_) => throw const JsonRpcException(-32600, 'The current model does not support image input');
      r.connect();

      final sent = _Outcome(r.session.sendBlocks([
        const TextBlock('what is this?'),
        const ImageBlock(data: 'AAAA', mimeType: 'image/jpeg'),
      ]));
      r.pump();

      expect(sent.done, isTrue);
      expect(sent.error, isNull);
      expect(r.session.error, startsWith('The current model does not support image input'));
      expect(r.session.error, contains('another model'));
      expect(r.session.link, AgentLink.live);
      expect(r.session.phase, AgentPhase.idle);
    });
  });

  group('sign in on the host', () {
    const piMethods = [
      {
        'id': 'pi_terminal_login',
        'name': 'Launch pi in the terminal',
        'type': 'terminal',
        'args': ['--terminal-login'],
        '_meta': {
          'terminal-auth': {
            'command': 'pi-acp',
            'args': ['--terminal-login'],
            'label': 'Launch pi',
          },
        },
      },
    ];

    _rigTest('an auth_required turn says to sign in on the host, with the methods; the next send clears it', (r) {
      r.connect();
      expect(r.session.authNeeded, isNull);
      r.keeper.onPrompt = (_) => throw const JsonRpcException(-32000, 'Authentication required', {'authMethods': piMethods});
      final sent = _Outcome(r.session.send('hello'));
      r.pump();

      expect(sent.error, isNull);
      final need = r.session.authNeeded!;
      expect(need.message, contains('sign in on the host'));
      expect(need.terminalHint, isTrue);
      expect(need.methods.single.terminalLabel, 'Launch pi');
      expect(r.session.error, need.message);
      expect(r.session.link, AgentLink.live, reason: 'the link is fine, the login is not');

      r.keeper.onPrompt = null;
      unawaited(r.session.send('again'));
      r.pump();
      expect(r.session.authNeeded, isNull);
      expect(r.session.error, isNull);
    });

    _rigTest('without methods in the error, the ones advertised at initialize are shown', (r) {
      r.keeper.initialize = codexInitialize;
      r.connect();
      r.keeper.onPrompt = (_) => throw const JsonRpcException(-32000, 'Authentication required');
      unawaited(r.session.send('hello'));
      r.pump();

      expect(r.session.authNeeded!.methods.map((m) => m.id), ['api-key', 'chat-gpt']);
      expect(r.session.authNeeded!.terminalHint, isFalse);
    });

    _rigTest('another -32000 is not an auth failure', (r) {
      r.connect();
      r.keeper.onPrompt = (_) => throw const JsonRpcException(-32000, 'The client went away before it answered.');
      unawaited(r.session.send('hello'));
      r.pump();

      expect(r.session.authNeeded, isNull);
      expect(r.session.error, 'The client went away before it answered.');
    });

    _rigTest('session/new refusing for lack of a login: the link failed, a login is needed, and Retry works after it', (r) {
      r.keeper.newFailure = const JsonRpcException(-32000, 'Authentication required');
      r.connect();

      expect(r.session.link, AgentLink.failed);
      expect(r.session.authNeeded, isNotNull);
      expect(r.session.error, contains('sign in on the host'));

      r.keeper.newFailure = null;
      unawaited(r.session.reattach());
      r.pump();
      expect(r.session.link, AgentLink.live);
      expect(r.session.authNeeded, isNull, reason: 'a successful attach clears it');
    });
  });

  group('repository', () {
    test('lists the keepers of a connected machine and attaches the running ones', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')
          ..add(id: 'k1', title: 'Fix login')
          ..add(id: 'k2', agent: 'claude')
          ..add(id: 'k3', state: KeeperState.exited, exitCode: 0);
        h.addMachine('a', 'alpha');

        expect(h.repo.sessions, hasLength(3));
        expect(host.attachCalls, 2, reason: 'the exited keeper is not attached');
        expect(h.repo.byKey('a/k1')!.link, AgentLink.live);
        expect(h.repo.byKey('a/k1')!.title, 'Fix login');
        expect(h.repo.byKey('a/k2')!.agentLabel, 'Claude Code');
        expect(h.repo.byKey('a/k3')!.link, AgentLink.ended);
        expect(h.repo.byKey('a/nope'), isNull);
        expect(host.openLinks, 2, reason: 'the exited keeper holds no channel');
        h.dispose();
      });
    });

    test('most urgent first: blocked, done and unseen, working, idle, ended; from the listing; counts follow', () {
      fakeAsync((async) {
        // Only the blocked one holds a channel: the rest is the listing's word.
        final h = _Fleet(async, recentAttached: 0);
        final host = h.host('a');
        host.add(id: 'idle');
        host.add(id: 'working').busy = true;
        host.add(id: 'blocked').askPermission();
        host.add(id: 'done').unseenDone = true;
        host.add(id: 'ended', state: KeeperState.exited, exitCode: 0);
        h.addMachine('a', 'alpha');

        expect([for (final s in h.repo.sessions) s.key], [
          'a/blocked',
          'a/done',
          'a/working',
          'a/idle',
          'a/ended',
        ]);
        expect(h.repo.blockedCount, 1);
        expect(h.repo.reviewCount, 1);
        expect(host.openLinks, 1);
        expect(h.repo.byKey('a/working')!.phase, AgentPhase.working);

        h.repo.byKey('a/done')!.markSeen();
        async.elapse(const Duration(seconds: 1));
        expect(h.repo.reviewCount, 0);
        expect([for (final s in h.repo.sessions) s.key], ['a/blocked', 'a/working', 'a/done', 'a/idle', 'a/ended']);
        h.dispose();
      });
    });

    test('inside a rank the one that changed last comes first', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        final first = host.add(id: 'first');
        final second = host.add(id: 'second');
        h.addMachine('a', 'alpha');

        first.askPermission();
        async.elapse(const Duration(minutes: 1));
        second.askPermission();
        async.elapse(const Duration(seconds: 1));

        expect([for (final s in h.repo.sessions) s.key], ['a/second', 'a/first']);
        h.dispose();
      });
    });

    test('listeners hear of what the board shows, not of streaming text', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final keeper = h.host('a').add(id: 'k1', sessionId: 's1');
        h.addMachine('a', 'alpha');
        var heard = 0;
        h.repo.addListener(() => heard++);

        for (var i = 0; i < 30; i++) {
          keeper.say('line $i ', messageId: 'a1');
          async.elapse(const Duration(milliseconds: 40));
        }
        expect(heard, 0, reason: 'text is the session screen\'s business');

        final request = keeper.askPermission();
        async.elapse(const Duration(milliseconds: 40));
        expect(heard, 1);

        final session = h.repo.byKey('a/k1')!;
        session.answerPermission(session.state.pending.single.id, const PermissionSelected('allow'));
        async.elapse(const Duration(milliseconds: 40));
        expect(request.answered, isTrue);
        expect(heard, 2);
        h.dispose();
      });
    });

    test('refresh finds new keepers and drops the ones the host forgot', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')
          ..add(id: 'old', state: KeeperState.exited, exitCode: 0)
          ..add(id: 'live');
        h.addMachine('a', 'alpha');
        expect(h.repo.sessions, hasLength(2));

        host.add(id: 'new');
        host.keepers.remove('old');
        unawaited(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));

        expect({for (final s in h.repo.sessions) s.key}, {'a/live', 'a/new'});
        h.dispose();
      });
    });

    test('a listing that fails changes nothing and does not throw', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')..add(id: 'k1');
        h.addMachine('a', 'alpha');

        host.listFailure = const AgentHostException('ssh down');
        final refreshed = _Outcome(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));

        expect(refreshed.done, isTrue);
        expect(refreshed.error, isNull);
        expect(h.repo.sessions, hasLength(1));
        h.dispose();
      });
    });

    test('lists every refreshEvery while the Agents tab is visible, never otherwise, never in the background', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')..add(id: 'k1');
        h.addMachine('a', 'alpha');
        final every = h.repo.refreshEvery; // the constructor's default, which boot.dart uses
        const second = Duration(seconds: 1);
        expect(every, const Duration(seconds: 30), reason: 'the board polls every 30 s while visible');
        final base = host.listCalls;

        async.elapse(every * 10);
        expect(host.listCalls, base, reason: 'no board, no timer');

        h.repo.setBoardVisible(true);
        async.elapse(every - second);
        expect(host.listCalls, base);
        async.elapse(second);
        expect(host.listCalls, base + 1);
        async.elapse(every * 2);
        expect(host.listCalls, base + 3);

        h.repo.setBoardVisible(false);
        async.elapse(every * 10);
        expect(host.listCalls, base + 3);

        h.repo.setBoardVisible(true);
        h.repo.onLifecycleState(AppLifecycleState.paused);
        final attaches = host.attachCalls;
        async.elapse(const Duration(minutes: 10));
        expect(host.listCalls, base + 3, reason: 'the background lists nothing');
        expect(host.attachCalls, attaches);
        expect(h.repo.byKey('a/k1')!.link, AgentLink.reconnecting, reason: 'detached after 90 s');

        h.repo.onLifecycleState(AppLifecycleState.resumed);
        async.elapse(second);
        expect(host.listCalls, base + 4, reason: 'listed on resume');
        expect(host.attachCalls, attaches + 1, reason: 'and attached again');
        expect(h.repo.byKey('a/k1')!.link, AgentLink.live);
        async.elapse(every);
        expect(host.listCalls, base + 5, reason: 'the timer is back');
        h.dispose();
      });
    });

    test('a machine that goes away takes its sessions and their reviews with it', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        h.host('a').add(id: 'k1');
        h.host('b').add(id: 'k2');
        h.addMachine('a', 'alpha');
        h.addMachine('b', 'beta');
        expect(h.repo.sessions, hasLength(2));
        unawaited(h.repo.byKey('a/k1')!.send('hi'));
        async.elapse(const Duration(seconds: 1));
        h.repo.byKey('a/k1')!.markSeen();
        expect(h.repo.reviewed.length, 1);

        unawaited(h.machines.remove('a'));
        async.elapse(const Duration(seconds: 1));

        expect([for (final s in h.repo.sessions) s.key], ['b/k2']);
        expect(h.repo.reviewed.length, 0);
        h.dispose();
      });
    });

    test('0 sessions and 30 sessions', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        h.addMachine('a', 'alpha');
        expect(h.repo.sessions, isEmpty);
        expect(h.repo.blockedCount + h.repo.reviewCount, 0);

        for (var i = 0; i < 30; i++) {
          host.add(id: 'k${i.toString().padLeft(2, '0')}', title: 'Nhiệm vụ số $i ${'rất dài ' * 20}');
        }
        unawaited(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));

        expect(h.repo.sessions, hasLength(30));
        final keys = [for (final s in h.repo.sessions) s.key];
        expect(keys.toSet(), hasLength(30));
        expect(host.openLinks, 3, reason: 'thirty sessions, three channels');
        expect(host.peakOpenLinks, lessThanOrEqualTo(4));
        h.dispose();
      });
    });
  });

  group('which sessions hold a channel', () {
    test('twelve running keepers hold three channels, the most recently active, and do not churn', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h);
        h.addMachine('a', 'alpha');

        expect(h.repo.sessions, hasLength(12));
        expect(_open(host), {'k11', 'k10', 'k09'});
        expect(host.attachCalls, 3);
        for (var i = 0; i < 5; i++) {
          unawaited(h.repo.refresh());
          async.elapse(const Duration(seconds: 31));
        }
        expect(host.attachCalls, 3, reason: 'listing again changes nothing');
        expect(host.peakOpenLinks, lessThanOrEqualTo(4));
        expect(_attached(h, 'a/k00'), isFalse);
        expect(h.repo.byKey('a/k00')!.link, AgentLink.live, reason: 'healthy, just not watched');
        h.dispose();
      });
    });

    test('a blocked keeper gets a channel before the recent ones, however old', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h, each: (i, k) {
          if (i == 2) k.askPermission();
        });
        h.addMachine('a', 'alpha');

        expect(_open(host), {'k02', 'k11', 'k10', 'k09'}, reason: 'one waiting + three recent = the cap');
        final s = h.repo.byKey('a/k02')!;
        expect(s.phase, AgentPhase.blockedOnPermission);
        expect(s.state.pending, hasLength(1), reason: 'attached, so the request itself is known');
        expect(h.repo.blockedCount, 1);
        expect(host.peakOpenLinks, lessThanOrEqualTo(4));
        h.dispose();
      });
    });

    test('a keeper that becomes blocked is attached at the next listing, within the cap', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h);
        h.addMachine('a', 'alpha');
        expect(h.repo.blockedCount, 0);

        host.keepers['k03']!.askPermission();
        unawaited(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));

        expect(_open(host), {'k03', 'k11', 'k10', 'k09'});
        expect(h.repo.blockedCount, 1);
        expect(h.repo.byKey('a/k03')!.state.pending, hasLength(1));
        expect(host.peakOpenLinks, lessThanOrEqualTo(4));
        h.dispose();
      });
    });

    test('more waiting than the cap: four hold channels, the longest waiting first; all still count; answering frees one', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h, each: (i, k) {
          if (i < 6) k.askPermission();
        });
        h.addMachine('a', 'alpha');

        expect(_open(host), {'k00', 'k01', 'k02', 'k03'});
        expect(h.repo.blockedCount, 6, reason: 'the two without a channel are blocked by the listing');
        expect(h.repo.byKey('a/k05')!.phase, AgentPhase.blockedOnPermission);
        expect(host.peakOpenLinks, lessThanOrEqualTo(4));

        final first = h.repo.byKey('a/k00')!;
        first.answerPermission(first.state.pending.single.id, const PermissionSelected('allow'));
        async.elapse(const Duration(seconds: 3)); // the settle window of the attach ends

        expect(_open(host), {'k01', 'k02', 'k03', 'k04'}, reason: 'the next one waiting takes the channel');
        expect(h.repo.blockedCount, 5);
        expect(host.peakOpenLinks, lessThanOrEqualTo(4));
        h.dispose();
      });
    });

    test('opening a session attaches it; the open one wins over the cap; closing lets go', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h);
        h.addMachine('a', 'alpha');
        final screens = [for (final k in ['k00', 'k01', 'k02', 'k03', 'k04']) h.repo.byKey('a/$k')!];

        screens[0].acquire();
        expect(screens[0].link, AgentLink.connecting);
        async.elapse(const Duration(seconds: 1));
        expect(screens[0].link, AgentLink.live);
        expect(_open(host), {'k00', 'k11', 'k10', 'k09'});

        for (final s in screens.sublist(1, 4)) {
          s.acquire();
          async.elapse(const Duration(seconds: 1));
        }
        expect(_open(host), {'k00', 'k01', 'k02', 'k03'}, reason: 'four screens fill the cap, the recent ones make room');
        expect(host.peakOpenLinks, lessThanOrEqualTo(4), reason: 'room is made before the next one attaches');

        screens[4].acquire();
        async.elapse(const Duration(seconds: 1));
        expect(_open(host), {'k00', 'k01', 'k02', 'k03', 'k04'}, reason: 'an open screen keeps its channel, cap or not');

        for (final s in screens) {
          s.release();
        }
        async.elapse(const Duration(seconds: 1));
        expect(_open(host), {'k11', 'k10', 'k09'}, reason: 'back to the recent ones');
        h.dispose();
      });
    });

    test('the rest show the listing: a turn in flight, a turn nobody saw end', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h, each: (i, k) {
          if (i == 0) k.busy = true;
          if (i == 1) k.unseenDone = true;
        });
        h.addMachine('a', 'alpha');

        final working = h.repo.byKey('a/k00')!;
        expect(_attached(h, 'a/k00'), isFalse);
        expect(working.phase, AgentPhase.working);
        final review = h.repo.byKey('a/k01')!;
        expect(review.phase, AgentPhase.idle);
        expect(review.unseenDone, isTrue);
        expect(h.repo.reviewCount, 1);

        // The turn ends; nobody is attached to see it.
        host.keepers['k00']!
          ..busy = false
          ..unseenDone = true;
        unawaited(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));
        expect(working.phase, AgentPhase.idle);
        expect(h.repo.reviewCount, 2);
        h.dispose();
      });
    });

    test('a session let go while it worked never shows that work as current once the listing says it ended', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = _twelve(h);
        h.addMachine('a', 'alpha');
        final s = h.repo.byKey('a/k00')!;
        final keeper = host.keepers['k00']!;
        keeper.turn = Completer<String>();

        s.acquire();
        async.elapse(const Duration(seconds: 1));
        unawaited(s.send('long job'));
        async.elapse(const Duration(seconds: 1));
        expect(s.phase, AgentPhase.working);

        s.release();
        async.elapse(const Duration(seconds: 1));
        expect(_attached(h, 'a/k00'), isFalse);
        expect(s.phase, AgentPhase.working, reason: 'what it was doing when it was let go');

        keeper.finishTurn(); // nobody attached: unseen
        unawaited(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));
        expect(s.phase, AgentPhase.idle);
        expect(s.unseenDone, isTrue);
        expect(h.repo.reviewCount, 1);
        h.dispose();
      });
    });
  });

  group('start racing a listing', () {
    test('a listing that finds the new keeper before start() returns does not make a second session', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        h.addMachine('a', 'alpha');
        host.startGate = Completer<void>();

        final started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'omp', cwd: '/work/app'));
        async.elapse(const Duration(seconds: 1));
        expect(started.done, isFalse);
        expect(host.keepers, hasLength(1));

        unawaited(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));
        expect(h.repo.sessions, hasLength(1));
        final found = h.repo.sessions.single;

        host.startGate!.complete();
        async.elapse(const Duration(seconds: 1));

        expect(started.error, isNull);
        expect(started.value, same(found), reason: 'the one session, not a second one');
        expect(h.repo.sessions, hasLength(1));
        expect(host.attachCalls, 1);
        expect(host.keepers.values.single.newCount, 1);
        async.elapse(const Duration(minutes: 10));
        expect(host.attachCalls, 1, reason: 'nobody evicts anybody');
        expect(found.evicted, isFalse);
        expect(found.link, AgentLink.live);
        expect((found as AcpAgentSession).attached, isTrue);
        h.dispose();
      });
    });

    test('a listing after start() returned finds the same session, not a new one', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        h.addMachine('a', 'alpha');

        final started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'omp', cwd: '/work/app'));
        async.elapse(const Duration(seconds: 1));
        unawaited(h.repo.refresh());
        async.elapse(const Duration(seconds: 1));

        expect(h.repo.sessions, hasLength(1));
        expect(started.value, same(h.repo.sessions.single));
        expect(host.attachCalls, 1);
        h.dispose();
      });
    });
  });

  group('start', () {
    test('starts a keeper, attaches, creates the session and lists it', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        h.addMachine('a', 'alpha');

        final started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'claude', cwd: '/work/app'));
        async.elapse(const Duration(seconds: 1));

        expect(started.error, isNull);
        final session = started.value! as AcpAgentSession;
        expect(session.link, AgentLink.live);
        expect(session.agent, 'claude');
        expect(session.cwd, '/work/app');
        expect(host.startCalls, 1);
        expect(host.keepers.values.single.newCount, 1);
        expect(h.repo.byKey(session.key), same(session));
        h.dispose();
      });
    });

    test('says which agent is missing, and starts nothing', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a')..installed = {'omp'};
        h.addMachine('a', 'studio-mac');

        final started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'claude', cwd: '/work'));
        async.elapse(const Duration(seconds: 1));

        final error = started.error! as AgentHostException;
        expect(error.message, 'Claude Code is not installed on studio-mac.');
        expect(error.fatal, isTrue);
        expect(host.startCalls, 0);
        expect(h.repo.sessions, isEmpty);
        h.dispose();
      });
    });

    test('an agent with no route is refused', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        h.host('a');
        h.addMachine('a', 'alpha');

        final started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'emacs', cwd: '/work'));
        async.elapse(const Duration(seconds: 1));

        expect(started.error, isA<AgentHostException>());
        h.dispose();
      });
    });

    test('a host that cannot be asked or cannot start the keeper says why', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        h.addMachine('a', 'alpha');

        host.availableFailure = const AgentHostException('python3 is missing on alpha.');
        var started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'omp', cwd: '/work'));
        async.elapse(const Duration(seconds: 1));
        expect((started.error! as AgentHostException).message, 'python3 is missing on alpha.');

        host.availableFailure = null;
        host.startFailure = const AgentHostException('/work does not exist on alpha.', fatal: true);
        started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'omp', cwd: '/work'));
        async.elapse(const Duration(seconds: 1));
        expect((started.error! as AgentHostException).message, '/work does not exist on alpha.');
        expect(h.repo.sessions, isEmpty);
        h.dispose();
      });
    });

    test('a keeper that cannot be attached is killed and the start fails', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        h.addMachine('a', 'alpha');
        host.attachFailures.add(const AgentHostException('login required: run `omp login` on alpha', fatal: true));

        final started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'omp', cwd: '/work'));
        async.elapse(const Duration(seconds: 1));

        final error = started.error! as AgentHostException;
        expect(error.message, 'login required: run `omp login` on alpha');
        expect(error.fatal, isTrue);
        expect(host.killed, hasLength(1), reason: 'no orphan keeper');
        expect(h.repo.sessions, isEmpty);
        async.elapse(const Duration(minutes: 5));
        expect(host.attachCalls, 1, reason: 'the abandoned session does not retry');
        h.dispose();
      });
    });

    test('a link that drops while starting is a failed start, not a half-open session', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        final host = h.host('a');
        h.addMachine('a', 'alpha');
        host.attachFailures.add(const AgentHostException('connection reset'));

        final started = _Outcome(h.repo.start(machine: h.conn('a'), agent: 'omp', cwd: '/work'));
        async.elapse(const Duration(seconds: 30));

        expect((started.error! as AgentHostException).message, 'connection reset');
        expect(h.repo.sessions, isEmpty);
        expect(host.attachCalls, 1);
        h.dispose();
      });
    });

    test('available asks the machine\'s host', () {
      fakeAsync((async) {
        final h = _Fleet(async);
        h.host('a').installed = {'omp', 'pi'};
        h.addMachine('a', 'alpha');

        final asked = _Outcome(h.repo.available(h.conn('a')));
        async.elapse(const Duration(seconds: 1));

        expect(asked.value, {'omp', 'pi'});
        h.dispose();
      });
    });
  });
}

// -- a fleet of fake machines, each with a scripted host ----------------------

class _Fleet {
  _Fleet(this.async, {int recentAttached = 3}) {
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
    );
  }

  final FakeAsync async;
  late final MachineRepository machines;
  late final FleetRepository fleet;
  late final AgentSessionRepository repo;
  final _hosts = <String, FakeAgentHost>{};

  FakeAgentHost host(String machineId) =>
      _hosts.putIfAbsent(machineId, () => FakeAgentHost(clock: () => _t0.add(async.elapsed)));

  MachineConnection conn(String id) => fleet.connection(id)!;

  /// Adds the machine and lets it connect and the repository list and attach.
  void addMachine(String id, String label) {
    unawaited(machines.save(_profile(id, label), secrets: const MachineSecrets(password: 'x')));
    async.elapse(const Duration(seconds: 1));
    expect(conn(id).isLive, isTrue);
  }

  void dispose() {
    repo.dispose();
    fleet.dispose();
  }
}

int _timers(FakeAsync async) => async.nonPeriodicTimerCount + async.periodicTimerCount;

/// Twelve running keepers on host `a`, `k00` the least and `k11` the most
/// recently active.
FakeAgentHost _twelve(_Fleet h, {void Function(int i, FakeKeeper k)? each}) {
  final host = h.host('a');
  for (var i = 0; i < 12; i++) {
    final k = host.add(id: 'k${i.toString().padLeft(2, '0')}', title: 'Task $i')
      ..lastEventAt = DateTime.utc(2026, 3, 1, 10, i);
    each?.call(i, k);
  }
  return host;
}

/// The keepers a channel is open to right now.
Set<String> _open(FakeAgentHost host) => {
      for (final k in host.keepers.values)
        if (k.linkOpen) k.info.id,
    };

bool _attached(_Fleet h, String key) => (h.repo.byKey(key)! as AcpAgentSession).attached;
