import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/decision/permission_evidence.dart';

import 'support/trace_session.dart';

TranscriptMessage _say(String text, {MessageRole role = MessageRole.agent, String key = 'm'}) =>
    TranscriptMessage(key: key, role: role, blocks: [TextBlock(text)]);

TranscriptTool _tool(String id) => TranscriptTool(ToolCall(toolCallId: id, title: id));

PermissionRequest _request(Json toolCall, {List<Json>? options}) => PermissionRequest.parse({
  'sessionId': 's',
  'toolCall': toolCall,
  'options': options ??
      [
        {'optionId': 'allow', 'name': 'Yes', 'kind': 'allow_once'},
        {'optionId': 'reject', 'name': 'No', 'kind': 'reject_once'},
      ],
});

String? _sentence(String text) => lastAgentSentence([_say(text)]);

void main() {
  group('real traces', () {
    test('every request in every trace gives bounded, clean evidence', () {
      var requests = 0;
      for (final name in allTraces()) {
        final run = replayTrace(name);
        for (final p in run.permissions) {
          requests++;
          final e = permissionEvidence(p.request, items: p.before.items);
          expect(e.planMarkdown, isNull, reason: name);
          expect(e.diffs, isEmpty, reason: name);
          expect(e.intent?.length ?? 0, lessThanOrEqualTo(intentCharLimit), reason: name);
        }
        // The sentence before the end of any transcript is bounded too.
        expect(lastAgentSentence(run.finalState.items)?.length ?? 0, lessThanOrEqualTo(intentCharLimit), reason: name);
      }
      expect(requests, greaterThanOrEqualTo(4), reason: 'the fixtures hold the permission requests this test reads');
    });

    test('claude/permission: a command asks, the agent had only thought: no intent', () {
      final run = replayTrace('claude/permission');
      final p = run.permissions.single;
      final e = permissionEvidence(p.request, items: p.before.items);
      expect(e.intent, isNull, reason: 'a thought is not something the agent said');
      expect(e.isEmpty, isTrue);
    });

    test('claude/subagent: the intent is the agent message before the call, past thoughts and tools', () {
      final run = replayTrace('claude/subagent');
      final p = run.permissions.single;
      final e = permissionEvidence(p.request, items: p.before.items);
      expect(e.intent, "I'll fetch the TaskCreate schema and then create a task to run ls.");
    });

    test('omp asks before its tool row exists: nothing said, no intent', () {
      for (final name in ['omp/permission', 'omp/tools']) {
        final p = replayTrace(name).permissions.single;
        expect(permissionEvidence(p.request, items: p.before.items).intent, isNull, reason: name);
      }
    });

    test('the plan scenarios hold no plan approval: the traces use the todo tool', () {
      for (final name in ['claude/plan', 'codex/plan', 'omp/plan']) {
        final run = replayTrace(name);
        expect(run.permissions, isEmpty, reason: name);
        expect(run.questions, isEmpty, reason: name);
      }
    });

    test('omp/ask is a question, not a plan approval', () {
      final q = replayTrace('omp/ask').questions.single;
      expect(planApprovalEvidence(q), isNull);
    });
  });

  group('plans', () {
    test('Claude ExitPlanMode: rawInput.plan, kind switch_mode, content text (claude-agent-acp ExitPlanModeReporter)', () {
      final e = permissionEvidence(
        _request({
          'toolCallId': 'tp',
          'title': 'Approve Plan',
          'kind': 'switch_mode',
          'rawInput': {'plan': '# Plan\n\n1. Add the flag.\n2. Wire it.'},
          'content': [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': '# Plan\n\n1. Add the flag.\n2. Wire it.'},
            },
          ],
        }),
      );
      expect(e.planMarkdown, '# Plan\n\n1. Add the flag.\n2. Wire it.');
      expect(e.planCutChars, 0);
      expect(e.planIsPreview, isFalse);
      expect(e.hasPlan, isTrue);
    });

    test('Claude without rawInput.plan falls back to the first content text of a switch_mode call', () {
      final e = permissionEvidence(
        _request({
          'toolCallId': 'tp',
          'kind': 'switch_mode',
          'rawInput': {'planFilePath': '/p.md'},
          'content': [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': 'Do it in two steps.'},
            },
          ],
        }),
      );
      expect(e.planMarkdown, 'Do it in two steps.');
    });

    test('the tool name ExitPlanMode counts as a plan call when the kind is missing', () {
      final e = permissionEvidence(
        _request({
          'toolCallId': 'tp',
          'name': 'ExitPlanMode',
          'content': [
            {
              'type': 'content',
              'content': {'type': 'text', 'text': 'Step one.'},
            },
          ],
        }),
      );
      expect(e.planMarkdown, 'Step one.');
    });

    test('codex plan review (codex-acp plan-review-permission scenario)', () {
      final e = permissionEvidence(
        _request(
          {
            'kind': 'switch_mode',
            'rawInput': {'plan': '# Plan\n\n1. Make the change.'},
            'status': 'pending',
            'title': 'Implement this plan?',
            'toolCallId': 'plan-review:plan-2',
          },
          options: [
            {'kind': 'allow_once', 'name': 'Yes, implement this plan', 'optionId': 'implement_plan'},
            {'kind': 'reject_once', 'name': 'No, and tell Codex what to do differently', 'optionId': 'revise_plan'},
          ],
        ),
      );
      expect(e.planMarkdown, '# Plan\n\n1. Make the change.');
    });

    test('a command call whose content text is a description is not a plan', () {
      final real = replayTrace('claude/permission').permissions.single.request;
      expect(real.toolCall.applyTo(null).content, isNotEmpty);
      expect(permissionEvidence(real).planMarkdown, isNull);
    });

    test('no plan key: nothing, whatever shape rawInput has', () {
      for (final input in <Object?>[
        null,
        'plan',
        ['plan'],
        <String, Object?>{},
        {'plan': ''},
        {'plan': '   \n'},
        {'plan': 42},
        {'plan': null},
        {'plan': ['a']},
      ]) {
        final e = permissionEvidence(_request({'toolCallId': 't', 'kind': 'switch_mode', 'rawInput': input}));
        expect(e.planMarkdown, isNull, reason: '$input');
      }
    });

    test('a 2 MB plan is cut, named, and cheap', () {
      final line = '- step number one of a very long plan, with words in it\n';
      final plan = line * (2 * 1024 * 1024 ~/ line.length);
      expect(plan.length, greaterThan(2 * 1000 * 1000));
      final watch = Stopwatch()..start();
      final e = permissionEvidence(_request({'toolCallId': 't', 'kind': 'switch_mode', 'rawInput': {'plan': plan}}));
      watch.stop();
      final md = e.planMarkdown!;
      expect(md.length, lessThan(planCharLimit + 100));
      expect(e.planCutChars, greaterThan(plan.length - planCharLimit - 600));
      expect(md, endsWith('\u2026 ${e.planCutChars} more characters not shown'));
      expect(md, startsWith('- step number one'));
      expect(watch.elapsedMilliseconds, lessThan(250), reason: 'one substring and one scan of the kept part');
    });

    test('a cut inside a code fence closes the fence before the note', () {
      final plan = '```dart\n${'int a = 1;\n' * 6000}```\n';
      final e = permissionEvidence(_request({'toolCallId': 't', 'kind': 'switch_mode', 'rawInput': {'plan': plan}}));
      final md = e.planMarkdown!;
      expect(md, contains('\n```\n\n\u2026'));
      expect('```'.allMatches(md).length.isEven, isTrue);
    });

    test('a cut never ends inside a surrogate pair', () {
      final plan = '${'a' * (planCharLimit - 1)}\u{1F600}\u{1F600}';
      final e = permissionEvidence(_request({'toolCallId': 't', 'kind': 'switch_mode', 'rawInput': {'plan': plan}}));
      final md = e.planMarkdown!;
      final body = md.substring(0, md.indexOf('\n\n\u2026'));
      expect(body.codeUnits.last, isNot(inInclusiveRange(0xD800, 0xDBFF)));
    });

    test('hidden characters in a plan show as escapes; ANSI is removed', () {
      final e = permissionEvidence(
        _request({
          'toolCallId': 't',
          'kind': 'switch_mode',
          'rawInput': {'plan': 'Run \u202Etxt.exe\u202C \x1B[31mnow\x1B[0m\u0000 ok\u200B'},
        }),
      );
      expect(e.planMarkdown, 'Run \u2039U+202E\u203atxt.exe\u2039U+202C\u203a now\u2039U+0000\u203a ok\u2039U+200B\u203a');
    });

    test('Vietnamese and CJK plans read as written', () {
      const plan = '# Kế hoạch\n\n1. Thêm cờ `--verbose`.\n2. 运行测试。';
      final e = permissionEvidence(_request({'toolCallId': 't', 'kind': 'switch_mode', 'rawInput': {'plan': plan}}));
      expect(e.planMarkdown, plan);
    });

    test('omp plan approval: the plan is read from the form message; a cut one is a preview', () {
      final q = ElicitationRequest.parse({
        'mode': 'form',
        'sessionId': 's',
        'message': 'Approve plan "Add verbose" and start implementation?\n\n# Plan\n\n1. Add flag\n\u2026',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'value': {
              'type': 'string',
              'enum': ['Approve and execute', 'Refine plan'],
            },
          },
        },
      });
      final e = planApprovalEvidence(q)!;
      expect(e.planMarkdown, '# Plan\n\n1. Add flag');
      expect(e.planIsPreview, isTrue);

      final whole = ElicitationRequest.parse({
        'mode': 'form',
        'message': 'Approve plan "x" and start implementation?\n\nOne line plan.',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'value': {
              'type': 'string',
              'enum': ['Approve and execute', 'Refine plan'],
            },
          },
        },
      });
      expect(planApprovalEvidence(whole)!.planIsPreview, isFalse);
    });

    test('omp approval lookalikes are not plans', () {
      final noOptions = ElicitationRequest.parse({
        'mode': 'form',
        'message': 'Approve plan "x" and start implementation?\n\nbody',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'value': {
              'type': 'string',
              'enum': ['yes', 'no'],
            },
          },
        },
      });
      expect(planApprovalEvidence(noOptions), isNull);
      final noMessage = ElicitationRequest.parse({
        'mode': 'form',
        'message': 'Pick one',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'value': {
              'type': 'string',
              'enum': ['Approve and execute', 'Refine plan'],
            },
          },
        },
      });
      expect(planApprovalEvidence(noMessage), isNull);
      final noBody = ElicitationRequest.parse({
        'mode': 'form',
        'message': 'Approve plan "x" and start implementation?',
        'requestedSchema': {
          'type': 'object',
          'properties': {
            'value': {
              'type': 'string',
              'enum': ['Approve and execute', 'Refine plan'],
            },
          },
        },
      });
      expect(planApprovalEvidence(noBody), isNull);
    });
  });

  group('diffs and locations', () {
    test('a diff carries path, both sides and +/- counts', () {
      final e = permissionEvidence(
        _request({
          'toolCallId': 't',
          'kind': 'edit',
          'content': [
            {'type': 'diff', 'path': '/w/a.dart', 'oldText': 'one\ntwo\nthree\n', 'newText': 'one\n2\nthree\nfour\n'},
            {'type': 'diff', 'path': '/w/new.txt', 'newText': 'x\ny\n'},
          ],
          'locations': [
            {'path': '/w/a.dart', 'line': 2},
          ],
        }),
      );
      expect(e.diffs, hasLength(2));
      final a = e.diffs[0];
      expect((a.path, a.added, a.removed, a.isNew, a.approximate), ('/w/a.dart', 2, 1, false, false));
      expect(a.oldText, 'one\ntwo\nthree\n');
      final n = e.diffs[1];
      expect((n.added, n.removed, n.isNew), (2, 0, true));
      expect(n.oldText, isNull);
      expect(e.locations.map((l) => l.label), ['/w/a.dart:2']);
    });

    test('line counts are the minimal diff (Myers: ABCABBA to CBABAC takes 5 edits)', () {
      final c = lineDiffCounts('A\nB\nC\nA\nB\nB\nA', 'C\nB\nA\nB\nA\nC');
      expect((c.added, c.removed, c.approximate), (2, 3, false));
    });

    test('identical texts, empty sides, and a missing final newline', () {
      expect(lineDiffCounts('a\nb\n', 'a\nb\n').added, 0);
      expect(lineDiffCounts('a\nb\n', 'a\nb\n').removed, 0);
      expect((lineDiffCounts('', 'a\nb').added, lineDiffCounts('', 'a\nb').removed), (2, 0));
      expect((lineDiffCounts('a\nb', '').added, lineDiffCounts('a\nb', '').removed), (0, 2));
      expect((lineDiffCounts('a\nb', 'a\nb\n').added, lineDiffCounts('a\nb', 'a\nb\n').removed), (0, 0));
      expect((lineDiffCounts('a', 'a\nb').added, lineDiffCounts('a', 'a\nb').removed), (1, 0));
    });

    test('a change too large to compare gives an upper bound, flagged', () {
      final old = [for (var i = 0; i < 15000; i++) 'old $i'].join('\n');
      final now = [for (var i = 0; i < 15000; i++) 'new $i'].join('\n');
      final c = lineDiffCounts(old, now);
      expect((c.added, c.removed, c.approximate), (15000, 15000, true));
    });

    test('a huge file side is cut and the diff says so', () {
      final big = 'line of text in a big file\n' * 20000;
      final e = permissionEvidence(
        _request({
          'toolCallId': 't',
          'kind': 'edit',
          'content': [
            {'type': 'diff', 'path': 'big.txt', 'oldText': big, 'newText': '${big}tail\n'},
          ],
        }),
      );
      final d = e.diffs.single;
      expect(d.cutChars, greaterThan(0));
      expect(d.approximate, isTrue);
      expect(d.newText.length, lessThanOrEqualTo(diffSideCharLimit));
    });

    test('more than twelve diffs: twelve kept, the rest counted', () {
      final e = permissionEvidence(
        _request({
          'toolCallId': 't',
          'kind': 'edit',
          'content': [
            for (var i = 0; i < 15; i++) {'type': 'diff', 'path': 'f$i', 'newText': 'x'},
          ],
        }),
      );
      expect(e.diffs, hasLength(maxEvidenceDiffs));
      expect(e.hiddenDiffs, 3);
    });

    test('locations: deduped, hidden characters shown, capped, with a fallback to rawInput paths', () {
      final e = permissionEvidence(
        _request({
          'toolCallId': 't',
          'kind': 'read',
          'locations': [
            for (var i = 0; i < 25; i++) {'path': '/w/f$i.dart', 'line': i},
            {'path': '/w/f0.dart', 'line': 0},
            {'path': '/w/\u202Eevil', 'line': null},
            {'path': ''},
          ],
        }),
      );
      expect(e.locations, hasLength(maxEvidenceLocations));
      expect(e.hiddenLocations, 25 + 1 - maxEvidenceLocations);
      expect(e.locations.first.label, '/w/f0.dart:0');

      final hidden = permissionEvidence(
        _request({
          'toolCallId': 't',
          'locations': [
            {'path': '/w/\u202Eevil'},
          ],
        }),
      );
      expect(hidden.locations.single.path, '/w/\u2039U+202E\u203aevil');

      final fallback = permissionEvidence(
        _request({
          'toolCallId': 't',
          'kind': 'edit',
          'rawInput': {'file_path': '/w/x.py', 'old_string': 'a', 'new_string': 'b'},
        }),
      );
      expect(fallback.locations.single.label, '/w/x.py');
    });

    test('a request with nothing in it has empty evidence', () {
      final e = permissionEvidence(PermissionRequest.parse(const {}));
      expect(e.isEmpty, isTrue);
      expect(e.planMarkdown, isNull);
      expect(e.diffs, isEmpty);
      expect(e.locations, isEmpty);
    });
  });

  group('lastAgentSentence', () {
    test('the last sentence of the last agent message', () {
      expect(_sentence('I will look at the build folder. Then I will delete it. May I run rm -rf build?'), 'May I run rm -rf build?');
      expect(_sentence('Checking the config. Next I will rewrite it'), 'Next I will rewrite it');
    });

    test('Vietnamese splits on its Latin punctuation and keeps its diacritics', () {
      expect(_sentence('Tôi sẽ xoá thư mục build. Bạn có đồng ý không?'), 'Bạn có đồng ý không?');
      expect(_sentence('Mình cần sửa tệp này! Đang chạy lệnh thử nghiệm'), 'Đang chạy lệnh thử nghiệm');
    });

    test('CJK splits on full-width stops with no space', () {
      expect(_sentence('我会删除构建目录。你同意吗？'), '你同意吗？');
      expect(_sentence('ビルドを削除します。続けてテストを実行します'), '続けてテストを実行します');
      expect(_sentence('我会先看一下。然后运行 `npm test`。'), '然后运行 npm test。');
    });

    test('paths, versions, abbreviations and list numbers do not split', () {
      expect(_sentence('I edit src/main.py and bump to 3.5.1 now'), 'I edit src/main.py and bump to 3.5.1 now');
      expect(_sentence('First read it. Then edit src/main.py, e.g. the flag parser'), 'Then edit src/main.py, e.g. the flag parser');
      expect(_sentence('Ask Dr. Smith about it'), 'Ask Dr. Smith about it');
      expect(_sentence('1. Install the package'), 'Install the package');
    });

    test('ellipsis and repeated marks end one sentence', () {
      expect(_sentence('Hmm... let me check the lockfile first'), 'let me check the lockfile first');
      expect(_sentence('Really?! I will delete it.'), 'I will delete it.');
    });

    test('Markdown is reduced to words', () {
      expect(_sentence('Next I will run **`rm -rf build`** in [the docs](https://x.y/z).'), 'Next I will run rm -rf build in the docs.');
      expect(_sentence('Plan:\n\n- read the file\n- rewrite `main.py`'), 'rewrite main.py');
      expect(_sentence('## Deleting the folder'), 'Deleting the folder');
    });

    test('a trailing code block is skipped, an unclosed one too', () {
      expect(_sentence('I will run this command:\n\n```sh\nrm -rf build\n```\n'), 'I will run this command:');
      expect(_sentence('I will run this command:\n\n```sh\nrm -rf bui'), 'I will run this command:');
    });

    test('a wrapped paragraph is one paragraph', () {
      expect(_sentence('I will remove the build\nfolder before the rebuild'), 'I will remove the build folder before the rebuild');
    });

    test('ANSI, controls and direction marks are removed', () {
      expect(_sentence('Run \x1B[31mrm\x1B[0m now\u0000 \u202Etxt.exe\u202C please'), 'Run rm now txt.exe please');
    });

    test('at most 200 characters, ending in an ellipsis, never inside a surrogate pair', () {
      final long = _sentence('word ' * 100)!;
      expect(long.length, lessThanOrEqualTo(intentCharLimit));
      expect(long, endsWith('\u2026'));
      expect(_sentence('\u{1F600}' * 150), isNull, reason: 'no letter or digit: nothing to read');
      final emoji = _sentence('a\u{1F600}' * 150)!;
      expect(emoji.length, lessThanOrEqualTo(intentCharLimit));
      expect(emoji.codeUnits[emoji.length - 2], isNot(inInclusiveRange(0xD800, 0xDBFF)));
      final cjk = _sentence('字' * 500)!;
      expect(cjk.length, lessThanOrEqualTo(intentCharLimit));
    });

    test('a 2 MB message is cheap', () {
      final text = '${'filler text. ' * 150000}Final words here.';
      final watch = Stopwatch()..start();
      expect(_sentence(text), 'Final words here.');
      expect(watch.elapsedMilliseconds, lessThan(250));
    });

    test('reads back from the call, skips tools and thoughts, stops at the user', () {
      final items = <TranscriptItem>[
        _say('Old turn text.', key: 'a'),
        _say('Do the thing', role: MessageRole.user, key: 'u'),
        _say('Thinking aloud.', role: MessageRole.thought, key: 't'),
        _tool('read'),
        _tool('ask'),
        _say('Later text.', key: 'later'),
      ];
      expect(lastAgentSentence(items, beforeToolCallId: 'ask'), isNull, reason: 'the user message ends the search');
      items.insert(2, _say('I will ask first.', key: 'b'));
      expect(lastAgentSentence(items, beforeToolCallId: 'ask'), 'I will ask first.');
      expect(lastAgentSentence(items), 'Later text.', reason: 'without a call the end of the list is the place');
      expect(lastAgentSentence(items, beforeToolCallId: 'missing'), 'Later text.');
    });

    test('a message with no words falls back to the one before it', () {
      final items = <TranscriptItem>[_say('First said.', key: 'a'), _say('```\ncode only\n```', key: 'b'), _say('...', key: 'c')];
      expect(lastAgentSentence(items), 'First said.');
    });

    test('nothing said is null', () {
      expect(lastAgentSentence(const []), isNull);
      expect(_sentence(''), isNull);
      expect(_sentence('   \n\n  '), isNull);
      expect(_sentence('!!! ... ???'), isNull);
      expect(lastAgentSentence([_say('hidden', role: MessageRole.thought)]), isNull);
    });

    test('a live message is read like any other', () {
      final state = [
        {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'Starting. I will delete'}},
        {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': ' the cache now.'}},
      ].fold(const AgentSessionState('s'), (s, u) => s.apply(SessionUpdate.parse(u)));
      expect(state.liveMessage, isNotNull);
      expect(lastAgentSentence(state.items), 'I will delete the cache now.');
    });
  });
}
