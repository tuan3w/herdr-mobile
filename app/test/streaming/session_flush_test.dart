// AcpAgentSession's notification path with a scripted FlushScheduler: chunks
// coalesce into one flush per frame, urgent changes ride the same flush, the
// background profile keeps its timers, a text chunk does not replace the item
// list, and Send shows the row and `working` in the first frame.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/live_text.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/acp_agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';

import '../support/fake_agent_host.dart';
import '../support/fake_flush.dart';
import '../support/fake_transport.dart';

final _t0 = DateTime.utc(2026, 3, 1, 12);

class _Rig {
  _Rig(this.async) : host = FakeAgentHost(clock: () => _t0.add(async.elapsed)) {
    machine = MachineConnection(
      profile: const MachineProfile(id: 'm1', label: 'studio-mac', host: 'm1.local', username: 'u'),
      api: HerdrApi(FakeTransport()),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    )..start();
    async.flushMicrotasks();
    keeper = host.add(sessionId: 's1');
    session = AcpAgentSession(
      machine: machine,
      host: host,
      info: keeper.info,
      clock: () => _t0.add(async.elapsed),
      flush: flush,
    )..addListener(() => notifications++);
  }

  final FakeAsync async;
  final FakeAgentHost host;
  final flush = FakeFlush();
  late final MachineConnection machine;
  late final FakeKeeper keeper;
  late final AcpAgentSession session;
  var notifications = 0;

  /// Attached, with the flush that the attach itself caused already run.
  void connect() {
    unawaited(session.connect());
    async.elapse(const Duration(milliseconds: 20));
    flush.fire();
    flush.frame();
    notifications = 0;
  }

  /// What the keeper sent reaches the session (a microtask or two).
  void deliver() => async.flushMicrotasks();

  void dispose() {
    session.dispose();
    machine.dispose();
  }
}

void _rigTest(String name, void Function(_Rig r) body) => test(name, () {
      fakeAsync((async) {
        final r = _Rig(async);
        body(r);
        r.dispose();
      });
    });

void main() {
  group('flush', () {
    _rigTest('chunks that arrive between frames are one flush and one notification', (r) {
      r.connect();
      for (var i = 0; i < 12; i++) {
        r.keeper.say('word$i ');
      }
      r.deliver();

      expect(r.notifications, 0, reason: 'nothing is told before the frame');
      expect(r.flush.framesWaiting, 1, reason: 'one flush waits, however many chunks came');
      r.flush.frame();
      expect(r.notifications, 1);
      expect(r.session.state.items.whereType<TranscriptMessage>().single.text, startsWith('word0 word1 '));
    });

    _rigTest('a flush asked for while another waits adds none', (r) {
      r.connect();
      r.keeper.say('one ');
      r.deliver();
      final scheduled = r.flush.scheduledFrames;
      r.keeper.say('two ');
      r.keeper.say('three ');
      r.deliver();
      expect(r.flush.scheduledFrames, scheduled);
      r.flush.frame();

      r.keeper.say('four ');
      r.deliver();
      expect(r.flush.scheduledFrames, scheduled + 1, reason: 'the next burst asks for the next frame');
    });

    _rigTest('an urgent change rides the same flush as the chunks before it', (r) {
      r.connect();
      r.keeper.say('thinking about it ');
      r.deliver();
      expect(r.flush.framesWaiting, 1);

      r.keeper.askPermission();
      r.deliver();
      expect(r.flush.framesWaiting, 1, reason: 'the request does not wait for a second frame');
      r.flush.frame();
      expect(r.notifications, 1);
      expect(r.session.phase, AgentPhase.blockedOnPermission);
      expect(r.session.state.liveKey, isNotNull);
    });

    _rigTest('a finished turn is flushed with the frame and settles the live message', (r) {
      r.connect();
      r.keeper.turn = Completer<String>();
      unawaited(r.session.send('go'));
      r.keeper.say('done ');
      r.deliver();
      r.flush.frame();
      expect(r.session.state.liveKey, isNotNull);

      r.keeper.finishTurn();
      r.deliver();
      expect(r.flush.framesWaiting, 1);
      r.flush.frame();
      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.state.liveKey, isNull, reason: 'the message ended: the list holds its final text');
      expect(r.session.state.items.whereType<TranscriptMessage>().last.text, 'done ');
    });

    _rigTest('in the background a kept session flushes text by timer, urgent changes sooner', (r) {
      r.connect();
      r.session
        ..keepAliveInBackground = true
        ..background(since: _t0);
      r.flush.fire();
      r.flush.frame();
      r.notifications = 0;
      final frames = r.flush.scheduledFrames;

      r.keeper.say('streaming while away ');
      r.deliver();
      expect(r.flush.scheduledFrames, frames, reason: 'no frame runs while the app is away');
      expect(r.flush.timersWaiting, [r.session.backgroundNotifyEvery]);

      r.keeper.askPermission();
      r.deliver();
      expect(r.flush.timersWaiting, [r.session.notifyEvery], reason: 'urgent: the slow timer is replaced');
      r.flush.fire();
      expect(r.notifications, 1);
      expect(r.session.phase, AgentPhase.blockedOnPermission);
    });

    _rigTest('coming back flushes what waited for the slow timer at the next frame', (r) {
      r.connect();
      r.session
        ..keepAliveInBackground = true
        ..background(since: _t0);
      r.flush.fire();
      r.keeper.say('while away ');
      r.deliver();
      expect(r.flush.timersWaiting, hasLength(1));

      r.session.foreground();
      expect(r.flush.timersWaiting, isEmpty);
      expect(r.flush.framesWaiting, 1);
      r.flush.frame();
      expect(r.notifications, 1);
    });

    _rigTest('dispose cancels the flush that waits', (r) {
      r.connect();
      r.keeper.say('x ');
      r.deliver();
      expect(r.flush.framesWaiting, 1);
      r.session.dispose();
      expect(r.flush.framesWaiting, 0);
    });

    _rigTest('by default a timer of notifyEvery flushes, as before frames were injected', (r) {
      final other = AcpAgentSession(
        machine: r.machine,
        host: r.host,
        info: r.keeper.info,
        clock: () => _t0.add(r.async.elapsed),
      );
      var told = 0;
      other.addListener(() => told++);
      unawaited(other.connect());
      r.async.elapse(const Duration(milliseconds: 5));
      final before = told;
      r.async.elapse(const Duration(milliseconds: 40));
      expect(told, greaterThan(before), reason: 'the attach was flushed without any frame');
      other.dispose();
    });
  });

  group('the live slot through the session', () {
    _rigTest('a chunk does not replace the items; the row listens to the live text', (r) {
      r.connect();
      r.keeper.say('first ');
      r.deliver();
      r.flush.frame();
      final items = r.session.state.items;
      final key = r.session.state.liveKey!;
      final live = r.session.liveTextOf(key)! as LiveText;
      var heard = 0;
      live.addListener(() => heard++);

      for (var i = 0; i < 30; i++) {
        r.keeper.say('more$i ');
      }
      r.deliver();
      expect(identical(r.session.state.items, items), isTrue, reason: 'the list is the same instance');
      expect(heard, 0, reason: 'the row hears of the text with the flush, not per chunk');
      expect(live.text, startsWith('first more0 more1 '));

      r.flush.frame();
      expect(heard, 1);
      expect(r.notifications, 2);
      expect(identical(r.session.state.items, items), isTrue);
      expect(r.session.liveTextOf('nope'), isNull);
    });

    _rigTest('a tool call settles the live message and the next text goes live again', (r) {
      r.connect();
      r.keeper.say('before ');
      r.deliver();
      r.flush.frame();
      final first = r.session.state.liveKey!;
      final items = r.session.state.items;

      r.keeper.update({'sessionUpdate': 'tool_call', 'toolCallId': 't1', 'title': 'Read', 'kind': 'read'});
      r.deliver();
      r.flush.frame();
      expect(identical(r.session.state.items, items), isFalse, reason: 'the structure changed');
      expect(r.session.state.liveKey, isNull);
      expect(r.session.liveTextOf(first), isNull);
      final settled = r.session.state.items.whereType<TranscriptMessage>().single;
      expect(settled.live, isNull);
      expect(settled.text, 'before ');

      r.keeper.say('after ', messageId: 'a2');
      r.deliver();
      r.flush.frame();
      expect(r.session.state.liveKey, isNot(first));
    });
  });

  group('send', () {
    _rigTest('the local row and `working` are there in the first frame, with the turn clock', (r) {
      r.connect();
      r.keeper.turn = Completer<String>();
      r.async.elapse(const Duration(seconds: 3));
      final sentAt = _t0.add(r.async.elapsed);

      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.turnStartedAt, isNull);
      unawaited(r.session.send('fix the bug'));
      // No microtask has run, no time has passed: only the synchronous part.
      final last = r.session.state.items.last as TranscriptMessage;
      expect(last.role, MessageRole.user);
      expect(last.local, isTrue);
      expect(last.text, 'fix the bug');
      expect(r.session.phase, AgentPhase.working);
      expect(r.session.phaseSince, sentAt);
      expect(r.session.turnStartedAt, sentAt);
      expect(r.flush.framesWaiting, 1, reason: 'the next frame carries it');
      expect(r.notifications, 0);

      r.flush.frame();
      expect(r.notifications, 1);

      r.async.elapse(const Duration(seconds: 5));
      r.keeper.say('on it ');
      r.deliver();
      r.flush.frame();
      expect(r.session.turnStartedAt, sentAt, reason: 'the clock counts from Send, not from the first token');

      r.keeper.finishTurn();
      r.deliver();
      r.flush.frame();
      expect(r.session.phase, AgentPhase.idle);
      expect(r.session.turnStartedAt, isNull);
    });

    _rigTest('a second turn starts its own clock', (r) {
      r.connect();
      r.keeper.turn = Completer<String>();
      unawaited(r.session.send('one'));
      r.keeper.finishTurn();
      r.deliver();
      r.flush.frame();
      expect(r.session.turnStartedAt, isNull);

      r.async.elapse(const Duration(seconds: 10));
      r.keeper.turn = Completer<String>();
      unawaited(r.session.send('two'));
      expect(r.session.turnStartedAt, _t0.add(r.async.elapsed));
    });

    _rigTest('a turn that was already running when the app looked starts its clock then', (r) {
      r.connect();
      r.async.elapse(const Duration(seconds: 4));
      r.keeper.update({'sessionUpdate': 'state_update', 'state': 'running'});
      r.deliver();
      expect(r.session.phase, AgentPhase.working);
      expect(r.session.turnStartedAt, _t0.add(r.async.elapsed));
    });

    _rigTest('a send that cannot go leaves no turn clock and no row', (r) {
      // Not connected: nothing is attached.
      unawaited(r.session.send('hello'));
      expect(r.session.turnStartedAt, isNull);
      expect(r.session.state.items, isEmpty);
      expect(r.session.error, isNotNull);
    });
  });
}
