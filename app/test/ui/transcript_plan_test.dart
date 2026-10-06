import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/markdown/markdown.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_plan.dart';

import '../support/fake_agent_session.dart';

/// The rows of a transcript are planned from the first turn that changed; the
/// plan must be the one a full pass over the items gives. The shape of a turn
/// (user, log, card, answer, exceptions) is pinned here.
void main() {
  bool sameRow(PlanRow a, PlanRow b) =>
      a.key == b.key &&
      a.kind == b.kind &&
      a.gap == b.gap &&
      identical(a.item, b.item) &&
      identical(a.turn, b.turn) &&
      a.live == b.live &&
      a.quiet == b.quiet &&
      a.nested == b.nested &&
      a.first == b.first &&
      a.last == b.last &&
      a.count == b.count &&
      a.label == b.label &&
      a.firstBlock == b.firstBlock &&
      _same(a.part, b.part) &&
      _same(a.before, b.before);

  void expectSamePlan(TranscriptPlan got, TranscriptPlan want, String reason) {
    expect(got.rows.map((r) => r.key).toList(), want.rows.map((r) => r.key).toList(), reason: reason);
    for (var i = 0; i < want.rows.length; i++) {
      expect(sameRow(got.rows[i], want.rows[i]), isTrue, reason: '$reason: row ${want.rows[i].key}');
    }
    expect(got.index, want.index, reason: reason);
    expect(got.liveRow, want.liveRow, reason: reason);
  }

  // Turn keys are `turn:<user key>`; the tests read them without the prefix.
  List<String> keys(TranscriptPlan p) => p.rows.map((r) => r.key.replaceFirst('turn:', '')).toList();
  List<RowKind> kinds(TranscriptPlan p) => p.rows.map((r) => r.kind).toList();

  TranscriptTool edit(String id, String path, {String? old, String text = 'new'}) => toolItem(
    id,
    title: 'Edit',
    kind: ToolKind.edit,
    content: [ToolDiff(path: path, oldText: old ?? 'old', newText: text)],
  );

  TranscriptTool read(String id, String path) => toolItem(
    id,
    title: 'Read',
    kind: ToolKind.read,
    rawInput: {'file_path': path},
  );

  TranscriptTool failedRun(String id) => toolItem(id, title: 'flutter test', kind: ToolKind.execute, status: ToolStatus.failed);

  group('the plan of a turn', () {
    test('planned in steps it is the plan of a full pass, after every event of every recorded turn', () {
      final root = Directory('test/fixtures/traces');
      final files = root.existsSync()
          ? (root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.jsonl')).toList()
              ..sort((a, b) => a.path.compareTo(b.path)))
          : <File>[];
      expect(files, isNotEmpty);
      for (final file in files) {
        final name = file.uri.pathSegments.sublist(file.uri.pathSegments.length - 2).join('/');
        var state = const AgentSessionState('s');
        final plan = TranscriptPlan();
        var step = 0;
        for (final event in _events(file)) {
          step++;
          switch (event) {
            case SessionUpdate():
              state = state.apply(event);
            case String():
              state = state.withUserMessage([TextBlock(event)]).withTurnStarted();
            case StopReason():
              state = state.withTurnEnded(event);
          }
          plan.update(state.items, live: state.turnActive);
          expectSamePlan(plan, TranscriptPlan()..update(state.items, live: state.turnActive), '$name step $step');
        }
      }
    });

    test('a finished turn: the message, the folded log, the Changed card, the answer', () {
      final plan = TranscriptPlan()
        ..update([
          userMsg('u', 'fix it'),
          thoughtMsg('th', 'weighing'),
          agentMsg('n', 'I will look at the parser.'),
          read('r1', '/a/lib/parse.dart'),
          edit('e1', '/a/lib/parse.dart'),
          agentMsg('a', 'Done: the parser normalizes first.'),
        ]);
      expect(kinds(plan), [
        RowKind.user,
        RowKind.fold,
        RowKind.changedHead,
        RowKind.changedFile,
        RowKind.text,
      ]);
      expect(keys(plan), ['u', 'u:log', 'u:changed', 'u:changed:/a/lib/parse.dart', 'a#0']);
      expect(plan.rows.last.quiet, isFalse, reason: 'the answer');
      expect(plan.rows[3].last, isTrue, reason: 'the card ends with its only file');
      expect(plan.rows[2].first, isTrue);
    });

    test('a turn with no work and no files is the message and the answer', () {
      final plan = TranscriptPlan()..update([userMsg('u', 'hi'), agentMsg('a', 'Hello.')]);
      expect(kinds(plan), [RowKind.user, RowKind.text]);
    });

    test('a turn with no user message (autonomous, or after a replay) has no user row', () {
      final plan = TranscriptPlan()..update([read('r', '/a/b.dart'), agentMsg('a', 'Found it.')]);
      expect(kinds(plan), [RowKind.fold, RowKind.text]);
      expect(plan.rows.first.gap, 0);
    });

    test('the running turn shows its log open, no fold line, no card', () {
      final plan = TranscriptPlan()
        ..update([
          userMsg('u', 'go'),
          edit('e1', '/a/x.dart'),
          toolItem('t2', title: 'dart test', kind: ToolKind.execute, status: ToolStatus.inProgress),
        ], live: true);
      expect(kinds(plan), [RowKind.user, RowKind.tool, RowKind.tool]);
      expect(plan.rows.where((r) => r.kind == RowKind.fold), isEmpty);
      expect(plan.rows.where((r) => r.kind == RowKind.changedHead), isEmpty);
    });

    test('the log opens and folds with its toggle, and only that turn is planned again', () {
      final open = <String>{};
      final items = <TranscriptItem>[
        userMsg('u0', 'first'),
        read('r0', '/a/x.dart'),
        agentMsg('a0', 'First answer.'),
        userMsg('u1', 'second'),
        read('r1', '/a/y.dart'),
        toolItem('c1', title: 'ls', kind: ToolKind.execute),
        agentMsg('a1', 'Second answer.'),
      ];
      final plan = TranscriptPlan(open: open)..update(items);
      expect(keys(plan), ['u0', 'u0:log', 'a0#0', 'u1', 'u1:log', 'a1#0']);
      final planned = plan.plannedTurns;

      open.add('turn:u1:log');
      plan.refresh('turn:u1:log');
      plan.update(items);
      expect(keys(plan), ['u0', 'u0:log', 'a0#0', 'u1', 'u1:log', 'tool:r1', 'tool:c1', 'a1#0']);
      expect(plan.plannedTurns, planned + 1, reason: 'the first turn kept its rows');
      expect(plan.rows[4].open, isTrue);

      open.remove('turn:u1:log');
      plan.refresh('turn:u1:log');
      plan.update(items);
      expect(keys(plan), ['u0', 'u0:log', 'a0#0', 'u1', 'u1:log', 'a1#0']);
    });

    test('exceptions break out of the fold: failed, cancelled, waiting calls, stops and notes stay visible', () {
      final items = <TranscriptItem>[
        userMsg('u', 'go'),
        read('ok', '/a/x.dart'),
        failedRun('bad'),
        toolItem('cut', title: 'sleep', kind: ToolKind.execute, status: ToolStatus.cancelled),
        toolItem('ask', title: 'rm -rf build', kind: ToolKind.execute, status: ToolStatus.pending),
        const TranscriptStop(key: 'stop', reason: StopReason.maxTokens),
        const TranscriptNote(key: 'note', text: 'Mode changed to Plan'),
      ];
      final plan = TranscriptPlan()..update(items, waiting: {'ask'});
      expect(keys(plan), ['u', 'u:log', 'tool:bad', 'tool:cut', 'tool:ask', 'stop', 'note']);
      expect(keys(plan), isNot(contains('tool:ok')), reason: 'a call that went well folds');

      // The plan with no permission waiting does not show the pending call.
      final calm = TranscriptPlan()..update(items);
      expect(keys(calm), ['u', 'u:log', 'tool:bad', 'tool:cut', 'stop', 'note']);

      // A call that starts waiting re-plans its turn.
      calm.update(items, waiting: {'ask'});
      expect(keys(calm), keys(plan));
      calm.update(items);
      expect(keys(calm), ['u', 'u:log', 'tool:bad', 'tool:cut', 'stop', 'note']);
    });

    test('an open log shows the exceptions in their place, once', () {
      final open = {'turn:u:log'};
      final plan = TranscriptPlan(open: open)
        ..update([userMsg('u', 'go'), read('ok', '/a/x.dart'), failedRun('bad'), agentMsg('a', 'It failed.')]);
      expect(keys(plan), ['u', 'u:log', 'tool:ok', 'tool:bad', 'a#0']);
    });

    test('adjacent reads and searches that went well are one group row; open, its calls follow', () {
      final open = <String>{};
      final items = <TranscriptItem>[
        userMsg('u', 'go'),
        read('r1', '/a/x.dart'),
        read('r2', '/a/y.dart'),
        toolItem('s1', title: 'grep', kind: ToolKind.search, rawInput: {'pattern': 'foo'}),
        failedRun('bad'),
        read('r3', '/a/z.dart'),
        agentMsg('a', 'ok'),
      ];
      open.add('turn:u:log');
      final plan = TranscriptPlan(open: open)..update(items);
      expect(keys(plan), ['u', 'u:log', 'tool:r1:group', 'tool:bad', 'tool:r3', 'a#0']);
      final group = plan.rows[2];
      expect(group.kind, RowKind.group);
      expect(group.group!.label, 'Read 2 files \u00b7 searched once');

      open.add('tool:r1:group');
      plan.refresh('tool:r1:group');
      plan.update(items);
      expect(keys(plan), ['u', 'u:log', 'tool:r1:group', 'tool:r1', 'tool:r2', 'tool:s1', 'tool:bad', 'tool:r3', 'a#0']);
      expect(plan.rows[3].nested, isTrue);
    });

    test('thoughts have no row of their own: one Thinking line per stretch of the log', () {
      final open = {'turn:u:log'};
      final plan = TranscriptPlan(open: open)
        ..update([
          userMsg('u', 'go'),
          read('r1', '/a/x.dart'),
          thoughtMsg('th1', 'first'),
          toolItem('c1', title: 'ls', kind: ToolKind.execute),
          thoughtMsg('th2', 'second'),
          agentMsg('n', 'Now the test.'),
          thoughtMsg('th3', 'third'),
          toolItem('c2', title: 'dart test', kind: ToolKind.execute),
          agentMsg('a', 'Done.'),
        ]);
      expect(keys(plan), ['u', 'u:log', 'th1', 'tool:r1', 'tool:c1', 'n#0', 'th3', 'tool:c2', 'a#0']);
      expect(plan.rows[2].thoughts.map((t) => t.key), ['th1', 'th2']);
      expect(plan.rows[5].quiet, isTrue, reason: 'narration');
      expect(plan.rows.last.quiet, isFalse, reason: 'the answer');
    });

    test('the Changed card lists six files and says how many more; all of them on demand', () {
      final open = <String>{};
      final items = <TranscriptItem>[
        userMsg('u', 'go'),
        for (var i = 0; i < 10; i++) edit('e$i', '/a/f$i.dart'),
        agentMsg('a', 'Done.'),
      ];
      final plan = TranscriptPlan(open: open)..update(items);
      expect(plan.rows.where((r) => r.kind == RowKind.changedFile), hasLength(6));
      final more = plan.rows.firstWhere((r) => r.kind == RowKind.changedMore);
      expect(more.count, 4);
      expect(more.last, isTrue);
      expect(plan.rows.where((r) => r.last), hasLength(1), reason: 'one bottom edge');

      open.add('turn:u:changed:all');
      plan.refresh('turn:u:changed:all');
      plan.update(items);
      expect(plan.rows.where((r) => r.kind == RowKind.changedFile), hasLength(10));
      expect(plan.rows.firstWhere((r) => r.kind == RowKind.changedMore).open, isTrue, reason: 'Show fewer');

      // Six files fit: no more row, the sixth file ends the card.
      final six = TranscriptPlan()
        ..update([userMsg('u', 'go'), for (var i = 0; i < 6; i++) edit('e$i', '/a/f$i.dart'), agentMsg('a', 'Done.')]);
      expect(six.rows.where((r) => r.kind == RowKind.changedMore), isEmpty);
      expect(six.rows.where((r) => r.kind == RowKind.changedFile).last.last, isTrue);
    });

    test('a failed edit changes nothing: no card', () {
      final plan = TranscriptPlan()
        ..update([
          userMsg('u', 'go'),
          toolItem('e', kind: ToolKind.edit, status: ToolStatus.failed, content: const [ToolDiff(path: '/a/x', newText: 'x')]),
          agentMsg('a', 'Failed.'),
        ]);
      expect(plan.rows.where((r) => r.kind == RowKind.changedHead), isEmpty);
    });

    test('only the turns from the first changed one are planned again', () {
      final items = <TranscriptItem>[
        for (var i = 0; i < 300; i++) ...[userMsg('u$i', 'q$i'), read('r$i', '/a/f.dart'), agentMsg('a$i', 'answer $i')],
      ];
      final plan = TranscriptPlan()..update(items);
      expect(plan.plannedTurns, 300);

      final gone = plan.update([...items, userMsg('uN', 'next'), toolItem('t', title: 'Run')], live: true);
      expect(plan.plannedTurns, 301, reason: 'one turn is new');
      expect(gone, isEmpty);

      final changed = [...items]..[602] = agentMsg('a200', 'changed\n\nin two');
      final removed = plan.update(changed);
      expect(plan.plannedTurns, 301 + 100, reason: 'turns 200..299 follow the first change');
      expect(removed, containsAll(['uN', 'tool:t']));
      expect(plan.index['a200#1'], isNotNull);
    });

    test('an unchanged list plans nothing', () {
      final items = [for (var i = 0; i < 20; i++) userMsg('u$i', 'x')];
      final plan = TranscriptPlan()..update(items);
      final before = plan.plannedTurns;
      expect(plan.update(items), isEmpty);
      expect(plan.plannedTurns, before);
    });

    test('the live message is one row; its blocks keep their keys when it ends', () {
      const text = 'First paragraph.\n\nSecond one.\n\n- a\n- b\n\nLast words';
      var s = stateWith(items: [userMsg('u', 'go')]).apply(const MessageChunk(MessageRole.agent, 'a', TextBlock(text)));
      final key = s.liveKey!;
      final live = TranscriptPlan()..update(s.items, live: true);
      expect(keys(live), ['u', '$key#live']);
      expect(live.liveRow, 1);
      expect(live.rows.last.live, isTrue);
      expect(live.rows.last.firstBlock, 0);
      expect(live.rows.last.gap, 16, reason: 'what an answer after a prompt has');

      s = s.withTurnEnded(StopReason.endTurn);
      final settled = TranscriptPlan()..update(s.items);
      expect(settled.liveRow, -1);
      expect(keys(settled), ['u', '$key#0', '$key#1', '$key#2', '$key#3']);
      expect(settled.rows[1].gap, live.rows.last.gap, reason: 'the first block sits where the live row did');
      expect(parseMd(text).blocks, hasLength(4));
    });

    test('blocks before the live text are rows of their own, and the live row counts on from them', () {
      var s = stateWith(items: [userMsg('u', 'go')])
          .apply(const MessageChunk(MessageRole.agent, 'a', ImageBlock(data: '', mimeType: 'image/png')))
          .apply(const MessageChunk(MessageRole.agent, 'a', TextBlock('after the picture')));
      final key = s.liveKey!;
      final plan = TranscriptPlan()..update(s.items, live: true);
      expect(keys(plan), ['u', '$key#0', '$key#live']);
      expect(plan.rows[1].part, isA<ImageBlock>());
      final liveRow = plan.rows.last;
      expect(liveRow.firstBlock, 1);
      expect(liveRow.before, isA<ImageBlock>());

      s = s.withTurnEnded(StopReason.endTurn);
      final settled = TranscriptPlan()..update(s.items);
      expect(keys(settled), ['u', '$key#0', '$key#1']);
      expect(settled.rows[2].gap, 10, reason: 'a text block after a content block');
    });

    test('a message with no text has no rows, and does not push the next gap', () {
      final plan = TranscriptPlan()..update([userMsg('u', 'hi'), agentMsg('a', ''), toolItem('t', title: 'Run')], live: true);
      expect(keys(plan), ['u', 'tool:t']);
      expect(plan.rows.last.gap, 6, reason: 'measured from the prompt: the empty message made no row');
    });

    test('the answer that becomes narration (a call starts after it) keeps its key and its gap', () {
      var s = stateWith(items: [userMsg('u', 'go'), toolItem('t1', title: 'Read', kind: ToolKind.read)], turnActive: true)
          .apply(const MessageChunk(MessageRole.agent, 'a', TextBlock('I will run the tests now.')));
      final key = s.liveKey!;
      final answer = TranscriptPlan()..update(s.items, live: true);
      expect(keys(answer), ['u', 'tool:t1', '$key#live']);
      final gap = answer.rows.last.gap;

      s = s.apply(ToolCallStart(const ToolCall(toolCallId: 't2', title: 'dart test', kind: ToolKind.execute)));
      final narration = TranscriptPlan()..update(s.items, live: true);
      expect(keys(narration), ['u', 'tool:t1', '$key#0', 'tool:t2']);
      expect(narration.rows[2].quiet, isTrue);
      expect(narration.rows[2].gap, gap, reason: 'the text does not move');
    });

    test('the divider goes above the first unseen item; inside a fold, above the fold line', () {
      final items = <TranscriptItem>[
        userMsg('u0', 'old'),
        agentMsg('a0', 'old answer'),
        userMsg('u1', 'new'),
        read('r1', '/a/x.dart'),
        agentMsg('a1', 'new answer'),
      ];
      var plan = TranscriptPlan()..update(items, dividerKey: 'u1', dividerLabel: '3 new');
      expect(keys(plan), ['u0', 'a0#0', 'since-left', 'u1', 'u1:log', 'a1#0']);
      expect(plan.dividerRow, 2);
      expect(plan.rows[2].label, '3 new');

      plan = TranscriptPlan()..update(items, dividerKey: 'tool:r1');
      expect(keys(plan), ['u0', 'a0#0', 'u1', 'since-left', 'u1:log', 'a1#0'], reason: 'the call is in the fold');

      plan = TranscriptPlan()..update(items, dividerKey: 'a1');
      expect(keys(plan), ['u0', 'a0#0', 'u1', 'u1:log', 'since-left', 'a1#0']);

      plan = TranscriptPlan()..update(items, dividerKey: 'gone');
      expect(keys(plan), ['u0', 'a0#0', 'u1', 'u1:log', 'a1#0']);
      expect(plan.dividerRow, -1);
    });

    test('the divider arrives late: only its turn is planned again', () {
      final items = <TranscriptItem>[
        for (var i = 0; i < 50; i++) ...[userMsg('u$i', 'q'), agentMsg('a$i', 'answer')],
      ];
      final plan = TranscriptPlan()..update(items);
      final before = plan.plannedTurns;
      plan.update(items, dividerKey: 'u40');
      expect(plan.plannedTurns, before + 10);
      expect(plan.index['since-left'], plan.index['u40']! - 1);
    });

    test('the plan note of a turn rides on its fold row', () {
      final plan = TranscriptPlan(notes: {'turn:u': 'Plan 3 of 3 done'})
        ..update([userMsg('u', 'go'), read('r', '/a/x.dart'), agentMsg('a', 'ok')]);
      expect(plan.rows[1].label, 'Plan 3 of 3 done');
    });
  });
}

bool _same(Object? a, Object? b) {
  if (identical(a, b)) return true;
  return a is MdBlock && b is MdBlock && mdBlocksEqual(a, b);
}

/// A trace as the client sees it: the agent's updates, and what the client did
/// (the prompt it sent, the response that ended the turn).
List<Object> _events(File file) {
  final out = <Object>[];
  Object? promptId;
  for (final row in const LineSplitter().convert(file.readAsStringSync())) {
    if (row.trim().isEmpty) continue;
    final j = jsonDecode(row) as Map<String, dynamic>;
    final msg = j['msg'] as Map<String, dynamic>;
    final received = j['dir'] == 'recv';
    if (!received && msg['method'] == 'session/prompt') {
      promptId = msg['id'];
      final prompt = (msg['params'] as Map)['prompt'] as List;
      out.add(prompt.map((b) => (b as Map)['text'] ?? '').join());
    } else if (received && msg['method'] == 'session/update') {
      out.add(SessionUpdate.parse((msg['params'] as Map)['update']));
    } else if (received && promptId != null && msg['id'] == promptId && msg.containsKey('result')) {
      out.add(StopReason.parse((msg['result'] as Map)['stopReason'] as String?));
      promptId = null;
    }
  }
  return out;
}
