// The commands and skills a chat of an agent in a terminal offers: what the
// machine's files say, plus the skills the agent's own log listed (Claude's
// plugin and bundled ones, which have no folder to find).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/observed/claude_log_mapper.dart';
import 'package:herdr_mobile/data/observed/codex_kind.dart';
import 'package:herdr_mobile/data/observed/codex_log_mapper.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/repositories/command_source.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';

import 'support/fake_fs.dart';
import 'support/fake_log_source.dart';
import 'support/fake_transport.dart' show eventually;

// The fake pane's folder, as `snapshotJson` makes it.
const _cwd = '/work/w1';
const _claudeLog = '/home/u/.claude/projects/-work-w1/aaaaaaaa-0000-4000-8000-000000000001.jsonl';

final _listing = jsonEncode({
  'type': 'attachment',
  'attachment': {
    'type': 'skill_listing',
    'isInitial': true,
    'names': ['ship', 'superpowers:brainstorming'],
    'content': '- ship: Ship the log\'s way\n- superpowers:brainstorming: Explore ideas',
  },
});

Future<(ObservedRig, ObservedAgentSession)> _open({
  required FakeFs fs,
  List<String> lines = const [],
  String agent = 'claude',
}) async {
  final rig = await ObservedRig.create(agent: agent, log: agent == 'claude' ? _claudeLog : ompLog);
  addTearDown(rig.dispose);
  rig.transport.fs = fs;
  if (agent == 'claude') fs.addFile(_claudeLog, '{}\n');
  rig.source.write(lines);
  final claude = agent == 'claude';
  final session = ObservedAgentSession(
    machine: rig.machine,
    paneId: 'w1:p1',
    kind: claude ? claudeKind : codexKind,
    source: rig.source,
    mapper: claude ? ClaudeLogMapper.new : CodexLogMapper.new,
    previews: rig.previews,
  );
  addTearDown(session.dispose);
  session.acquire();
  await eventually(() => session.link == AgentLink.live, reason: 'log followed');
  return (rig, session);
}

FakeFs _files() => FakeFs()
  ..addFile('$_cwd/.claude/skills/ship/SKILL.md', '---\ndescription: Ship it from the folder\n---\n')
  ..addFile('/home/dev/.claude/commands/standup.md', 'Write the standup\n');

List<String> _names(List<SlashCommand> list) => [for (final c in list) c.name];

void main() {
  test('before a command is begun, what the log listed is all there is', () async {
    final (_, session) = await _open(fs: _files(), lines: [_listing]);
    await eventually(() => session.slashCommands.isNotEmpty, reason: 'the log\'s skills');

    expect(_names(session.slashCommands), ['ship', 'superpowers:brainstorming']);
    expect(session.slashCommands.first.description, 'Ship the log\'s way');
  });

  test('wanting commands reads the machine; its entries come first and win, the log adds what it lacks', () async {
    final (_, session) = await _open(fs: _files(), lines: [_listing]);
    await eventually(() => session.slashCommands.isNotEmpty, reason: 'the log\'s skills');
    var told = 0;
    session.addListener(() => told++);

    session.wantCommands();
    await eventually(() => session.slashCommands.any((c) => c.name == 'standup'), reason: 'the catalog');

    final list = session.slashCommands;
    final ship = list.where((c) => c.name == 'ship').toList();
    expect(ship, hasLength(1), reason: 'one of a name');
    expect(ship.single.source, SlashSource.project);
    expect(ship.single.description, 'Ship it from the folder');
    expect(list.firstWhere((c) => c.name == 'standup').source, SlashSource.user);
    expect(list.firstWhere((c) => c.name == 'clear').source, SlashSource.builtIn, reason: 'Claude\'s own table');
    expect(list.last.name, 'superpowers:brainstorming', reason: 'a plugin skill has no folder: only the log knows it');
    await eventually(() => told > 0, reason: 'the palette is told');
  });

  test('the list is the same instance until the catalog or the log changes', () async {
    final (rig, session) = await _open(fs: _files(), lines: [_listing]);
    await eventually(() => session.slashCommands.isNotEmpty, reason: 'the log\'s skills');
    session.wantCommands();
    await eventually(() => session.slashCommands.any((c) => c.name == 'standup'), reason: 'the catalog');

    final first = session.slashCommands;
    expect(identical(session.slashCommands, first), isTrue);

    rig.source.push([
      jsonEncode({
        'type': 'attachment',
        'attachment': {'type': 'skill_listing', 'isInitial': false, 'names': ['late']},
      }),
    ]);
    await eventually(() => session.slashCommands.any((c) => c.name == 'late'), reason: 'a later listing');
    expect(identical(session.slashCommands, first), isFalse);
  });

  test('a second want within two minutes does not read the machine again', () async {
    final fs = _files();
    final (_, session) = await _open(fs: fs);
    session.wantCommands();
    await eventually(() => session.slashCommands.any((c) => c.name == 'standup'), reason: 'the catalog');
    final reads = fs.calls.length;

    session.wantCommands();
    session.wantCommands();
    await pumpEventQueue();

    expect(fs.calls.length, reads);
  });

  test('Codex skills come with their dollar', () async {
    final fs = FakeFs()..addFile('$_cwd/.agents/skills/deploy/SKILL.md', '---\ndescription: Deploy it\n---\n');
    final (_, session) = await _open(fs: fs, agent: 'codex');
    session.wantCommands();
    await eventually(() => session.slashCommands.any((c) => c.trigger == r'$'), reason: 'the catalog');

    final deploy = session.slashCommands.firstWhere((c) => c.name == 'deploy');
    expect(deploy.text, r'$deploy');
    expect(deploy.source, SlashSource.project);
  });

  test('as a source it tells the palette once per change and reads on the first slash', () async {
    final (_, session) = await _open(fs: _files(), lines: [_listing]);
    await eventually(() => session.slashCommands.isNotEmpty, reason: 'the log\'s skills');
    final source = SessionCommandSource(session);
    addTearDown(source.dispose);
    var told = 0;
    source.addListener(() => told++);
    expect(source.agent, 'claude');

    source.ensureLoaded();
    await eventually(() => source.commands.any((c) => c.name == 'standup'), reason: 'the catalog');
    final tellings = told;
    expect(tellings, greaterThan(0));

    await pumpEventQueue();
    expect(told, tellings, reason: 'nothing changed since');
  });
}
