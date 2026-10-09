import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/observed/claude_log_mapper.dart';
import 'package:herdr_mobile/data/observed/claude_subagent_logs.dart';
import 'package:herdr_mobile/data/observed/codex_kind.dart';
import 'package:herdr_mobile/data/observed/codex_locator.dart';
import 'package:herdr_mobile/data/observed/observed_contracts.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink, SubagentState;
import 'package:herdr_mobile/data/repositories/observed_session.dart';

import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';
import 'support/fake_transport.dart';

// Where the transcripts of Claude Code's and Codex's subagents are, and whether
// they are still being written. Files and ids are the real captures
// (test/fixtures/claude_logs/subagents, codex_logs/subagent*).

const _parentLog = '/home/u/.claude/projects/-tmp-x/aaaaaaaa-0000-4000-8000-000000000001.jsonl';
const _dir = '/home/u/.claude/projects/-tmp-x/aaaaaaaa-0000-4000-8000-000000000001/subagents';
const _agent = 'a6c798c858e96e728';
const _call = 'toolu_019d2qfwngqnzYnhnaEihhwd';

String _fixture(String path) => File('test/fixtures/claude_logs/$path').readAsStringSync();

Future<ObservedRig> _rig(FakeFs fs, {String agent = 'claude'}) async {
  final rig = await ObservedRig.create(agent: agent, log: _parentLog);
  addTearDown(rig.dispose);
  rig.transport.fs = fs;
  return rig;
}

void main() {
  group('Claude Code', () {
    final logs = ClaudeSubagentLogs();

    test('the transcript is named by the agent id the parent log gave', () async {
      final fs = FakeFs()..addFile('$_dir/agent-$_agent.jsonl', _fixture('subagents/agent-$_agent.jsonl'));
      final rig = await _rig(fs);

      final path = await logs.pathOf(rig.machine, _parentLog, const SubagentInfo(name: 'List files', logId: _agent));

      expect(path, '$_dir/agent-$_agent.jsonl');
    });

    test('before the parent knows the id, the .meta.json that names the call says which file it is', () async {
      final fs = FakeFs()
        ..addFile('$_dir/agent-$_agent.jsonl', _fixture('subagents/agent-$_agent.jsonl'))
        ..addFile('$_dir/agent-$_agent.meta.json', _fixture('subagents/agent-$_agent.meta.json'))
        ..addFile('$_dir/agent-a7348e8a87aaf897f.meta.json', _fixture('subagents/agent-a7348e8a87aaf897f.meta.json'));
      final rig = await _rig(fs);

      final path = await logs.pathOf(rig.machine, _parentLog, const SubagentInfo(name: 'List files', callId: _call));

      expect(path, '$_dir/agent-$_agent.jsonl');
    });

    test('a file that does not exist yet is not followed', () async {
      final fs = FakeFs()..addDir(_dir);
      final rig = await _rig(fs);
      expect(await logs.pathOf(rig.machine, _parentLog, const SubagentInfo(name: 'x', logId: _agent)), isNull);
    });

    test('an id from a log never becomes a path outside the folder', () async {
      final fs = FakeFs();
      final rig = await _rig(fs);

      for (final bad in ['../../../../etc/passwd', 'a/b', 'a b', 'x' * 65, '']) {
        expect(await logs.pathOf(rig.machine, _parentLog, SubagentInfo(name: 'x', logId: bad)), isNull, reason: bad);
      }
      expect(fs.calls, isEmpty);
    });

    test('a meta file of any size or shape is not trusted', () async {
      final fs = FakeFs()
        ..addFile('$_dir/agent-$_agent.meta.json', 'x' * 20000)
        ..addFile('$_dir/agent-a7348e8a87aaf897f.meta.json', '{"toolUseId": 5}');
      final rig = await _rig(fs);
      expect(await logs.pathOf(rig.machine, _parentLog, const SubagentInfo(name: 'x', callId: _call)), isNull);
    });

    test('running while its file was written lately, finished otherwise', () async {
      final fs = FakeFs()
        ..addFile('$_dir/agent-$_agent.jsonl', '{}\n', modified: DateTime.now().toUtc())
        ..addFile('$_dir/agent-a7348e8a87aaf897f.jsonl', '{}\n', modified: DateTime.now().toUtc().subtract(const Duration(minutes: 5)));
      final rig = await _rig(fs);

      final states = await logs.refine(
        rig.machine,
        _parentLog,
        const [SubagentInfo(name: 'fresh', logId: _agent), SubagentInfo(name: 'old', logId: 'a7348e8a87aaf897f')],
        running: const Duration(seconds: 32),
      );

      expect(states, {'fresh': SubagentState.running, 'old': SubagentState.finished});
    });

    test('a subagent opens as a chat of its own transcript, read by the sidechain mapper', () async {
      final fs = FakeFs()
        ..addFile(_parentLog, '{}\n')
        ..addFile('$_dir/agent-$_agent.jsonl', _fixture('subagents/agent-$_agent.jsonl'));
      final rig = await _rig(fs);
      rig.source.write(File('test/fixtures/claude_logs/subagent.jsonl').readAsLinesSync());
      final parent = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: claudeKind,
        source: rig.source,
        mapper: ClaudeLogMapper.new,
        previews: rig.previews,
      );
      addTearDown(parent.dispose);
      parent.acquire();
      await eventually(() => parent.link == AgentLink.live, reason: 'parent followed');
      expect(parent.logPath, _parentLog);

      final childSource = FakeLogSource()..write(File('test/fixtures/claude_logs/subagents/agent-$_agent.jsonl').readAsLinesSync());
      final child = ObservedAgentSession(
        machine: rig.machine,
        paneId: 'w1:p1',
        kind: claudeKind,
        source: childSource,
        mapper: claudeKind.newSubagentMapper!,
        parent: parent,
        subagentName: 'List files in hm-capture-claude',
      );
      addTearDown(child.dispose);
      child.acquire();
      await eventually(() => child.link == AgentLink.live, reason: 'child followed');

      expect(childSource.calls.single.path, '$_dir/agent-$_agent.jsonl');
      expect(child.state.toolCalls.single.title, 'List contents of hm-capture-claude temp directory');
      expect(child.agentLabel, startsWith('Subagent of'));
    });
  });

  group('Codex', () {
    const child = '01a120bb-b7c6-7d22-9a8c-9aa1031d513f';
    final childFile = '/home/dev/.codex/sessions/2026/10/09/rollout-2026-10-09T19-45-35-$child.jsonl';
    late CodexSubagentLogs logs;
    setUp(() => logs = CodexSubagentLogs(CodexLocator()));

    test('a subagent is a thread: its rollout is found by its thread id, and is running while written', () async {
      final fs = FakeFs()..addFile(childFile, '{}\n', modified: DateTime.now().toUtc());
      final rig = await _rig(fs, agent: 'codex');
      const info = SubagentInfo(name: 'list_files', logId: child);

      expect(await logs.pathOf(rig.machine, '/ignored.jsonl', info), childFile);
      final states = await logs.refine(rig.machine, '/ignored.jsonl', const [info], running: const Duration(seconds: 32));
      expect(states, {'list_files': SubagentState.running});
    });

    test('a subagent whose id is not known yet, or whose file is not there, has no transcript yet', () async {
      final rig = await _rig(FakeFs()..addDir('/home/dev/.codex/sessions'), agent: 'codex');

      expect(await logs.pathOf(rig.machine, '/x.jsonl', const SubagentInfo(name: 'a')), isNull);
      expect(await logs.pathOf(rig.machine, '/x.jsonl', const SubagentInfo(name: 'a', logId: child)), isNull);
    });
  });
}
