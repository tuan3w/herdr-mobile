// Every test starts real processes (a keeper, an agent, python): the default 30 s per test is what a busy machine runs out of, not a hang.
@Timeout(Duration(minutes: 3))
@TestOn('linux || mac-os')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/keeper_command.dart';

import 'support/keeper_harness.dart';

// What the REAL keeper script (python3) does for Cursor's flow: `authenticate`
// before the first session, and its `cursor/*` extension methods, which the
// keeper turns into the question form and the permission card the phone has.

void main() {
  final hasPython = pythonDir() != null;

  Future<KeeperHost> newHost([Map<String, String> env = const {}]) async {
    final h = await KeeperHost.create({'FAKE_ACP_AUTH': 'cursor_login', ...env});
    addTearDown(h.dispose);
    await h.install();
    return h;
  }

  Future<KeeperAttach> session(KeeperHost h) async {
    final info = await h.start(agent: 'cursor');
    final a = await h.attach(info.id);
    await a.initialize();
    final created = await a.newSession(h);
    expect(created['error'], isNull, reason: 'the agent refused the session: $created');
    return a;
  }

  /// What the agent said it got back (`got:<json>`), once the turn says it.
  Future<Object?> got(KeeperAttach a) async {
    final m = await a.next(
      (m) => isUpdate('agent_message_chunk')(m) && updateText(asJson(asJson(m['params'])['update'])).startsWith('got:'),
    );
    return jsonDecode(updateText(asJson(asJson(m['params'])['update'])).substring(4));
  }

  Json answered(String colour, List<String> fruits) => {
    'outcome': {
      'outcome': 'answered',
      'answers': [
        {
          'questionId': 'q1',
          'selectedOptionIds': [colour],
        },
        {'questionId': 'q2', 'selectedOptionIds': fruits},
      ],
    },
  };

  group('keeper with Cursor', skip: hasPython ? false : 'python3 is not installed', () {
    test('authenticates before the first session, and the start reports only after it', () async {
      final h = await newHost();
      await h.start(agent: 'cursor');
      final methods = [for (final m in h.agentLog()) m['method']];
      expect(methods, ['initialize', 'authenticate'], reason: 'the start report waited for the agent');
      final auth = h.agentLog().last;
      expect(asJson(auth['params'])['methodId'], 'cursor_login');
      final a = await h.attach((await h.list()).single.id);
      await a.initialize();
      expect((await a.newSession(h))['error'], isNull);
      expect([for (final m in h.agentLog()) m['method']], ['initialize', 'authenticate', 'session/new']);
    });

    test('a sign-in the agent refuses fails the start with its words and leaves nothing behind', () async {
      final h = await newHost({'FAKE_ACP_AUTH_FAIL': '1'});
      final r = await h.run(keeperStartCommand(agent: 'cursor', cwd: h.work));
      expect(r.code, 70);
      expect(
        r.err,
        contains('Not logged in: run agent login first'),
        reason: 'the error and the reason it carries in data',
      );
      expect(await h.list(), isEmpty);
    });

    test('an agent that is not Cursor is not asked to authenticate', () async {
      final h = await newHost();
      await h.start(agent: 'omp');
      expect([for (final m in h.agentLog()) m['method']], ['initialize']);
    });

    test(
      'a question arrives as a form with a choice and a multiple choice, and the answer goes back as chosen',
      () async {
        final h = await newHost();
        final a = await session(h);
        a.prompt('cursor-ask');
        final q = await a.next(isMethod('elicitation/create'));
        final p = asJson(q['params']);
        expect(p['message'], 'Need input');
        expect(p['sessionId'], 'sess-1');
        final schema = asJson(p['requestedSchema']);
        expect(schema['required'], ['q1', 'q2']);
        final props = asJson(schema['properties']);
        expect(asJson(props['q1']), {
          'type': 'string',
          'title': 'Which colour?',
          'oneOf': [
            {'const': 'red', 'title': 'Red'},
            {'const': 'blue', 'title': 'Blue'},
          ],
        });
        expect(asJson(props['q2']), {
          'type': 'array',
          'title': 'Which fruits?',
          'items': {
            'anyOf': [
              {'const': 'fig', 'title': 'Fig'},
              {'const': 'plum', 'title': 'Plum'},
              {'const': 'pear', 'title': 'Pear'},
            ],
          },
        });
        a.reply(q['id'], {
          'action': 'accept',
          'content': {
            'q1': 'blue',
            'q2': ['fig', 'pear'],
          },
        });
        expect(await got(a), answered('blue', ['fig', 'pear']));
      },
    );

    test('declining a question is skipped, and cancelling it is cancelled', () async {
      final h = await newHost();
      final a = await session(h);
      var id = a.prompt('cursor-ask');
      var q = await a.next(isMethod('elicitation/create'));
      a.reply(q['id'], {'action': 'decline'});
      expect(await got(a), {
        'outcome': {'outcome': 'skipped'},
      });
      await a.response(id);

      id = a.prompt('cursor-ask');
      q = await a.next(isMethod('elicitation/create'));
      a.reply(q['id'], {'action': 'cancel'});
      expect(await got(a), {
        'outcome': {'outcome': 'cancelled'},
      });
      await a.response(id);
    });

    test('a question with nothing to choose from is cancelled at once, not shown', () async {
      final h = await newHost();
      final a = await session(h);
      a.prompt('cursor-ask-empty');
      expect(await got(a), {
        'outcome': {'outcome': 'cancelled'},
      });
      expect(a.seen.where(isMethod('elicitation/create')), isEmpty);
    });

    test('a question asked while detached is held, re-issued to the next client and answered once', () async {
      final h = await newHost();
      final a = await session(h);
      a.prompt('cursor-ask');
      final first = await a.next(isMethod('elicitation/create'));
      await a.close();
      await eventually(() async => (await h.list()).single.pending == 1, what: 'one pending request');

      final b = await h.attach((await h.list()).single.id);
      await b.initialize();
      await b.load(h);
      final again = await b.next(isMethod('elicitation/create'));
      expect(again['id'], first['id']);
      expect(asJson(again['params']), asJson(first['params']));
      b.reply(again['id'], {
        'action': 'accept',
        'content': {
          'q1': 'red',
          'q2': ['plum'],
        },
      });
      // A late duplicate (another device, a double tap) changes nothing.
      b.reply(again['id'], {'action': 'decline'});
      expect(await got(b), answered('red', ['plum']));
      final answers = h.agentLog().where((m) => !m.containsKey('method') && m['id'] == 'cur-ask').toList();
      expect(answers, hasLength(1));
      expect((await h.list()).single.pending, 0);
    });

    test('a plan arrives as a permission to approve with the plan in it, and only "Approve plan" accepts it', () async {
      final h = await newHost();
      final a = await session(h);

      Future<Object?> choose(Json chosen, {bool inspect = false}) async {
        final id = a.prompt('cursor-plan');
        final req = await a.next(isMethod('session/request_permission'));
        if (inspect) {
          final p = asJson(req['params']);
          final tool = asJson(p['toolCall']);
          expect(tool['title'], 'Approve plan: Refactor tabs');
          final text = asJson(asJson((tool['content']! as List).single)['content'])['text']! as String;
          expect(text, contains('Keep UX.'));
          expect(text, contains('1. Inspect.'));
          expect([for (final o in p['options']! as List) asJson(o)['optionId']], ['accept', 'reject']);
        }
        a.reply(req['id'], {'outcome': chosen});
        final r = await got(a);
        await a.response(id);
        return r;
      }

      Json result(String name) => {
        'outcome': {'outcome': name},
      };
      Json cancelled() => {'outcome': 'cancelled'};
      Json selected(String id) => {'outcome': 'selected', 'optionId': id};

      expect(await choose(selected('accept'), inspect: true), result('accepted'));
      expect(await choose(selected('reject')), result('rejected'));
      expect(await choose(cancelled()), result('cancelled'));
      expect(await choose(selected('something-else')), result('cancelled'), reason: 'never accepted by guess');
    });

    test('todo updates become plan updates: replaced, then merged, a cancelled one left out', () async {
      final h = await newHost();
      final a = await session(h);
      a.prompt('cursor-todos');
      await a.next(isUpdate('agent_message_chunk'));
      final plans = [
        for (final u in updatesOf(a.seen))
          if (u['sessionUpdate'] == 'plan') u['entries'],
      ];
      Json entry(String content, String status) => {'content': content, 'priority': 'medium', 'status': status};
      expect(plans, [
        [entry('Set up', 'completed'), entry('Build', 'in_progress')],
        [entry('Set up', 'completed'), entry('Build', 'completed'), entry('Test', 'pending')],
      ]);
    });

    test('a finished subagent task rides its launching tool call, without the prompt', () async {
      final h = await newHost();
      final a = await session(h);
      a.prompt('cursor-task');
      await a.next(isUpdate('agent_message_chunk'));
      final tasks = [
        for (final u in updatesOf(a.seen))
          if (u['sessionUpdate'] == 'tool_call_update' && u['_meta'] != null) u,
      ];
      expect(tasks, hasLength(1));
      expect(tasks.single['toolCallId'], 'tc-task');
      expect(asJson(asJson(asJson(tasks.single['_meta'])['cursor'])['task']), {
        'description': 'Explore codebase',
        'subagentType': 'reviewer',
        'model': 'composer',
        'agentId': 'ag-1',
        'durationMs': 1234,
      });
    });

    test('a task notification that names no tool call is dropped', () async {
      final h = await newHost();
      final a = await session(h);
      a.prompt('cursor-task-bad');
      await a.next(isUpdate('agent_message_chunk'));
      expect([
        for (final u in updatesOf(a.seen))
          if (u['sessionUpdate'] == 'tool_call_update') u,
      ], isEmpty);
    });

    test('a package run through npx keeps the route\'s arguments', () async {
      final h = await newHost();
      final fake = File('test/support/fake_acp_agent.py').absolute.path;
      final stub = File('${h.home.path}/bin/npx')
        ..writeAsStringSync('#!/bin/sh\nprintf \'%s\\n\' "\$@" > "\$HOME/npx.argv"\nexec python3 \'$fake\'\n');
      await Process.run('chmod', ['755', stub.path]);
      await h.start(agent: 'deepseek');
      expect(File('${h.home.path}/npx.argv').readAsLinesSync(), ['-y', '@deepseek-ai/dsh@next', '--profile', 'acp']);
    });
  });
}
