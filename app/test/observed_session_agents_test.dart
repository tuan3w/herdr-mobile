import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/observed/claude_log_mapper.dart';
import 'package:herdr_mobile/data/observed/codex_kind.dart';
import 'package:herdr_mobile/data/observed/observed_kind.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/observed/session_log_locator.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show Pane;
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/repositories/observed_sessions.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_subject.dart';

import 'support/create_harness.dart';
import 'support/fake_claude_ask.dart';
import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';
import 'support/fake_transport.dart';

// Claude Code and Codex panes as chats: what a person approves and answers, and
// what happens when the log cannot be found. Screens and logs are the real
// captures in test/fixtures/ (Claude Code 2.1.293, Codex 0.153.4).

/// The screen of a prompt fixture, without its `# key: value` header.
String _screen(String name) =>
    File('test/fixtures/prompts/$name.txt').readAsLinesSync().skipWhile((l) => l.startsWith('# ')).join('\n');

List<String> _lines(String dir, String name) => File('test/fixtures/$dir/$name.jsonl').readAsLinesSync();

/// The lines up to and including the first that calls [tool] (Claude).
List<String> _claudeThrough(String name, String tool) {
  final all = _lines('claude_logs', name);
  return all.sublist(0, all.indexWhere((l) => l.contains('"type":"tool_use"') && l.contains('"name":"$tool"')) + 1);
}

const _claudeLog = '/home/u/.claude/projects/-tmp-x/3f1c9a52-7d0e-4b6a-9a11-0c5d2e8b7f41.jsonl';
const _codexLog = '/home/u/.codex/sessions/2026/10/09/rollout-2026-10-09T19-43-18-01a120b0-76ea-7a42-a868-59d0ab120afc.jsonl';

Future<(ObservedRig, ObservedAgentSession)> _open(
  ObservedKind kind,
  List<String> lines, {
  required String status,
  required String screen,
}) async {
  final rig = await ObservedRig.create(status: status, agent: kind.id, log: kind.id == 'claude' ? _claudeLog : _codexLog);
  addTearDown(rig.dispose);
  // The agent's log is on the host (the follower itself is the fake source).
  rig.transport.fs = FakeFs()..addFile(kind.id == 'claude' ? _claudeLog : _codexLog, '{}\n');
  rig.transport.screen = screen;
  rig.source.write(lines);
  final session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    kind: kind,
    source: rig.source,
    mapper: kind.newMapper,
    previews: rig.previews,
    answerGrace: const Duration(seconds: 30),
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live, reason: 'log followed');
  return (rig, session);
}

void main() {
  group('Claude Code', () {
    Future<(ObservedRig, ObservedAgentSession)> approval({String? screen}) async {
      final (rig, session) = await _open(
        claudeKind,
        _claudeThrough('bash-approve', 'Bash'),
        status: 'blocked',
        screen: screen ?? _screen('claude/approval-bash'),
      );
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the dialog is understood');
      return (rig, session);
    }

    test('a Bash approval is a card with the command itself, from the log and the screen', () async {
      final (_, session) = await approval();

      final request = (session.state.pending.single as PendingPermission).request;
      expect(describePermission(request).subject, 'touch /tmp/hm-capture-claude/x.txt');
      expect(request.toolCall.toolCallId, startsWith('toolu_'), reason: 'the open call of the log is the one asked about');
      expect(session.agentLabel, 'Claude Code');
    });

    test('a card made before the log arrived is made again with the call once it has', () async {
      final rig = await ObservedRig.create(status: 'blocked', agent: 'claude', log: _claudeLog);
      addTearDown(rig.dispose);
      rig.transport.fs = FakeFs()..addFile(_claudeLog, '{}\n');
      rig.transport.screen = _screen('claude/plan-approval');
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: claudeKind,
        source: rig.source,
        mapper: ClaudeLogMapper.new,
        previews: rig.previews,
        readyAfter: const Duration(milliseconds: 20),
      );
      addTearDown(session.dispose);
      session.acquire();
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the dialog is understood before the log');
      expect((session.state.pending.single as PendingPermission).request.toolCall.toolCallId, 'prompt');

      rig.source.push(_claudeThrough('plan-mode', 'ExitPlanMode'));

      Object? planOf() => session.state.pending.isEmpty
          ? null
          : ((session.state.pending.single as PendingPermission).request.toolCall.fields['rawInput'] as Map?)?['plan'];
      await eventually(() => planOf() is String, reason: 'the card has the plan of the call');
      expect(planOf(), startsWith('# Plan: create hello.txt'));
    });

    test('Yes sends its digit and enter only after the screen was read again', () async {
      final (rig, session) = await approval();
      final id = session.state.pending.single.id;
      final reads = rig.sent('pane.read').length;

      session.answerPermission(id, const PermissionSelected('0'));
      await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'keys sent');

      expect(rig.sent('pane.send_keys').single['keys'], ['1', 'enter']);
      expect(rig.sent('pane.read').length, greaterThan(reads), reason: 'the screen was read before the keys');
    });

    test('nothing is sent when the screen no longer asks that', () async {
      final (rig, session) = await approval();
      final id = session.state.pending.single.id;
      rig.transport.screen = '  ⏺ Working… (esc to interrupt)\n';

      session.answerPermission(id, const PermissionSelected('0'));
      await eventually(() => session.error != null, reason: 'the person is told');

      expect(rig.sent('pane.send_keys'), isEmpty);
    });

    test('a different command on the screen is not the card the person tapped', () async {
      final (rig, session) = await approval();
      final id = session.state.pending.single.id;
      rig.transport.screen = _screen('claude/approval-bash-dontask');

      session.answerPermission(id, const PermissionSelected('0'));
      await eventually(() => session.error != null, reason: 'the person is told');

      expect(rig.sent('pane.send_keys'), isEmpty);
    });

    test('a plan for approval shows the plan from the log, and a refusal is esc', () async {
      final (rig, session) = await _open(
        claudeKind,
        _claudeThrough('plan-mode', 'ExitPlanMode'),
        status: 'blocked',
        screen: _screen('claude/plan-approval'),
      );
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the dialog is understood');

      final request = (session.state.pending.single as PendingPermission).request;
      expect((request.toolCall.fields['rawInput'] as Map)['plan'], startsWith('# Plan: create hello.txt'));
      session.answerPermission(session.state.pending.single.id, const PermissionCancelled());
      await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'esc sent');
      expect(rig.sent('pane.send_keys').single['keys'], ['esc']);
    });

    test('Stop is esc, and not twice within a moment: a second one opens the rewind menu', () async {
      final (rig, session) = await _open(claudeKind, _claudeThrough('bash-approve', 'Bash'), status: 'working', screen: '');

      session.cancel();
      session.cancel();
      await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'esc sent');

      expect(rig.sent('pane.send_keys').map((k) => k['keys']), [
        ['esc'],
      ]);
    });
  });

  group('Claude Code\'s question tool', () {
    /// The log of ask-two up to the call, the dialog as a model that takes keys,
    /// and the rest of the log (the tool result) to push once the dialog ends.
    Future<(ObservedRig, ObservedAgentSession, FakeClaudeAsk, List<String>)> asking() async {
      final all = _lines('claude_logs', 'ask-two');
      final at = all.indexWhere((l) => l.contains('"type":"tool_use"') && l.contains('"name":"AskUserQuestion"'));
      final probe = ClaudeLogMapper();
      for (final l in all.sublist(0, at + 1)) {
        probe.map(l);
      }
      final fake = FakeClaudeAsk(probe.pendingAsk!.questions);
      final (rig, session) = await _open(claudeKind, all.sublist(0, at + 1), status: 'working', screen: '');
      rig.transport.liveScreen = fake.screen;
      rig.transport.onInput = (p) {
        final text = p['text'];
        if (text is String) fake.paste(text);
        for (final k in (p['keys'] as List?) ?? const []) {
          fake.press('$k');
        }
      };
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the question');
      return (rig, session, fake, all.sublist(at + 1));
    }

    test('the question is a form with the log\'s own options', () async {
      final (_, session, _, _) = await asking();

      final pending = session.state.pending.single;
      expect(pending, isA<PendingQuestion>());
      expect(session.agentLabel, 'Claude Code');
    });

    test('answering drives the dialog by keys, and the result the log records is the answer given', () async {
      final (rig, session, fake, rest) = await asking();
      final q = session.state.pending.single as PendingQuestion;
      final langs = fake.questions[0].options;
      final extras = fake.questions[1].options;

      session.answerQuestion(
        q.id,
        ElicitationAccept({
          'q0': '${langs.indexWhere((o) => o.label == 'Go')}',
          'q1': [for (final l in ['Tests', 'CI']) '${extras.indexWhere((o) => o.label == l)}', 'other'],
          'q1_other': 'Docs please',
        }),
      );
      await eventually(() => fake.submitted, reason: 'the dialog was answered by keys');
      expect([fake.answerOf(0), fake.answerOf(1)], ['Go', 'Tests, CI, Docs please']);

      rig.source.push(rest); // Claude writes the tool result
      await eventually(() => session.state.pending.isEmpty, reason: 'the question is answered');
      expect(session.error, isNull, reason: 'the result Claude recorded is what was answered');
    });

    test('declining sends esc while the dialog is up, and not when it is gone', () async {
      final (rig, session, fake, _) = await asking();
      final q = session.state.pending.single;

      session.answerQuestion(q.id, const ElicitationDecline());
      await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'esc sent');

      expect(rig.sent('pane.send_keys').single['keys'], ['esc']);
      expect(fake.declined, isTrue);
    });
  });

  group('Codex', () {
    test('a command that waits for approval is the card, with the command from the log', () async {
      final lines = _lines('codex_logs', 'command-approve');
      final (_, session) = await _open(
        codexKind,
        lines.sublist(0, lines.indexWhere((l) => l.contains('"custom_tool_call"')) + 1),
        status: 'blocked',
        screen: _screen('codex/approval-command'),
      );
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the dialog is understood');

      final request = (session.state.pending.single as PendingPermission).request;
      expect(request.toolCall.fields['title'], 'curl -sI https://example.com | head -1', reason: 'the `\$ ` of the screen matched the call');
      expect(session.agentLabel, 'Codex');
    });

    test('a question Codex asks is a menu card, not a form: answering sends the digit alone', () async {
      final lines = _lines('codex_logs', 'ask-two');
      final (rig, session) = await _open(
        codexKind,
        lines.sublist(0, lines.indexWhere((l) => l.contains('"request_user_input"')) + 1),
        status: 'blocked',
        screen: _screen('codex/ask-two-first'),
      );
      await eventually(() => session.state.pending.isNotEmpty, reason: 'the dialog is understood');

      expect(session.state.pending.single, isA<PendingPermission>(), reason: 'Codex has no question driver: no PendingQuestion');
      session.answerPermission(session.state.pending.single.id, const PermissionSelected('1'));
      await eventually(() => rig.sent('pane.send_keys').isNotEmpty, reason: 'keys sent');

      expect(rig.sent('pane.send_keys').single['keys'], ['2'], reason: 'an enter would answer the next question too');
    });
  });

  group('a log the agent has not written yet', () {
    test('waits quietly, and follows it when herdr reports the session', () async {
      final rig = await ObservedRig.create(agent: 'claude', log: null);
      addTearDown(rig.dispose);
      rig.source.write(_claudeThrough('bash-approve', 'Bash'));
      final locator = _Scripted();
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: ObservedKind(id: 'claude', label: 'Claude Code', newMapper: ClaudeLogMapper.new, locator: locator),
        source: rig.source,
        mapper: ClaudeLogMapper.new,
        previews: rig.previews,
      );
      addTearDown(session.dispose);
      session.acquire();
      await eventually(() => locator.asked > 0, reason: 'looked for the log');

      expect(session.waiting, 'Claude has not written this session yet.');
      expect(session.link, AgentLink.live, reason: 'an empty chat the person can type into, not a connection that never comes');
      expect(rig.source.calls, isEmpty, reason: 'nothing to follow yet');

      locator.found = _claudeLog;
      await rig.setLog(_claudeLog);

      await eventually(() => rig.source.calls.isNotEmpty && session.state.toolCalls.isNotEmpty, reason: 'followed once the session is known');
      expect(rig.source.calls.single.path, _claudeLog);
      expect(session.waiting, isNull);
      expect(session.state.toolCalls, hasLength(1));
    });
  });

  group('a log that cannot be found', () {
    /// A claude pane herdr reports no session for, on a host with no claude
    /// files: nothing links the pane to a log.
    Future<(ObservedRig, ObservedAgentSession, List<int>)> unlinked() async {
      final rig = await ObservedRig.create(agent: 'claude', log: null);
      addTearDown(rig.dispose);
      rig.transport.fs = FakeFs();
      final told = <int>[];
      final session = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: claudeKind,
        source: rig.source,
        mapper: ClaudeLogMapper.new,
        previews: rig.previews,
        onUnlinked: () => told.add(1),
      );
      addTearDown(session.dispose);
      session.acquire();
      return (rig, session, told);
    }

    test('fails the link with what to do, and tells the registry', () async {
      final (_, session, told) = await unlinked();
      await eventually(() => session.link == AgentLink.failed, reason: 'unlinked');

      expect(session.error, contains('herdr integration install claude'));
      expect(told, [1]);
    });

    test('the registry opens such a pane as its terminal for a while, and offers the integration', () async {
      final h = await CreateHarness.create([
        (
          profile: profileOf('a', 'workstation'),
          snapshot: snapshotJson(
            workspaces: const [(id: 'w1', label: 'api')],
            panes: const [
              (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle'),
              (id: 'w1:p2', ws: 'w1', agent: 'codex', status: 'idle'),
              (id: 'w1:p3', ws: 'w1', agent: 'omp', status: 'idle'),
            ],
          ),
        ),
      ]);
      addTearDown(h.dispose);
      final machine = h.connection('a');
      final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
      addTearDown(previews.dispose);
      final sessions = ObservedSessions(
        fleet: h.fleet,
        previews: previews,
        sourceFor: (_) => FakeLogSource(),
        kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
      );
      addTearDown(sessions.dispose);

      expect(sessions.supports(machine, 'w1:p1'), isTrue, reason: 'a claude pane may be found by its process');
      expect(sessions.supports(machine, 'w1:p2'), isFalse, reason: 'Codex without a session reference cannot be linked');
      expect(sessions.supports(machine, 'w1:p3'), isFalse, reason: 'omp reports no log');
      expect(sessions.integrationFor(machine, 'w1:p2'), 'codex');
      expect(sessions.integrationFor(machine, 'w1:p1'), 'claude', reason: 'offered while herdr reports no session, whatever happened to a look');
      expect(sessions.integrationFor(machine, 'w1:p3'), isNull, reason: 'omp needs no offer');

      sessions.markUnlinked(machine, 'w1:p1');

      expect(sessions.supports(machine, 'w1:p1'), isFalse);
      expect(sessions.integrationFor(machine, 'w1:p1'), 'claude');
      expect(sessions.forPane(machine, 'w1:p1'), isNull, reason: 'the terminal, not a failed chat');
    });
  });
}

/// A locator that says "not yet" until [found] is set.
class _Scripted implements SessionLogLocator {
  String? found;
  var asked = 0;

  @override
  bool mayLocate(Pane pane) => true;

  @override
  Future<LogLocation> locate(MachineConnection machine, Pane pane) async {
    asked++;
    final path = found;
    return path == null ? const NotYet('Claude has not written this session yet.') : Located(path);
  }
}
