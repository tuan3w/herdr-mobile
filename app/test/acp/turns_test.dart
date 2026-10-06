// The data half of the turn model: turns,
// Changed files, tool summaries and groups, the fold line, the status line.
// Fixtures are the recorded traces of claude, codex and omp
// (`test/fixtures/traces`), folded with their own clock; shapes the traces did
// not record (edits with diffs, searches, fetches, failures) are written out
// as the agents send them.
import 'dart:io';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/turns/plain_text.dart';
import 'package:herdr_mobile/data/acp/turns/turns.dart';

import 'support/trace_state.dart';

final _t0 = DateTime.utc(2026, 10, 5, 9);
DateTime _at(int seconds) => _t0.add(Duration(seconds: seconds));

SessionUpdate _u(Map<String, Object?> json) => SessionUpdate.parse(json);

/// The calls of the transcript and of every subagent's transcript.
List<ToolCall> _allCalls(AgentSessionState s) => [
  ...s.toolCalls,
  for (final run in s.subagents)
    for (final i in run.items)
      if (i is TranscriptTool) i.call,
];

ToolCall _call(Map<String, Object?> json) => ToolCall.parse({'toolCallId': 't', ...json});

Map<String, Object?> _agentText(String text, {String id = 'a'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

Map<String, Object?> _thought(String text, {String id = 'th'}) => {
  'sessionUpdate': 'agent_thought_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

Map<String, Object?> _tool(String id, String status, {String kind = 'execute', String title = 'tool', Object? content, Object? rawInput}) => {
  'sessionUpdate': 'tool_call',
  'toolCallId': id,
  'kind': kind,
  'title': title,
  'status': status,
  'content': ?content,
  'rawInput': ?rawInput,
};

Map<String, Object?> _diff(String path, String? oldText, String newText) => {
  'type': 'diff',
  'path': path,
  'oldText': ?oldText,
  'newText': newText,
};

/// Folds updates one second apart after a user message at second 0.
class _Run {
  _Run([String prompt = 'go']) {
    state = const AgentSessionState('s').withUserMessage([TextBlock(prompt)], at: _at(0)).withTurnStarted();
  }

  late AgentSessionState state;
  var clock = 0;

  DateTime get now => _at(clock);

  _Run add(Map<String, Object?> update, {int after = 1}) {
    clock += after;
    state = state.apply(_u(update), at: now);
    return this;
  }

  _Run end([StopReason reason = StopReason.endTurn, int after = 1]) {
    clock += after;
    state = state.withTurnEnded(reason, at: now);
    return this;
  }

  Turn get turn => turnsOf(state.items, live: state.turnActive).last;
}

void main() {
  group('lineStats', () {
    test('counts what a numstat counts', () {
      expect(lineStats(null, 'a\nb\n'), const LineStats(2, 0), reason: 'a new file adds everything');
      expect(lineStats('a\nb\n', 'a\nb\n'), LineStats.none);
      expect(lineStats('a\nb\nc\n', 'a\nB\nc\n'), const LineStats(1, 1), reason: 'a changed line is one out, one in');
      expect(lineStats('a\nc\n', 'a\nb\nc\n'), const LineStats(1, 0));
      expect(lineStats('a\nb\nc\n', 'a\nc\n'), const LineStats(0, 1));
      expect(lineStats('a\nb', ''), const LineStats(0, 2));
      expect(lineStats('', ''), LineStats.none);
      expect(lineStats('a\nb\nc\nd', 'a\nc\nb\nd'), const LineStats(1, 1), reason: 'a swap');
    });

    test('line endings and the last line feed are not changes', () {
      expect(lineStats('a\r\nb\r\n', 'a\nb\n'), LineStats.none);
      expect(lineStats('a\nb', 'a\nb\n'), LineStats.none);
      expect(lineStats('a\n\nb\n', 'a\nb\n'), const LineStats(0, 1), reason: 'a blank line is a line');
    });

    test('Vietnamese lines are lines', () {
      expect(lineStats('Hà Nội\nĐà Nẵng\n', 'Hà Nội\nĐà Lạt\nHuế\n'), const LineStats(2, 1));
    });

    test('agrees with a reference LCS on random texts', () {
      final rng = Random(7);
      for (var i = 0; i < 300; i++) {
        final a = [for (var k = rng.nextInt(30); k > 0; k--) 'l${rng.nextInt(5)}'];
        final b = [for (var k = rng.nextInt(30); k > 0; k--) 'l${rng.nextInt(5)}'];
        final expected = _referenceStats(a, b);
        expect(lineStats(a.isEmpty ? null : a.join('\n'), b.join('\n')), expected, reason: '$a -> $b');
      }
    });

    test('is bounded: a huge file is counted by multiset, a hopeless script too', () {
      final big = [for (var i = 0; i < 6000; i++) 'line $i'];
      final edited = [...big]..[3000] = 'changed';
      expect(lineStats(big.join('\n'), edited.join('\n')), const LineStats(1, 1));
      // More edits than the exact search looks for: every line is new.
      final other = [for (var i = 0; i < 3000; i++) 'x$i'];
      final first = [for (var i = 0; i < 3000; i++) 'y$i'];
      expect(lineStats(first.join('\n'), other.join('\n')), const LineStats(3000, 3000));
    });
  });

  group('Changed files', () {
    test('diffs of one path are grouped, codex hunks included; failed and pending edits count nothing', () {
      final r = _Run('refactor')
        // codex: one call, one diff per hunk, title "Editing files"
        ..add(_tool('e1', 'completed', kind: 'edit', title: 'Editing files', content: [
          _diff('/w/lib/a.dart', 'one\ntwo', 'one\n2'),
          _diff('/w/lib/a.dart', 'ten', 'ten\neleven\ntwelve'),
          _diff('/w/lib/b.dart', null, 'p\nq\nr\n'),
        ]))
        // an edit that starts from what the last one ended with is one change
        ..add(_tool('e2', 'completed', kind: 'edit', content: [_diff('/w/lib/a.dart', 'ten\neleven\ntwelve', 'ten\neleven\nTWELVE')]))
        ..add(_tool('e3', 'failed', kind: 'edit', content: [_diff('/w/lib/never.dart', 'x', 'y')]))
        ..add(_tool('e4', 'pending', kind: 'edit', content: [_diff('/w/lib/later.dart', 'x', 'y')]))
        ..add(_tool('d1', 'completed', kind: 'delete', title: 'Delete', content: const []))
        ..add({'sessionUpdate': 'tool_call_update', 'toolCallId': 'd1', 'locations': [{'path': '/w/old.txt'}]});
      final changed = r.turn.changed;
      expect(changed.map((f) => f.path), ['/w/lib/a.dart', '/w/lib/b.dart', '/w/old.txt']);
      final a = changed[0];
      expect((a.added, a.removed), (3, 1), reason: 'hunk one +1 -1, then hunk two and the next edit as one net change +2');
      expect(a.isNew, isFalse);
      expect(a.diffs, hasLength(3));
      final b = changed[1];
      expect((b.added, b.removed, b.isNew, b.isDelete), (3, 0, true, false));
      final gone = changed[2];
      expect((gone.added, gone.removed, gone.isNew, gone.isDelete), (0, 0, false, true));
    });

    test('a file written again after a delete is not deleted', () {
      final r = _Run()
        ..add(_tool('d', 'completed', kind: 'delete', rawInput: {'file_path': '/w/x'}))
        ..add(_tool('e', 'completed', kind: 'edit', content: [_diff('/w/x', null, 'again')]));
      expect(r.turn.changed.single.isDelete, isFalse);
      expect(r.turn.changed.single.isNew, isTrue);
    });

    test('the traces changed no file', () {
      for (final (agent, scenario) in _scenarios()) {
        expect(turnsOf(stateOfTrace(agent, scenario).items).single.changed, isEmpty, reason: '$agent/$scenario');
      }
    });
  });

  group('toolSummary', () {
    test('read: file name and directory hint', () {
      final claude = toolSummary(_call({
        'kind': 'read',
        'title': 'Read notes.txt',
        'rawInput': {'file_path': '/tmp/scratch/notes.txt'},
        'locations': [{'path': '/tmp/scratch/notes.txt', 'line': 1}],
      }));
      expect((claude.kind, claude.text, claude.hint), (ToolKind.read, 'notes.txt', 'tmp/scratch'));
      expect(claude.plain, 'notes.txt (tmp/scratch)');
      final omp = toolSummary(_call({'kind': 'read', 'title': 'Reading notes file', 'rawInput': {'path': 'notes.txt'}}));
      expect((omp.text, omp.hint), ('notes.txt', null));
      expect(toolSummary(_call({'kind': 'read', 'title': 'Reading config'})).text, 'Reading config');
      final vi = toolSummary(_call({'kind': 'read', 'locations': [{'path': '/dự-án/Hà Nội/tệp mới.dart'}]}));
      expect((vi.text, vi.hint), ('tệp mới.dart', 'dự-án/Hà Nội'));
      final win = toolSummary(_call({'kind': 'read', 'rawInput': {'path': r'C:\proj\lib\a.dart'}}));
      expect((win.text, win.hint), ('a.dart', 'proj/lib'));
    });

    test('edit: file name and +added −removed', () {
      final s = toolSummary(_call({
        'kind': 'edit',
        'title': 'Edit parse.dart',
        'status': 'completed',
        'content': [_diff('/w/lib/parse.dart', 'a\nb\nc', 'a\nB\nc\nd')],
      }));
      expect((s.text, s.hint, s.added, s.removed, s.fileCount), ('parse.dart', 'w/lib', 2, 1, 1));
      expect(s.plain, 'parse.dart · +2 \u22121');
      final created = toolSummary(_call({'kind': 'edit', 'content': [_diff('/w/x.dart', null, '1\n2\n3\n')]}));
      expect((created.added, created.removed), (3, 0));
      expect(created.plain, 'x.dart · +3');
      final many = toolSummary(_call({
        'kind': 'edit',
        'title': 'Editing files',
        'content': [_diff('/w/a.dart', 'x', 'y'), _diff('/w/b.dart', 'x', 'y\nz')],
      }));
      expect((many.text, many.fileCount, many.added, many.removed), ('a.dart', 2, 3, 2));
      final pending = toolSummary(_call({'kind': 'edit', 'title': 'Edit', 'rawInput': {'file_path': '/w/lib/c.dart'}}));
      expect((pending.text, pending.added, pending.removed), ('c.dart', null, null));
      final nothing = toolSummary(_call({'kind': 'edit', 'content': [_diff('/w/d.dart', 'same', 'same')]}));
      expect((nothing.text, nothing.added, nothing.removed), ('d.dart', null, null));
    });

    test('delete and move', () {
      expect(toolSummary(_call({'kind': 'delete', 'locations': [{'path': '/w/old.txt'}]})).text, 'old.txt');
      expect(toolSummary(_call({'kind': 'move', 'title': 'Move a.dart to b.dart'})).text, 'Move a.dart to b.dart');
    });

    test('execute: the command, wherever the agent put it', () {
      expect(toolSummary(_call({'kind': 'execute', 'title': 'echo hello', 'rawInput': {'command': 'echo hello', 'description': 'Echo'}})).text, 'echo hello');
      expect(toolSummary(_call({'kind': 'execute', 'title': r'$ echo hi', 'rawInput': {'command': 'echo hi'}})).text, 'echo hi');
      expect(toolSummary(_call({'kind': 'execute', 'title': r'$ mkdir x'})).text, 'mkdir x', reason: r'omp titles come as "$ cmd"');
      expect(toolSummary(_call({'kind': 'execute', 'title': 'Terminal'})).text, 'Terminal', reason: 'Claude before its input arrives');
      expect(toolSummary(_call({'kind': 'execute', 'rawInput': {'command': ['ls', '-la']}})).text, 'ls -la');
      expect(toolSummary(_call({'kind': 'execute', 'rawInput': {'command': "/usr/bin/zsh -lc 'cat notes.txt'"}})).text, 'cat notes.txt');
      expect(toolSummary(_call({'kind': 'execute', 'rawInput': {'command': 'bash -c "ls -la"'}})).text, 'ls -la');
      final script = toolSummary(_call({'kind': 'execute', 'rawInput': {'command': 'set -e\nflutter test\necho done'}}));
      expect((script.text, script.extraLines), ('set -e', 2));
    });

    test('execute: the last output line and the exit code only on failure', () {
      Map<String, Object?> meta(int code, String out, {String? signal}) => {
        '_meta': {
          'terminal_output_delta': {'data': out, 'terminal_id': 'x'},
          'terminal_exit': {'exit_code': code, 'signal': signal, 'terminal_id': 'x'},
        },
      };
      final ok = toolSummary(_call({'kind': 'execute', 'status': 'completed', 'rawInput': {'command': 'dart test'}, ...meta(0, 'all fine\n')}));
      expect((ok.failure, ok.exitCode, ok.signal), (null, null, null));
      final failed = toolSummary(_call({'kind': 'execute', 'status': 'failed', 'rawInput': {'command': 'flutter test'}, ...meta(1, 'running\n1 failed\n')}));
      expect((failed.failure, failed.exitCode), ('1 failed', 1));
      expect(failed.plain, 'flutter test · exit 1 · 1 failed');
      final silent = toolSummary(_call({'kind': 'execute', 'status': 'completed', 'rawInput': {'command': 'make'}, ...meta(2, 'x\n')}));
      expect(silent.exitCode, 2, reason: 'a non-zero exit is a failure whatever the status says');
      final killed = toolSummary(_call({'kind': 'execute', 'status': 'failed', 'rawInput': {'command': 'sleep 9'}, ...meta(0, 'zzz\n', signal: 'SIGTERM')}));
      expect((killed.signal, killed.plain), ('SIGTERM', 'sleep 9 · signal SIGTERM · zzz'));
      final colour = toolSummary(_call({'kind': 'execute', 'status': 'failed', 'rawInput': {'command': 'x'}, ...meta(1, '\x1B[31merror: boom\x1B[0m\n')}));
      expect(colour.failure, 'error: boom');
      // Claude: the code is in the text, the output in rawOutput.
      final claude = toolSummary(_call({
        'kind': 'execute',
        'status': 'failed',
        'rawInput': {'command': 'foo'},
        'rawOutput': 'Exit code 2\nsh: foo: command not found',
      }));
      expect((claude.exitCode, claude.failure), (2, 'sh: foo: command not found'));
      // omp: a "Wall time" footer is not output.
      final omp = toolSummary(_call({
        'kind': 'execute',
        'status': 'failed',
        'rawInput': {'command': 'x'},
        'rawOutput': {
          'content': [{'type': 'text', 'text': 'oops\n\n\nWall time: 0.02 seconds'}],
        },
      }));
      expect(omp.failure, 'oops');
      final fenced = toolSummary(_call({
        'kind': 'execute',
        'status': 'failed',
        'rawInput': {'command': 'x'},
        'content': [{'type': 'content', 'content': {'type': 'text', 'text': '```console\nboom\n```'}}],
      }));
      expect(fenced.failure, 'boom');
      expect(toolSummary(_call({'kind': 'execute', 'status': 'in_progress', 'rawInput': {'command': 'x'}})).failure, isNull);
    });

    test('search: the pattern and the hit count the output states', () {
      final counted = toolSummary(_call({
        'kind': 'search',
        'rawInput': {'pattern': 'TODO', 'path': 'lib'},
        'rawOutput': {'totalMatches': 7},
      }));
      expect((counted.text, counted.hits, counted.plain), ('TODO', 7, 'TODO · 7 matches'));
      expect(toolSummary(_call({'kind': 'search', 'rawInput': {'query': 'x'}, 'rawOutput': {'matches': [1, 2, 3]}})).hits, 3);
      expect(toolSummary(_call({'kind': 'search', 'rawInput': {'pattern': 'x'}, 'rawOutput': 'Found 3 files\nlib/a.dart\nlib/b.dart'})).hits, 3);
      expect(toolSummary(_call({'kind': 'search', 'rawInput': {'pattern': 'x'}, 'rawOutput': 'No matches found'})).hits, 0);
      expect(toolSummary(_call({'kind': 'search', 'rawInput': {'pattern': 'x'}, 'rawOutput': 'lib/a.dart:1\nlib/b.dart:2'})).hits, isNull,
          reason: 'a count is never guessed from the size of the text');
      expect(toolSummary(_call({'kind': 'search', 'rawInput': {'pattern': 'x'}})).hits, isNull);
      expect(toolSummary(_call({'kind': 'search', 'title': 'Searching the code'})).text, 'Searching the code');
      expect(toolSummary(_call({'kind': 'search', 'rawInput': {'pattern': 'a\nb'}})).text, 'a');
    });

    test('fetch: the host', () {
      expect(toolSummary(_call({'kind': 'fetch', 'rawInput': {'url': 'https://docs.flutter.dev/ui/layout?x=1'}})).text, 'docs.flutter.dev');
      expect(toolSummary(_call({'kind': 'fetch', 'rawInput': {'url': 'example.com/path'}})).text, 'example.com');
      expect(toolSummary(_call({'kind': 'fetch', 'rawInput': {'urls': ['https://a.test/x']}})).text, 'a.test');
      expect(toolSummary(_call({'kind': 'fetch', 'title': 'Fetch page'})).text, 'Fetch page');
    });

    test('think, other and switch mode: the title; never raw JSON; ANSI stripped', () {
      expect(toolSummary(_call({'kind': 'think', 'title': 'Guardian Review'})).text, 'Guardian Review');
      expect(toolSummary(_call({'kind': 'other', 'title': '\x1B[1mBold tool\x1B[0m\nsecond line'})).text, 'Bold tool');
      expect(toolSummary(_call({'kind': 'switch_mode', 'title': 'Switch to plan'})).text, 'Switch to plan');
      expect(toolSummary(_call({'kind': 'other', 'title': '{"a":1}', 'name': 'exec_command'})).text, 'exec_command');
      expect(toolSummary(_call({'kind': 'other', 'title': '[1, 2]'})).text, 'Tool call');
      expect(toolSummary(_call({'kind': 'think'})).text, 'Think');
      final long = toolSummary(_call({'kind': 'other', 'title': 'x' * 1000})).text;
      expect(long.characters.length, lessThanOrEqualTo(240));
      expect(long, endsWith('…'));
    });

    test('is memoized per call object', () {
      final c = _call({'kind': 'read', 'rawInput': {'path': 'a'}});
      expect(identical(toolSummary(c), toolSummary(c)), isTrue);
    });

    test('summaries of the recorded calls', () {
      String text(String agent, String scenario, String id) {
        final call = _allCalls(stateOfTrace(agent, scenario)).firstWhere((c) => c.toolCallId.startsWith(id));
        return toolSummary(call).plain;
      }

      expect(text('claude', 'tools', 'toolu_01Bz'), 'notes.txt (tmp/scratch)');
      expect(text('claude', 'tools', 'toolu_01FH'), 'echo hello-from-scratch');
      expect(text('omp', 'tools', 'toolu_01Jd'), 'notes.txt (tmp/scratch)');
      expect(text('omp', 'tools', 'toolu_012o'), 'echo hello-from-scratch');
      expect(text('codex', 'tools', 'exec-495d'), 'cat notes.txt');
      expect(text('codex', 'tools', 'exec-c053'), 'echo hello-from-scratch');
      expect(text('codex', 'tools', 'guardian_assessment:4ce9'), 'Guardian Review');
      expect(text('claude', 'subagent', 'toolu_01Up'), 'Run ls command and report filenames');
      expect(text('claude', 'subagent', 'toolu_01P8'), 'ToolSearch');
      expect(text('claude', 'subagent', 'toolu_017D'), 'ls -1 /tmp/scratch');
      expect(text('omp', 'plan', 'toolu_01A8'), 'Planning verbose flag');
      expect(text('omp', 'ask', 'toolu_01FK'), 'Asking colour preference');
    });

    test('every recorded call has a plain, non-empty, non-JSON summary', () {
      var seen = 0;
      for (final (agent, scenario) in _scenarios()) {
        for (final call in _allCalls(stateOfTrace(agent, scenario))) {
          final s = toolSummary(call);
          seen++;
          expect(s.text.trim(), isNotEmpty, reason: '$agent/$scenario ${call.toolCallId}');
          expect(s.plain, isNot(startsWith('{')), reason: '$agent/$scenario ${call.toolCallId}');
          expect(s.plain, isNot(startsWith('[')), reason: '$agent/$scenario ${call.toolCallId}');
          expect(s.plain, isNot(contains('\x1B')));
        }
      }
      expect(seen, greaterThan(10));
    });
  });

  group('groupTools', () {
    TranscriptTool tool(String id, String kind, String status, {String? path}) => TranscriptTool(
      _call({'toolCallId': id, 'kind': kind, 'status': status, if (path != null) 'rawInput': {'path': path}}),
    );

    test('adjacent completed reads and searches collapse; nothing else joins', () {
      final groups = groupTools([
        tool('1', 'read', 'completed', path: 'a'),
        tool('2', 'read', 'completed', path: 'b'),
        tool('3', 'search', 'completed'),
        tool('4', 'execute', 'completed'),
        tool('5', 'read', 'completed', path: 'c'),
        tool('6', 'read', 'failed', path: 'd'),
        tool('7', 'read', 'completed', path: 'e'),
        tool('8', 'read', 'in_progress', path: 'f'),
        tool('9', 'read', 'completed', path: 'g'),
        tool('10', 'search', 'cancelled'),
        tool('11', 'read', 'pending', path: 'h'),
        tool('12', 'search', 'completed'),
        tool('13', 'search', 'completed'),
        tool('14', 'search', 'completed'),
      ]);
      expect(groups.map((g) => g.tools.map((t) => t.call.toolCallId).join('+')), [
        '1+2+3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
        '10',
        '11',
        '12+13+14',
      ]);
      expect(groups.first.isGroup, isTrue);
      expect((groups.first.reads, groups.first.searches), (2, 1));
      expect(groups.first.label, 'Read 2 files · searched once');
      expect(groups[1].isGroup, isFalse);
      expect(groups[1].label, isNull);
      expect(groups.last.label, 'Searched 3\u00d7');
      expect(groups.first.key, 'tool:1');
      // No call is lost or duplicated.
      expect(groups.expand((g) => g.tools).length, 14);
    });

    test('a failed, running, cancelled or pending call never sits inside a group', () {
      for (final status in ['failed', 'in_progress', 'cancelled', 'pending']) {
        final groups = groupTools([
          tool('a', 'read', 'completed', path: 'a'),
          tool('b', 'read', status, path: 'b'),
          tool('c', 'read', 'completed', path: 'c'),
          tool('d', 'read', 'completed', path: 'd'),
        ]);
        expect(groups.map((g) => g.tools.length), [1, 1, 2], reason: status);
        expect(groups[1].tools.single.call.status, isNot(ToolStatus.completed));
        for (final g in groups) {
          if (g.isGroup) expect(g.tools.every((t) => t.call.status == ToolStatus.completed), isTrue);
        }
      }
    });

    test('the same file read twice is one file', () {
      final g = groupTools([
        tool('1', 'read', 'completed', path: 'a'),
        tool('2', 'read', 'completed', path: 'a'),
        tool('3', 'read', 'completed'),
        tool('4', 'read', 'completed'),
      ]).single;
      expect(g.reads, 3, reason: 'a, and two reads of an unknown file');
      expect(g.label, 'Read 3 files');
    });

    test('labels', () {
      expect(groupLabel(reads: 1, searches: 0), 'Read 1 file');
      expect(groupLabel(reads: 0, searches: 2), 'Searched 2\u00d7');
      expect(groupLabel(reads: 3, searches: 2), 'Read 3 files · searched 2\u00d7');
      expect(groupLabel(reads: 0, searches: 0), '');
    });

    test('empty list, empty groups', () => expect(groupTools(const []), isEmpty));
  });

  group('turnsOf', () {
    test('a turn per user message; activity before the first one is a turn with no user', () {
      var s = const AgentSessionState('s');
      s = s.apply(_u(_tool('bg', 'completed')), at: _at(1));
      s = s.apply(_u(_agentText('background done', id: 'x')), at: _at(2));
      s = s.withUserMessage([const TextBlock('first')], at: _at(3)).withTurnStarted();
      s = s.apply(_u(_agentText('one', id: 'a')), at: _at(4)).withTurnEnded(StopReason.endTurn, at: _at(5));
      s = s.withUserMessage([const TextBlock('second')], at: _at(6)).withTurnStarted();
      s = s.apply(_u(_agentText('two', id: 'b')), at: _at(7)).withTurnEnded(StopReason.endTurn, at: _at(8));
      final turns = turnsOf(s.items);
      expect(turns, hasLength(3));
      expect(turns[0].user, isNull);
      expect(turns[0].tools.single.call.toolCallId, 'bg');
      expect(turns[0].answer?.text, 'background done');
      expect(turns[0].key, startsWith('turn:'));
      expect(turns[1].user?.text, 'first');
      expect(turns[1].answer?.text, 'one');
      expect(turns[2].user?.text, 'second');
      expect(turns[2].answer?.text, 'two');
      expect(turns.map((t) => t.key).toSet(), hasLength(3));
      expect(turns.every((t) => t.ended), isTrue);
    });

    test('empty transcript, empty list', () {
      expect(turnsOf(const []), isEmpty);
      expect(turnsOf(const [], live: true), isEmpty);
    });

    test('the answer is the agent message after the last tool call or thought', () {
      // Narration, then a tool: no answer yet.
      final r = _Run()
        ..add(_agentText('I will read the file', id: 'n'))
        ..add(_tool('t1', 'in_progress', kind: 'read'));
      expect(r.turn.answer, isNull, reason: 'only narration exists');
      expect(r.turn.narration.single.text, 'I will read the file');
      expect(r.turn.live, isTrue);
      // The tool ends, the agent talks: that is the answer, the first message folds.
      r
        ..add({'sessionUpdate': 'tool_call_update', 'toolCallId': 't1', 'status': 'completed'})
        ..add(_agentText('Here is what it says', id: 'f'));
      expect(r.turn.answer?.text, 'Here is what it says');
      expect(r.turn.narration.single.text, 'I will read the file');
      // Another tool: the answer was narration after all.
      r.add(_tool('t2', 'in_progress'));
      expect(r.turn.answer, isNull);
      expect(r.turn.narration.map((m) => m.text), ['I will read the file', 'Here is what it says']);
    });

    test('a plain chat reply is the answer at once and there is no work log', () {
      final r = _Run('hi')..add(_agentText('Hello'));
      expect(r.turn.answer?.text, 'Hello');
      expect(r.turn.hasWork, isFalse);
      expect(r.turn.live, isTrue);
    });

    test('a thought as the last item means no answer; thoughts are work', () {
      final r = _Run()..add(_agentText('part', id: 'a'))..add(_thought('hmm'));
      expect(r.turn.answer, isNull);
      expect(r.turn.thoughts.single.text, 'hmm');
      expect(r.turn.work.map((i) => i.key), [r.state.items[1].key, r.state.items[2].key]);
    });

    test('empty messages are nothing; stop rows and notes do not take the answer away', () {
      final r = _Run()
        ..add(_agentText('No.', id: 'a'))
        ..add(_tool('t', 'completed'))
        ..add(_agentText('  \n', id: 'blank'))
        ..add(_agentText('Final', id: 'f'));
      r.end(StopReason.refusal);
      final turn = r.turn;
      expect(turn.answer?.text, 'Final');
      expect(turn.narration.map((m) => m.text), ['No.']);
      expect(turn.stops, hasLength(1));
      expect(turn.items.last, isA<TranscriptStop>());
      expect(turn.work.every((i) => i is TranscriptTool || i is TranscriptMessage), isTrue);
    });

    test('notes belong to the turn and are not work', () {
      var s = AgentSessionState('s').withSetup(AcpSessionSetup.parse(_modes));
      s = s.withUserMessage([const TextBlock('go')], at: _at(0)).withTurnStarted();
      s = s.apply(_u({'sessionUpdate': 'current_mode_update', 'currentModeId': 'plan'}), at: _at(1));
      s = s.apply(_u(_agentText('ok')), at: _at(2));
      final turn = turnsOf(s.items).single;
      expect(turn.notes.single.text, 'Mode changed to Plan');
      expect(turn.work, isEmpty);
      expect(turn.answer?.text, 'ok');
    });

    test('counts by kind and failed, cancelled, unfinished', () {
      final r = _Run()
        ..add(_tool('r1', 'completed', kind: 'read'))
        ..add(_tool('r2', 'completed', kind: 'read'))
        ..add(_tool('x1', 'completed', kind: 'execute'))
        ..add(_tool('x2', 'failed', kind: 'execute'))
        ..add({
          ..._tool('x3', 'completed', kind: 'execute'),
          '_meta': {'terminal_exit': {'exit_code': 2}},
        })
        ..add(_tool('s1', 'cancelled', kind: 'search'))
        ..add(_tool('t1', 'in_progress', kind: 'think'))
        ..add(_tool('t2', 'pending', kind: 'other'));
      final t = r.turn;
      expect(t.toolCounts, {ToolKind.read: 2, ToolKind.execute: 3, ToolKind.search: 1, ToolKind.think: 1, ToolKind.other: 1});
      expect(t.failedCount, 2, reason: 'a failed status, and a command that exited with 2');
      expect(t.cancelledCount, 1);
      expect(t.unfinishedCount, 2);
      expect(t.commands.map((c) => (c.tool.call.toolCallId, c.exitCode, c.failed)), [
        ('x1', null, false),
        ('x2', null, true),
        ('x3', 2, true),
      ]);
    });

    test('what breaks out of the fold: failed, cancelled, waiting calls and stop rows', () {
      final r = _Run()
        ..add(_tool('ok', 'completed', kind: 'read'))
        ..add(_tool('bad', 'failed'))
        ..add(_tool('cut', 'cancelled'))
        ..add(_tool('wait', 'pending'))
        ..add(_tool('run', 'in_progress'))
        ..add(_agentText('Sorry'));
      r.end(StopReason.maxTokens);
      final turn = r.turn;
      expect(turn.breakouts().map((i) => i.key), ['tool:bad', 'tool:cut', r.state.items.last.key]);
      expect(turn.breakouts({'wait'}).map((i) => i.key), ['tool:bad', 'tool:cut', 'tool:wait', r.state.items.last.key]);
      expect(turn.needsAttention(), isTrue);
      expect(turnsOf(const [TranscriptTool(ToolCall(toolCallId: 'a', status: ToolStatus.completed))]).single.needsAttention(), isFalse);
    });

    test('memoized by list identity; streaming into the live message costs no rebuild; unchanged turns are the same object', () {
      final r = _Run('one')
        ..add(_agentText('first '))
        ..end();
      final before = turnsOf(r.state.items);
      expect(identical(turnsOf(r.state.items), before), isTrue);
      // A second turn.
      r.state = r.state.withUserMessage([const TextBlock('two')], at: _at(20)).withTurnStarted();
      r.add(_agentText('second ', id: 'b'), after: 21);
      final afterNewTurn = turnsOf(r.state.items, live: true);
      expect(afterNewTurn, hasLength(2));
      expect(identical(afterNewTurn[0], before[0]), isTrue, reason: 'turn one did not change');
      // Streaming: same items list, same turns, the answer message grows in place.
      final items = r.state.items;
      final during = turnsOf(items, live: true);
      r.add(_agentText('more', id: 'b'));
      expect(identical(r.state.items, items), isTrue);
      expect(identical(turnsOf(r.state.items, live: true), during), isTrue);
      expect(during.last.answer?.text, 'second more');
      // A structural change keeps the old turn and rebuilds the last.
      r.add(_tool('t', 'in_progress'));
      final next = turnsOf(r.state.items, live: true);
      expect(identical(next[0], before[0]), isTrue);
      expect(identical(next[1], during[1]), isFalse);
    });

    test('live: only the last turn, and the same twin every time', () {
      final r = _Run('one')
        ..add(_agentText('a'))
        ..end();
      r.state = r.state.withUserMessage([const TextBlock('two')], at: _at(30)).withTurnStarted();
      final ended = turnsOf(r.state.items);
      final live = turnsOf(r.state.items, live: true);
      expect(ended.map((t) => t.live), [false, false]);
      expect(live.map((t) => t.live), [false, true]);
      expect(identical(live[0], ended[0]), isTrue);
      expect(live[1].ended, isFalse);
      expect(identical(turnsOf(r.state.items, live: true), live), isTrue);
      expect(identical(live[1].withLive(false), ended[1]), isTrue);
      expect(live[1].endedAt, isNull);
      expect(live[1].duration, isNull);
    });
  });

  group('turn times', () {
    test('duration runs from the user message to the last event, per-step durations from the calls', () {
      final r = _Run()
        ..add(_agentText('Looking', id: 'n'), after: 2)
        ..add(_tool('t1', 'in_progress', kind: 'read'), after: 3)
        ..add({'sessionUpdate': 'tool_call_update', 'toolCallId': 't1', 'status': 'completed'}, after: 4)
        ..add(_agentText('Done', id: 'f'), after: 1)
        ..end(StopReason.endTurn, 10);
      final t = r.turn;
      expect(t.startedAt, _at(0));
      expect(t.endedAt, _at(20), reason: 'the answer stopped growing when the turn ended');
      expect(t.duration, const Duration(seconds: 20));
      expect(t.timed, isTrue);
      expect(t.tools.single.duration, const Duration(seconds: 4));
    });

    test('a turn that is still live has a start and no end', () {
      final r = _Run()..add(_agentText('x'));
      expect(r.turn.startedAt, _at(0));
      expect(r.turn.endedAt, isNull);
      expect(r.turn.duration, isNull);
      expect(r.turn.timed, isFalse);
    });

    test('replayed history has no duration, and neither has a turn that began in it', () {
      for (final (agent, scenario) in _scenarios()) {
        final turn = turnsOf(replayOfTrace(agent, scenario).items).single;
        expect(turn.startedAt, isNull, reason: '$agent/$scenario');
        expect(turn.duration, isNull, reason: '$agent/$scenario');
        expect(turn.timed, isFalse);
        for (final tool in turn.tools) {
          expect(tool.duration, isNull);
        }
        expect(workSummaryParts(turn).first, 'Worked', reason: 'no duration part');
      }
      // Started in a replay, finished live.
      var s = AgentSessionState('s', replaying: true);
      s = s.apply(_u({'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': 'old'}}), at: _at(1));
      s = s.apply(_u(_tool('t', 'in_progress')), at: _at(2));
      s = s.withSetup(const AcpSessionSetup());
      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 't', 'status': 'completed'}), at: _at(90));
      s = s.apply(_u(_agentText('late')), at: _at(91)).withTurnEnded(StopReason.endTurn, at: _at(92));
      final mixed = turnsOf(s.items).single;
      expect(mixed.timed, isFalse, reason: 'the first part of this turn is missing');
      expect(mixed.tools.single.duration, isNull);
    });

    test('a turn after a replay is timed', () {
      var s = AgentSessionState('s', replaying: true);
      s = s.apply(_u({'sessionUpdate': 'user_message_chunk', 'content': {'type': 'text', 'text': 'old'}}), at: _at(1));
      s = s.apply(_u(_agentText('old answer')), at: _at(2)).withSetup(const AcpSessionSetup());
      s = s.withUserMessage([const TextBlock('new')], at: _at(60)).withTurnStarted();
      s = s.apply(_u(_agentText('new answer', id: 'n')), at: _at(65)).withTurnEnded(StopReason.endTurn, at: _at(70));
      final turns = turnsOf(s.items);
      expect(turns[0].timed, isFalse);
      expect(turns[1].duration, const Duration(seconds: 10));
    });
  });

  group('the recorded traces as turns', () {
    for (final (agent, scenario) in _scenarios()) {
      test('$agent/$scenario', () {
        final facts = TraceFacts(loadTrace(agent, scenario));
        final state = stateOfTrace(agent, scenario);
        final turns = turnsOf(state.items);
        expect(turns, hasLength(1));
        final turn = turns.single;
        expect(turn.user?.text, facts.promptText);
        expect(turn.ended, isTrue);

        // Nothing the agent said is lost or doubled, in order.
        final agentText = [...turn.narration, ?turn.answer].map((m) => m.text).join();
        expect(agentText, facts.textOf('agent_message_chunk'));
        expect(turn.thoughts.map((m) => m.text).join(), facts.textOf('agent_thought_chunk'));
        if (turn.answer != null) {
          expect(turn.items.where((i) => i is! TranscriptStop).last, same(turn.answer));
        }

        // Every tool call is one tool, counted once.
        final ids = <String>{};
        for (final (_, u) in facts.updates) {
          if (u is ToolCallStart) ids.add(u.call.toolCallId);
          if (u is ToolCallPatchUpdate) ids.add(u.patch.toolCallId);
        }
        final owned = {
          for (final run in state.subagents)
            for (final i in run.items)
              if (i is TranscriptTool) i.call.toolCallId,
        };
        expect(turn.tools.map((t) => t.call.toolCallId).toSet(), ids.difference(owned));
        expect(turn.toolCounts.values.fold<int>(0, (a, b) => a + b), ids.length - owned.length);
        expect(turn.unfinishedCount, 0, reason: 'the turn ended');
        expect(turn.breakouts().length, turn.failedCount + turn.cancelledCount + turn.stops.length);

        // Times: from the prompt to the last event; the answer settled when the turn ended.
        final asked = traceTime(facts.promptLine.tMs);
        final answered = traceTime(facts.answerLine.tMs);
        expect(turn.startedAt, asked);
        expect(turn.endedAt, isNotNull);
        expect(turn.duration! <= answered.difference(asked), isTrue);
        if (turn.answer != null) expect(turn.duration, answered.difference(asked));

        // Per-step durations are the recorded ones.
        final started = <String, DateTime>{};
        final finished = <String, DateTime>{};
        for (final (line, u) in facts.updates) {
          final id = switch (u) {
            ToolCallStart() => u.call.toolCallId,
            ToolCallPatchUpdate() => u.patch.toolCallId,
            _ => null,
          };
          if (id == null) continue;
          started.putIfAbsent(id, () => traceTime(line.tMs));
          final status = switch (u) {
            ToolCallStart() => u.call.status,
            ToolCallPatchUpdate() when u.patch.has('status') => ToolStatus.parse(u.patch.fields['status'] as String?),
            _ => ToolStatus.pending,
          };
          if (status.isFinished) finished.putIfAbsent(id, () => traceTime(line.tMs));
        }
        for (final tool in turn.tools) {
          final id = tool.call.toolCallId;
          expect(tool.at, started[id], reason: id);
          expect(tool.finishedAt, finished[id], reason: id);
          if (finished[id] != null) expect(tool.duration, finished[id]!.difference(started[id]!), reason: id);
        }
      });
    }

    test('claude/tools: thought, read, command, thought, answer', () {
      final turn = turnsOf(stateOfTrace('claude', 'tools').items).single;
      expect(turn.toolCounts, {ToolKind.read: 1, ToolKind.execute: 1});
      expect(turn.thoughts, hasLength(2));
      expect(turn.narration, isEmpty);
      expect(turn.answer, isNotNull);
      expect(turn.commands.single.command, 'echo hello-from-scratch');
      expect(turn.commands.single.exitCode, isNull, reason: 'Claude sends none');
      expect(turn.commands.single.failed, isFalse);
      expect(workSummaryLine(turn), 'Worked ${formatDuration(turn.duration!)} · 1 command');
      expect(groupTools(turn.tools).map((g) => g.isGroup), [false, false], reason: 'one read and one command');
    });

    test('claude/subagent: narration folds, the answer is the last message', () {
      final turn = turnsOf(stateOfTrace('claude', 'subagent').items).single;
      expect(turn.narration, hasLength(1));
      expect(turn.thoughts, hasLength(3));
      expect(turn.toolCounts, {ToolKind.other: 1, ToolKind.think: 1}, reason: 'the subagent\'s own Bash call is in its run');
      expect(turn.work.whereType<TranscriptMessage>().where((m) => m.role == MessageRole.agent), hasLength(1));
      expect(turn.answer, isNot(same(turn.narration.single)));
      expect(turn.items.indexOf(turn.narration.single), lessThan(turn.items.indexOf(turn.tools.first)));
    });

    test('codex/tools: narration, two commands with exit code 0, guardian reviews as think', () {
      final turn = turnsOf(stateOfTrace('codex', 'tools').items).single;
      expect(turn.narration, hasLength(1));
      expect(turn.toolCounts, {ToolKind.execute: 2, ToolKind.think: 2});
      expect(turn.commands.map((c) => (c.command, c.exitCode, c.failed)), [
        ('cat notes.txt', 0, false),
        ('echo hello-from-scratch', 0, false),
      ]);
      expect(workSummaryLine(turn), 'Worked ${formatDuration(turn.duration!)} · 2 commands');
    });

    test('omp/tools: a read and a command, no narration', () {
      final turn = turnsOf(stateOfTrace('omp', 'tools').items).single;
      expect(turn.toolCounts, {ToolKind.read: 1, ToolKind.execute: 1});
      expect(turn.narration, isEmpty);
      expect(turn.commands.single.command, 'echo hello-from-scratch');
      expect(workSummaryLine(turn), 'Worked ${formatDuration(turn.duration!)} · 1 command');
    });

    test('a subagent\'s call waiting on a permission is not in the turn: the dock names the subagent, the status line says it waits', () {
      final state = stateOfTrace('claude', 'subagent', stopAtPermission: true);
      expect(state.waitingToolIds, hasLength(1));
      final waiting = state.waitingToolIds.single;
      expect(waiting, startsWith('toolu_017D'), reason: 'still named, for whoever shows the request');
      final turn = turnsOf(state.items, live: state.turnActive).single;
      expect(turn.live, isTrue);
      expect(turn.tools.map((t) => t.call.toolCallId), isNot(contains(waiting)), reason: 'it sits in the subagent\'s transcript');
      expect(turn.breakouts(state.waitingToolIds), isEmpty);
      expect(state.pending.single.origin!.id, startsWith('toolu_01Up'));
      final activity = activityOf(state, now: _at(0))!;
      expect(activity.kind, ActivityKind.waiting);
      expect(activity.text, 'Waiting for you');
    });
  });

  group('workSummary', () {
    test('Worked 42s · 3 files · 4 commands · 1 failed', () {
      final r = _Run()
        ..add(_tool('e1', 'completed', kind: 'edit', content: [_diff('/w/a.dart', 'x', 'y')]), after: 2)
        ..add(_tool('e2', 'completed', kind: 'edit', content: [_diff('/w/b.dart', null, 'new')]))
        ..add(_tool('e3', 'completed', kind: 'edit', content: [_diff('/w/c.dart', 'p', 'q')]))
        ..add(_tool('c1', 'completed'))
        ..add(_tool('c2', 'completed'))
        ..add(_tool('c3', 'completed'))
        ..add(_tool('c4', 'failed'))
        ..add(_agentText('Done'), after: 20)
        ..end(StopReason.endTurn, 14);
      expect(r.turn.duration, const Duration(seconds: 42));
      expect(workSummaryLine(r.turn), 'Worked 42s \u00b7 3 files \u00b7 4 commands \u00b7 1 failed');
      expect(workSummaryParts(r.turn), ['Worked 42s', '3 files', '4 commands', '1 failed']);
    });

    test('plural rules; zero parts are omitted; cancelled has its own part', () {
      final one = _Run()
        ..add(_tool('e1', 'completed', kind: 'edit', content: [_diff('/w/a.dart', 'x', 'y')]), after: 4)
        ..add(_tool('c1', 'completed'))
        ..end();
      // Times run to the last event: the end of the last call (the end of the
      // turn itself is an event only when a message was still growing).
      expect(workSummaryLine(one.turn), 'Worked 5s \u00b7 1 file \u00b7 1 command');
      final cancelled = _Run()
        ..add(_tool('c1', 'cancelled'), after: 70)
        ..add(_tool('c2', 'cancelled'))
        ..end(StopReason.cancelled);
      expect(workSummaryLine(cancelled.turn), 'Worked 1m 11s \u00b7 2 commands \u00b7 2 cancelled');
      final reads = _Run()
        ..add(_tool('r', 'completed', kind: 'read'))
        ..end();
      expect(workSummaryLine(reads.turn), 'Worked 1s');
    });

    test('no duration when the turn is not timed or ran under a second', () {
      final untimed = AgentSessionState('s').withUserMessage([const TextBlock('go')]).apply(_u(_tool('c', 'completed')));
      expect(workSummaryLine(turnsOf(untimed.items).single), 'Worked \u00b7 1 command');
      var s = const AgentSessionState('s').withUserMessage([const TextBlock('go')], at: _at(0));
      s = s.apply(_u(_tool('c', 'completed')), at: _t0.add(const Duration(milliseconds: 400)));
      s = s.withTurnEnded(StopReason.endTurn, at: _t0.add(const Duration(milliseconds: 600)));
      expect(workSummaryLine(turnsOf(s.items).single), 'Worked \u00b7 1 command');
    });

    test('formatDuration', () {
      expect(formatDuration(Duration.zero), '0s');
      expect(formatDuration(const Duration(milliseconds: 499)), '0s');
      expect(formatDuration(const Duration(milliseconds: 1500)), '2s');
      expect(formatDuration(const Duration(seconds: 42)), '42s');
      expect(formatDuration(const Duration(seconds: 60)), '1m');
      expect(formatDuration(const Duration(seconds: 65)), '1m 5s');
      expect(formatDuration(const Duration(minutes: 59, seconds: 59)), '59m 59s');
      expect(formatDuration(const Duration(hours: 1)), '1h');
      expect(formatDuration(const Duration(hours: 1, minutes: 5, seconds: 30)), '1h 5m');
    });
  });

  group('text helpers are safe for any script', () {
    test('clip never splits a letter from its marks', () {
      for (final text in ['Tiếng Việt: Hà Nội, Đà Nẵng', 'Tie\u0302\u0301ng Vie\u0323\u0302t', '👨‍👩‍👧‍👦 family 🇻🇳 flag']) {
        final graphemes = text.characters.toList();
        for (var n = 1; n <= graphemes.length; n++) {
          final clipped = clip(text, n);
          expect(clipped.characters.length, lessThanOrEqualTo(n), reason: '$text / $n');
          if (n < graphemes.length) {
            expect(clipped, '${graphemes.take(n - 1).join()}…', reason: '$text / $n');
          } else {
            expect(clipped, text);
          }
        }
      }
    });

    test('firstSentence', () {
      expect(firstSentence('**Planning the fix**\n\nFirst I will read.'), 'Planning the fix');
      expect(firstSentence('I should check the locale file. Then edit it.'), 'I should check the locale file.');
      expect(firstSentence('# Heading\nbody'), 'Heading');
      expect(firstSentence('- `lib/a.dart` needs a change! Really.'), 'lib/a.dart needs a change!');
      expect(firstSentence('Đang đọc tệp Hà Nội. Sau đó sửa.'), 'Đang đọc tệp Hà Nội.');
      expect(firstSentence('   \n\n  '), isNull);
      expect(firstSentence('```\ncode\n```'), 'code');
      expect(firstSentence('x' * 300, max: 20)!.characters.length, 20);
    });

    test('basenameOf and dirHintOf', () {
      expect(basenameOf('/a/b/c.txt'), 'c.txt');
      expect(basenameOf('c.txt'), 'c.txt');
      expect(basenameOf('/a/b/'), 'b');
      expect(basenameOf(r'C:\a\b.txt'), 'b.txt');
      expect(dirHintOf('/a/b/c/d.txt'), 'b/c');
      expect(dirHintOf('lib/d.txt'), 'lib');
      expect(dirHintOf('d.txt'), isNull);
      expect(dirHintOf('/d.txt'), isNull);
    });
  });

  group('activityOf and quietFor', () {
    AgentSessionState running() =>
        const AgentSessionState('s').withUserMessage([const TextBlock('go')], at: _at(0)).withTurnStarted();

    test('null when no turn runs', () {
      expect(activityOf(const AgentSessionState('s'), now: _at(0)), isNull);
      final done = running().withTurnEnded(StopReason.endTurn, at: _at(3));
      expect(activityOf(done, now: _at(4)), isNull);
    });

    test('Working when nothing more is known', () {
      final a = activityOf(running(), now: _at(5))!;
      expect(a.kind, ActivityKind.working);
      expect(a.text, 'Working');
      expect(a.tool, isNull);
      expect(a.elapsed(_at(5)), isNull);
    });

    test('the latest running tool, with its summary and when it started', () {
      var s = running();
      s = s.apply(_u(_tool('r', 'completed', kind: 'read', title: 'Read a')), at: _at(1));
      s = s.apply(_u(_tool('x', 'in_progress', rawInput: {'command': 'flutter test'})), at: _at(2));
      final a = activityOf(s, now: _at(14))!;
      expect(a.kind, ActivityKind.tool);
      expect(a.text, 'flutter test');
      expect(a.tool?.kind, ToolKind.execute);
      expect(a.since, _at(2));
      expect(a.elapsed(_at(14)), const Duration(seconds: 12));
      // Claude never says in_progress: pending counts as running; the latest wins.
      s = s.apply(_u(_tool('y', 'pending', kind: 'read', rawInput: {'file_path': '/w/lib/a.dart'})), at: _at(3));
      expect(activityOf(s, now: _at(4))!.text, 'a.dart (w/lib)');
      // It ends: back to what is left.
      s = s.apply(_u({'sessionUpdate': 'tool_call_update', 'toolCallId': 'y', 'status': 'completed'}), at: _at(4));
      expect(activityOf(s, now: _at(5))!.text, 'flutter test');
    });

    test('the first sentence of the latest thought while it is the last thing', () {
      var s = running().apply(_u(_thought('**Planning the fix**\n\nFirst I will read the locale file.')), at: _at(1));
      var a = activityOf(s, now: _at(2))!;
      expect((a.kind, a.text, a.since), (ActivityKind.thought, 'Planning the fix', _at(1)));
      // Once the agent talks, the thought is stale.
      s = s.apply(_u(_agentText('Reading')), at: _at(3));
      a = activityOf(s, now: _at(4))!;
      expect((a.kind, a.text), (ActivityKind.working, 'Working'));
      // A thought after a tool, in a message that only has whitespace: nothing to say.
      var t = running().apply(_u(_tool('x', 'completed')), at: _at(1)).apply(_u(_thought('  ')), at: _at(2));
      expect(activityOf(t, now: _at(3))!.kind, ActivityKind.working);
      t = t.apply(_u(_thought('Now the tests. Then done.', id: 'th2')), at: _at(3));
      expect(activityOf(t, now: _at(4))!.text, 'Now the tests.');
    });

    test('a call that waits for the person', () {
      var s = running().apply(_u(_tool('x', 'pending', rawInput: {'command': 'rm -rf build'})), at: _at(1));
      s = s.withPending(
        PendingPermission(
          7,
          PermissionRequest(sessionId: 's', toolCall: ToolCallPatch('x', const {}), options: const []),
        ),
      );
      final a = activityOf(s, now: _at(100))!;
      expect(a.kind, ActivityKind.waiting);
      expect(a.text, 'rm -rf build');
      expect(a.quiet, isNull, reason: 'silence while waiting for you is expected');
      expect(quietFor(s, now: _at(1000)), isNull);
    });

    test('quiet after 60 s without an event, counted from the last event or from the prompt', () {
      var s = running().apply(_u(_agentText('hi')), at: _at(10));
      expect(quietFor(s, now: _at(69)), isNull);
      expect(quietFor(s, now: _at(70)), const Duration(seconds: 60));
      expect(quietFor(s, now: _at(190)), const Duration(minutes: 3));
      expect(activityOf(s, now: _at(190))!.quiet, const Duration(minutes: 3));
      expect(activityOf(s, now: _at(20))!.quiet, isNull);
      // An update of any kind counts as life.
      s = s.apply(_u({'sessionUpdate': 'usage_update', 'used': 1, 'size': 10}), at: _at(100));
      expect(quietFor(s, now: _at(150)), isNull);
      // A turn that never produced an event: from the user message.
      final fresh = const AgentSessionState('s').withUserMessage([const TextBlock('go')], at: _at(5)).withTurnStarted();
      expect(quietFor(fresh, now: _at(64)), isNull);
      expect(quietFor(fresh, now: _at(125)), const Duration(minutes: 2));
      // The new prompt starts the count over, whatever the last turn did.
      var again = running().apply(_u(_agentText('a')), at: _at(10)).withTurnEnded(StopReason.endTurn, at: _at(11));
      again = again.withUserMessage([const TextBlock('more')], at: _at(500)).withTurnStarted();
      expect(quietFor(again, now: _at(520)), isNull);
      expect(quietFor(again, now: _at(560)), const Duration(seconds: 60));
    });

    test('never when idle, disconnected, or without a clock', () {
      final idle = const AgentSessionState('s').apply(_u(_agentText('hi')), at: _at(1));
      expect(quietFor(idle, now: _at(500)), isNull);
      final down = running().apply(_u(_agentText('hi')), at: _at(1)).withDisconnected();
      expect(quietFor(down, now: _at(500)), isNull);
      final clockless = const AgentSessionState('s').withUserMessage([const TextBlock('go')]).withTurnStarted();
      expect(quietFor(clockless, now: _at(500)), isNull);
      expect(quietFor(running(), now: _at(300), threshold: const Duration(minutes: 10)), isNull);
    });
  });
}

const _modes = <String, Object?>{
  'modes': {
    'currentModeId': 'default',
    'availableModes': [
      {'id': 'default', 'name': 'Default'},
      {'id': 'plan', 'name': 'Plan'},
    ],
  },
};

/// Every recorded trace as (agent, scenario).
List<(String, String)> _scenarios() {
  final out = <(String, String)>[];
  for (final dir in Directory('test/fixtures/traces').listSync().whereType<Directory>()) {
    final agent = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    for (final f in dir.listSync().whereType<File>().where((f) => f.path.endsWith('.jsonl'))) {
      out.add((agent, f.uri.pathSegments.last.replaceAll('.jsonl', '')));
    }
  }
  out.sort((a, b) => '${a.$1}/${a.$2}'.compareTo('${b.$1}/${b.$2}'));
  return out;
}

/// The textbook answer: the longest common subsequence by dynamic programming.
LineStats _referenceStats(List<String> a, List<String> b) {
  final dp = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      dp[i][j] = a[i - 1] == b[j - 1] ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1]);
    }
  }
  final lcs = dp[a.length][b.length];
  return LineStats(b.length - lcs, a.length - lcs);
}
