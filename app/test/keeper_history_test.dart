import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';

import 'support/keeper_harness.dart' show eventually;
import 'support/keeper_process_host.dart';

// The `history` command of the keeper (the `herdr-host` binary) against the scripted agent
// (`fake-acp-agent` of `rust/crates/testkit`, whose store is `useAgentStore`): what an
// agent remembers must come back newest first, bounded, and the agent process
// the command ran must never outlive it.

Future<bool> _alive(int pid) async => (await Process.run('kill', ['-0', '$pid'])).exitCode == 0;

Map<String, Object?> _session(String id, {String cwd = '/work', Object? title, String? at, int? messages}) => {
  'sessionId': id,
  'cwd': cwd,
  'title': ?title,
  'updatedAt': ?at,
  'messageCount': ?messages,
};

/// The app's failure for a keeper call the host refused: the host's own words, fatal when trying again
/// cannot help.
Matcher _failed(Object? text, {bool? fatal}) => isA<AgentHostException>()
    .having((e) => e.message, 'message', text)
    .having((e) => e.fatal, 'fatal', fatal ?? anything);

void main() {
  Future<KeeperProcessHost> newHost() async {
    final h = await KeeperProcessHost.create();
    addTearDown(h.dispose);
    return h;
  }

  /// No agent process of this test host is left, and no keeper state exists.
  Future<void> expectNothingLeft(KeeperProcessHost h) async {
    for (final run in h.agentRuns) {
      expect(await _alive(run.pid), isFalse, reason: 'agent ${run.pid} outlived the command');
    }
    final keepers = Directory('${h.home.path}/.herdr-mobile/keepers');
    expect(!keepers.existsSync() || keepers.listSync().isEmpty, isTrue, reason: 'history must not create keeper files');
  }

  group('history command', () {
    test('lists newest first with title, count and folder; unknown dates last, in the agent\'s order', () async {
      final h = await newHost();
      h.useAgentStore(
        sessions: [
          _session('old', title: 'Old one', at: '2026-10-01T08:00:00.000Z', messages: 4),
          _session('undated-1'),
          _session('new', title: 'New one', at: '2026-10-05T09:30:00.000Z', messages: 12),
          _session('undated-2'),
          _session('mid', at: '2026-10-03T00:00:00.000Z', messages: 0),
        ],
      );

      final past = await h.history(agent: 'omp');

      expect(past.sessions.map((s) => s.sessionId), ['new', 'mid', 'old', 'undated-1', 'undated-2']);
      expect(past.sessions.first.title, 'New one');
      expect(past.sessions.first.cwd, '/work');
      expect(past.sessions.first.messageCount, 12);
      expect(past.sessions.first.updatedAt, DateTime.utc(2026, 10, 5, 9, 30));
      expect(past.sessions[1].messageCount, 0);
      expect(past.sessions.last.updatedAt, isNull);
      expect((past.canList, past.canLoad, past.canResume, past.more), (true, true, true, false));
      await expectNothingLeft(h);
    });

    test('a folder limits the list to its sessions; without one every folder is listed', () async {
      final h = await newHost();
      final other = Directory('${h.home.path}/other')..createSync();
      h.useAgentStore(
        sessions: [
          _session('a1', cwd: h.work, at: '2026-10-02T00:00:00Z'),
          _session('b1', cwd: other.path, at: '2026-10-03T00:00:00Z'),
          _session('a2', cwd: h.work, at: '2026-10-04T00:00:00Z'),
        ],
      );

      expect((await h.history(agent: 'omp', cwd: h.work)).sessions.map((s) => s.sessionId), ['a2', 'a1']);
      expect((await h.history(agent: 'omp', cwd: other.path)).sessions.map((s) => s.sessionId), ['b1']);
      expect((await h.history(agent: 'omp')).sessions.map((s) => s.sessionId), ['a2', 'b1', 'a1']);
    });

    test('the agent runs in the asked folder, or in the home folder when none is asked', () async {
      final h = await newHost();
      h.useAgentStore();

      await h.history(agent: 'omp', cwd: h.work);
      await h.history(agent: 'omp');

      final cwds = h.agentRuns.map((r) => Directory(r.cwd).resolveSymbolicLinksSync()).toList();
      expect(cwds, [Directory(h.work).resolveSymbolicLinksSync(), Directory(h.home.path).resolveSymbolicLinksSync()]);
    });

    test('reads past the first page, and says when it stopped before the end', () async {
      final h = await newHost();
      h.useAgentStore(
        page: 2,
        sessions: [for (var i = 0; i < 7; i++) _session('s$i', at: '2026-10-0${i + 1}T00:00:00Z')],
      );
      final all = await h.history(agent: 'omp');
      expect(all.sessions.map((s) => s.sessionId), ['s6', 's5', 's4', 's3', 's2', 's1', 's0'].sublist(0, 7));
      expect(all.more, isFalse);

      // Five pages are read at most.
      h.useAgentStore(
        page: 2,
        sessions: [
          for (var i = 0; i < 14; i++) _session('p$i', at: '2026-10-${(i + 1).toString().padLeft(2, '0')}T00:00:00Z'),
        ],
      );
      final capped = await h.history(agent: 'omp');
      expect(capped.sessions, hasLength(10));
      expect(capped.more, isTrue);
      expect(capped.sessions.first.sessionId, 'p9', reason: 'newest of what was read');
    });

    test('at most 200 sessions, whatever the page size', () async {
      final h = await newHost();
      h.useAgentStore(
        page: 100,
        sessions: [
          for (var i = 0; i < 260; i++)
            _session(
              's$i',
              at: '2026-10-05T10:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}Z',
            ),
        ],
      );

      final past = await h.history(agent: 'omp');

      expect(past.sessions, hasLength(200));
      expect(past.more, isTrue);
    });

    test('the answer stays small: titles are cut, junk entries dropped, nothing else is passed on', () async {
      final h = await newHost();
      h.useAgentStore(
        sessions: [
          _session('long', title: 'x' * 5000, at: '2026-10-05T00:00:00Z'),
          {'sessionId': 'no-folder'},
          {'cwd': '/work', 'title': 'no id'},
          {
            ...(_session('extra', at: '2026-10-04T00:00:00Z', messages: 3)),
            'updates': List.generate(500, (i) => {'sessionUpdate': 'x$i'}),
          },
        ],
      );

      final object = await h.historyObject(agent: 'omp');
      final rows = object['sessions']! as List;

      expect(rows.map((s) => (s as Map)['sessionId']), ['long', 'extra']);
      expect(((rows.first as Map)['title'] as String).length, lessThanOrEqualTo(300));
      expect((rows.last as Map).keys, unorderedEquals(['sessionId', 'cwd', 'updatedAt', '_meta']));
      expect(jsonEncode(object).length, lessThan(1500));
    });

    test('an agent without session/list reports canList false, not an empty history', () async {
      final h = await newHost();
      h.useAgentStore(caps: 'load', sessions: [_session('s1')]);

      final past = await h.history(agent: 'omp');

      expect((past.canList, past.canLoad, past.canResume), (false, true, false));
      expect(past.sessions, isEmpty);
      expect(past.canReopen, isTrue);
    });

    test('an agent that cannot even load says so (the default fake agent)', () async {
      final h = await newHost();

      final past = await h.history(agent: 'omp');

      expect((past.canList, past.canLoad, past.canResume, past.canReopen), (false, false, false, false));
    });

    test('an agent that only resumes can be reopened', () async {
      final h = await newHost();
      h.useAgentStore(caps: 'list,resume', sessions: [_session('s1')]);

      final past = await h.history(agent: 'omp');

      expect((past.canLoad, past.canResume, past.canReopen), (false, true, true));
      expect(past.sessions, hasLength(1));
    });

    test('exits clean with the agent gone and no keeper files', () async {
      final h = await newHost();
      h.useAgentStore(sessions: [_session('s1')]);

      final past = await h.history(agent: 'omp');

      expect(past.sessions, hasLength(1));
      expect(h.agentRuns, hasLength(1));
      await expectNothingLeft(h);
    });

    test(
      'an agent that answers session/list with an error: the call fails with its words, the agent is gone',
      () async {
        final h = await newHost();
        h.useAgentStore(sessions: [_session('s1')]);
        h.env['FAKE_ACP_LIST_FAIL'] = '1';

        await expectLater(h.history(agent: 'omp'), throwsA(_failed(contains('omp: store unreadable'))));

        await expectNothingLeft(h);
      },
    );

    test('an agent that dies before answering initialize fails the command', () async {
      final h = await newHost();
      h.env['FAKE_ACP_FAIL_INIT'] = '1';

      await expectLater(h.history(agent: 'omp'), throwsA(_failed(contains('exited before'))));

      await expectNothingLeft(h);
    });

    test(
      'notifications, garbage and requests of the agent do not derail it; the request is refused, not left hanging',
      () async {
        final h = await newHost();
        h.useAgentStore(sessions: [_session('s1'), _session('s2')]);
        h.env['FAKE_ACP_LIST_NOISE'] = '1';

        final past = await h.history(agent: 'omp');

        expect(past.sessions.map((s) => s.sessionId).toSet(), {'s1', 's2'});
        final answered = [
          for (final l in File(h.env['FAKE_ACP_LOG']!).readAsLinesSync())
            if (l.contains('noise-1') &&
                (jsonDecode(l) as Map)['recv'] is Map &&
                ((jsonDecode(l) as Map)['recv'] as Map)['error'] != null)
              ((jsonDecode(l) as Map)['recv'] as Map)['error'] as Map,
        ];
        expect(answered.first['code'], -32601);
        await expectNothingLeft(h);
      },
    );

    test('the client giving up ends the agent too, with SIGKILL when it ignores SIGTERM', () async {
      final h = await newHost();
      h.useAgentStore(sessions: [_session('s1')]);
      h.env['FAKE_ACP_LIST_DELAY'] = '60';
      h.env['FAKE_ACP_IGNORE_TERM'] = '1';
      final stream = await h.openHistory(agent: 'omp');
      await eventually(() => h.agentRuns.isNotEmpty, what: 'the agent to start');
      final agent = h.agentRuns.single.pid;
      expect(await _alive(agent), isTrue);

      stream.reset();

      await eventually(
        () async => !await _alive(agent),
        what: 'the agent to be gone',
        timeout: const Duration(seconds: 15),
      );
      await expectNothingLeft(h);
    });

    test('an agent that is not installed is named, and trying again cannot help', () async {
      final h = await newHost();
      h.useAgentStore();
      File('${h.home.path}/bin/omp').deleteSync();

      await expectLater(h.history(agent: 'omp'), throwsA(_failed(contains('not installed'), fatal: true)));
    });

    test('a missing folder is named before any agent is started', () async {
      final h = await newHost();
      h.useAgentStore();

      await expectLater(
        h.history(agent: 'omp', cwd: '${h.home.path}/nope'),
        throwsA(_failed(contains('does not exist'), fatal: true)),
      );

      expect(h.agentRuns, isEmpty);
    });

    test('a folder name is only ever a folder name: nothing in it is run', () async {
      final h = await newHost();
      h.useAgentStore();
      final marker = '${h.home.path}/pwned';
      for (final evil in [
        "x'; touch $marker; '",
        '\$(touch $marker)',
        '`touch $marker`',
        'x"; touch $marker; "',
        'a b; touch $marker',
        '-rf',
      ]) {
        await expectLater(
          h.history(agent: 'omp', cwd: evil),
          throwsA(_failed(contains('does not exist'), fatal: true)),
          reason: evil,
        );
        expect(File(marker).existsSync(), isFalse, reason: evil);
      }
      expect(h.agentRuns, isEmpty);
    });

    test('a folder with spaces and quotes, and ~, work', () async {
      final h = await newHost();
      final odd = Directory('${h.home.path}/it\'s a "dir" \$HOME `x`')..createSync();
      h.useAgentStore(
        sessions: [
          _session('s1', cwd: odd.path),
          _session('s2', cwd: h.home.path),
        ],
      );

      expect((await h.history(agent: 'omp', cwd: odd.path)).sessions.map((s) => s.sessionId), ['s1']);
      expect((await h.history(agent: 'omp', cwd: '~')).sessions.map((s) => s.sessionId), ['s2']);
    });
  });
}
