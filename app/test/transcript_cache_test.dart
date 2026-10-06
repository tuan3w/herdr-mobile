// The transcript cache: what the recorder keeps of the lines a session
// received, that a cached transcript folds into the very state a keeper's
// replay gives, and the file store (versioned, bounded, atomic, debounced, and
// it never trusts a file it cannot read).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_client.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/transcript_log.dart';
import 'package:herdr_mobile/data/services/transcript_cache.dart';

import 'acp/support/fake_agent.dart';
import 'acp/support/trace_state.dart' show loadTrace;

String _line(String sessionId, Map<String, Object?> update) => jsonEncode({
  'jsonrpc': '2.0',
  'method': 'session/update',
  'params': {'sessionId': sessionId, 'update': update},
});

Map<String, Object?> _agent(String text, {String id = 'a1'}) => {
  'sessionUpdate': 'agent_message_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

Map<String, Object?> _user(String text, {String id = 'u1'}) => {
  'sessionUpdate': 'user_message_chunk',
  'messageId': id,
  'content': {'type': 'text', 'text': text},
};

/// A conversation of [n] pairs as raw lines.
List<String> _conversation(int n, {String sid = 's1', String pad = ''}) => [
  for (var i = 0; i < n; i++) ...[
    _line(sid, _user('question $i', id: 'u$i')),
    _line(sid, _agent('answer $i $pad', id: 'a$i')),
  ],
];

/// What a state shows, compared item by item (the states hold no equality).
List<String> _describe(AgentSessionState s) => [
  for (final i in s.items)
    switch (i) {
      TranscriptMessage() => 'message ${i.key} ${i.role.name} ${i.messageId} ${i.blocks.map((b) => b is TextBlock ? b.text : b.runtimeType).join('|')}',
      TranscriptTool() => 'tool ${i.key} ${i.call.title} ${i.call.status.name} ${i.call.kind.name}',
      TranscriptStop() => 'stop ${i.key} ${i.reason.name}',
      TranscriptNote() => 'note ${i.key} ${i.text}',
    },
  'plan ${s.plan.map((e) => '${e.content}:${e.status.name}').join(',')}',
  'title ${s.title}',
  'mode ${s.currentModeId}',
  'commands ${s.commands.map((c) => c.name).join(',')}',
  'runs ${s.subagents.length}',
];

void main() {
  group('TranscriptRecorder', () {
    test('keeps the newest lines under both caps, oldest out first, and says it left some out', () {
      final r = TranscriptRecorder(maxLines: 5, maxChars: 1 << 20);
      for (var i = 0; i < 8; i++) {
        r.add('line $i');
      }
      expect(r.lines, ['line 3', 'line 4', 'line 5', 'line 6', 'line 7']);
      expect(r.partial, isTrue);

      final bytes = TranscriptRecorder(maxLines: 100, maxChars: 30);
      for (var i = 0; i < 10; i++) {
        bytes.add('0123456789'); // 10 chars
      }
      expect(bytes.length, 3);
      expect(bytes.partial, isTrue);
    });

    test('a line over the cap is left out, never cut; the log is marked partial', () {
      final r = TranscriptRecorder(maxLineChars: 100);
      r.add('small');
      r.add('x' * 101);
      r.add('after');
      expect(r.lines, ['small', 'after'], reason: 'no line is edited: the big one is simply not there');
      expect(r.partial, isTrue);
    });

    test('a log within the caps is not partial; a new attach starts over', () {
      final r = TranscriptRecorder()
        ..add('a')
        ..setup = {'x': 1};
      expect(r.partial, isFalse);
      r.add('b' * (r.maxLineChars + 1));
      expect(r.partial, isTrue);
      final rev = r.revision;
      r.reset();
      expect(r.isEmpty, isTrue);
      expect(r.partial, isFalse);
      expect(r.setup, isNull);
      expect(r.revision, greaterThan(rev));
    });

    test('the user\'s own message is written the way the keeper\'s log has it, and can be taken back', () {
      final r = TranscriptRecorder();
      r.add(_line('s1', _agent('hello')));
      r.addLocalUser('s1', [const TextBlock('fix it'), const TextBlock('now')]);
      expect(r.length, 3);
      final state = replayCachedTranscript(_cached(r.lines));
      expect(state.items, hasLength(2));
      final user = state.items[1] as TranscriptMessage;
      expect(user.role, MessageRole.user);
      expect(user.text, 'fix itnow', reason: 'two blocks of one message');

      r.takeBackLocalUser();
      expect(r.length, 1);

      // Taken back after the agent's own lines arrived: only the message goes.
      r.addLocalUser('s1', [const TextBlock('again')]);
      r.add(_line('s1', _agent(' more')));
      r.takeBackLocalUser();
      expect(r.length, 2);
      final kept = replayCachedTranscript(_cached(r.lines));
      expect([for (final i in kept.items) if (i is TranscriptMessage) i.role], [MessageRole.agent]);
      r.takeBackLocalUser();
      expect(r.length, 2, reason: 'a message is taken back once');
    });
  });

  group('a cached transcript folds into what a keeper\'s replay gives', () {
    // The same lines, once through a real client's `session/load` and once
    // through the cache's fold.
    for (final (agent, scenario) in [
      ('claude', 'tools'),
      ('claude', 'permission'),
      ('claude', 'plan'),
      ('claude', 'subagent'),
      ('codex', 'thinking'),
      ('codex', 'tools'),
      ('omp', 'markdown'),
      ('omp', 'plan'),
    ]) {
      test('$agent / $scenario', () async {
        final updates = [
          for (final l in loadTrace(agent, scenario))
            if (l.received && l.method == 'session/update') (l.msg['params'] as Map)['update'] as Map<String, Object?>,
        ];
        expect(updates, isNotEmpty);

        final link = MemoryLink();
        final recorder = TranscriptRecorder();
        late final FakeAgent server;
        server = FakeAgent(link.agent, {
          'initialize': (_) => ompInitialize(),
          'session/load': (_) async {
            for (final u in updates) {
              server.update('s', u);
            }
            return {
              'modes': {
                'currentModeId': 'default',
                'availableModes': [
                  {'id': 'default', 'name': 'Default'},
                ],
              },
            };
          },
        });
        final client = AcpClient(
          link.client,
          handler: _NoRequests(),
          onUpdateLine: recorder.add,
          onSetup: (sid, result) => recorder.setup = result,
        );
        await client.initialize();
        final live = (await client.loadSession('s', cwd: '/x')).withDisconnected();
        await client.close();
        expect(recorder.length, updates.length, reason: 'every update line was kept as it came');

        final cached = replayCachedTranscript(_cached(recorder.lines, sid: 's', setup: recorder.setup));
        expect(_describe(cached), _describe(live));
        expect(cached.disconnected, isTrue);
        expect(cached.replaying, isFalse);
        expect(cached.pending, isEmpty);
        expect(cached.turnActive, isFalse);
      });
    }

    test('lines of another session are skipped', () {
      final lines = [
        _line('s1', _user('one', id: 'u1')),
        _line('other', _agent('not mine', id: 'x')),
        _line('s1', _agent('two', id: 'a2')),
      ];
      final state = replayCachedTranscript(_cached(lines));
      expect(state.items, hasLength(2));
      expect(_describe(state).join(), isNot(contains('not mine')));
    });
  });

  group('FileTranscriptCache', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('transcripts'));
    tearDown(() => dir.deleteSync(recursive: true));

    FileTranscriptCache cache({
      int session = 1 << 20,
      int total = 5 << 20,
      Duration debounce = const Duration(milliseconds: 30),
      Offload offload = inlineOffload,
    }) => FileTranscriptCache(
      () async => dir,
      maxSessionBytes: session,
      maxTotalBytes: total,
      debounce: debounce,
      offload: offload,
    );

    TranscriptSnapshot snapshot(List<String> lines, {String sid = 's1', bool partial = false, Object? setup}) =>
        TranscriptSnapshot(sessionId: sid, asOf: DateTime.utc(2026, 3, 1, 14, 2), lines: lines, partial: partial, setup: setup);

    List<String> names() => [for (final f in dir.listSync()) f.uri.pathSegments.last]..sort();

    test('what is saved is read back: the lines decoded, the setup, the time, partial', () async {
      final c = cache();
      final lines = _conversation(3);
      c.save('m1/k1', snapshot(lines, setup: {'modes': {'currentModeId': 'plan', 'availableModes': []}}, partial: true), now: true);
      await c.flush();
      final got = (await c.read('m1/k1'))!;
      expect(got.sessionId, 's1');
      expect(got.asOf, DateTime.fromMillisecondsSinceEpoch(DateTime.utc(2026, 3, 1, 14, 2).millisecondsSinceEpoch));
      expect(got.partial, isTrue);
      expect(got.setup, {'modes': {'currentModeId': 'plan', 'availableModes': []}});
      expect(got.updates, hasLength(6));
      expect(got.updates.first['sessionId'], 's1');
      final state = replayCachedTranscript(got);
      expect(state.items, hasLength(6));
      expect(state.currentModeId, 'plan');
    });

    test('the real isolate does the same', () async {
      final c = cache(offload: isolateOffload);
      c.save('m1/k1', snapshot(_conversation(50)), now: true);
      await c.flush();
      expect((await c.read('m1/k1'))!.updates, hasLength(100));
    });

    test('a file lives under the directory the cache was given and nowhere else', () async {
      final c = cache();
      c.save('m 1/k:1', snapshot(_conversation(1)), now: true);
      await c.flush();
      expect(names(), ['m_1~k_1.tr']);
    });

    group('a file it cannot trust is ignored and deleted', () {
      Future<void> expectIgnored(String name, String content) async {
        final c = cache();
        File('${dir.path}/m1~k1.tr').writeAsStringSync(content);
        expect(await c.read('m1/k1'), isNull, reason: name);
        expect(names(), isEmpty, reason: '$name: the file is gone');
      }

      String header(Map<String, Object?> over, {int lines = 2}) =>
          jsonEncode({'v': 1, 'key': 'm1/k1', 'sid': 's1', 'asOf': 1, 'partial': false, 'lines': lines, ...over});

      test('garbage', () => expectIgnored('garbage', 'not a transcript\n'));
      test('empty', () => expectIgnored('empty', ''));
      test('an older or newer version', () async {
        final lines = _conversation(1);
        await expectIgnored('v0', '${header({'v': 0})}\n${lines.join('\n')}\n');
        await expectIgnored('v2', '${header({'v': 2})}\n${lines.join('\n')}\n');
      });
      test('a file for another key', () async {
        await expectIgnored('key', '${header({'key': 'm9/k9'})}\n${_conversation(1).join('\n')}\n');
      });
      test('cut short: fewer lines than the header says, or no final newline', () async {
        final lines = _conversation(2);
        await expectIgnored('fewer', '${header({}, lines: 4)}\n${lines.take(2).join('\n')}\n');
        await expectIgnored('no newline', '${header({})}\n${lines.take(2).join('\n')}');
      });
      test('a line that is not a session update', () async {
        await expectIgnored('line', '${header({})}\n${_conversation(1).first}\n{"jsonrpc":"2.0","method":"other","params":{}}\n');
        await expectIgnored('json', '${header({})}\n${_conversation(1).first}\n{broken\n');
      });
      test('a header without a session id or a time', () async {
        await expectIgnored('sid', '${header({'sid': ''})}\n${_conversation(1).join('\n')}\n');
        await expectIgnored('asOf', '${header({'asOf': 'noon'})}\n${_conversation(1).join('\n')}\n');
      });
      test('larger than any file this cache would have written', () async {
        final small = cache(session: 4096);
        final pad = 'x' * 8000;
        File('${dir.path}/m1~k1.tr').writeAsStringSync(
          '${header({}, lines: 2)}\n${_line('s1', _agent(pad))}\n${_line('s1', _agent('b'))}\n',
        );
        expect(await small.read('m1/k1'), isNull);
        expect(names(), isEmpty);
      });
    });

    test('a file is bounded: the oldest lines go first, and it is marked partial', () async {
      final c = cache(session: 6000);
      final lines = _conversation(100, pad: 'padding ' * 5);
      final all = lines.fold<int>(0, (n, l) => n + l.length + 1);
      expect(all, greaterThan(6000));
      c.save('m1/k1', snapshot(lines), now: true);
      await c.flush();
      final file = File('${dir.path}/m1~k1.tr');
      expect(file.lengthSync(), lessThanOrEqualTo(6000));
      final got = (await c.read('m1/k1'))!;
      expect(got.partial, isTrue);
      expect(got.updates.length, lessThan(200));
      final last = ((got.updates.last['update'] as Map)['content'] as Map)['text'] as String;
      expect(last, startsWith('answer 99'), reason: 'the newest lines are the ones kept');
    });

    test('non-ASCII text counts in bytes: a file stays inside its bound', () async {
      final c = cache(session: 8000);
      final lines = [for (var i = 0; i < 100; i++) _line('s1', _agent('Tiếng Việt – ${'日本語' * 10} $i', id: 'a$i'))];
      c.save('m1/k1', snapshot(lines), now: true);
      await c.flush();
      expect(File('${dir.path}/m1~k1.tr').lengthSync(), lessThanOrEqualTo(8000));
    });

    test('the directory is bounded: the session opened longest ago goes first', () async {
      final lines = _conversation(20, pad: 'pad ' * 20);
      final one = lines.fold<int>(0, (n, l) => n + l.length + 1) + 200;
      final c = cache(total: one * 3 + one ~/ 2);
      for (final k in ['a', 'b', 'c']) {
        c.save('m1/$k', snapshot(lines), now: true);
        await c.flush();
        // Distinct recency for the test (file times can tie within a tick).
        File('${dir.path}/m1~$k.tr').setLastModifiedSync(DateTime.now().subtract(Duration(minutes: {'a': 30, 'b': 20, 'c': 10}[k]!)));
      }
      expect(names(), ['m1~a.tr', 'm1~b.tr', 'm1~c.tr']);

      // Opening 'a' makes it the most recent one.
      expect(await c.read('m1/a'), isNotNull);
      c.save('m1/d', snapshot(lines), now: true);
      await c.flush();
      expect(names(), ['m1~a.tr', 'm1~c.tr', 'm1~d.tr'], reason: 'b was opened longest ago');
      final total = dir.listSync().whereType<File>().fold<int>(0, (n, f) => n + f.lengthSync());
      expect(total, lessThanOrEqualTo(one * 3 + one ~/ 2));
    });

    test('nothing to keep deletes the file', () async {
      final c = cache();
      c.save('m1/k1', snapshot(_conversation(2)), now: true);
      await c.flush();
      expect(names(), isNotEmpty);
      c.save('m1/k1', snapshot(const []), now: true);
      await c.flush();
      expect(names(), isEmpty);
    });

    group('writes', () {
      test('are debounced: a burst is one write, of the newest snapshot', () async {
        final c = cache(debounce: const Duration(milliseconds: 80));
        for (var i = 1; i <= 20; i++) {
          c.save('m1/k1', snapshot(_conversation(i)));
        }
        expect(c.writes, 0);
        expect(names(), isEmpty, reason: 'nothing is written while the debounce runs');
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await c.flush();
        expect(c.writes, 1);
        expect((await c.read('m1/k1'))!.updates, hasLength(40), reason: 'the newest of the twenty');
      });

      test('the wait is from the first ask: a stream of asks does not push the write away for ever', () async {
        final c = cache(debounce: const Duration(milliseconds: 50));
        // A stream of asks, ten times longer than the wait. If each ask
        // pushed the write away, nothing would be written while it lasts.
        final end = DateTime.now().add(const Duration(milliseconds: 500));
        while (DateTime.now().isBefore(end)) {
          c.save('m1/k1', snapshot(_conversation(1)));
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(c.writes, greaterThanOrEqualTo(1));
      });

      test('`now` writes at once and takes the waiting save with it', () async {
        final c = cache(debounce: const Duration(hours: 1));
        c.save('m1/k1', snapshot(_conversation(1)));
        c.save('m1/k1', snapshot(_conversation(2)), now: true);
        await c.flush();
        expect(c.writes, 1);
        expect((await c.read('m1/k1'))!.updates, hasLength(4));
        // Nothing left waiting an hour.
        await c.flush();
        expect(c.writes, 1);
      });

      test('are atomic: a write that dies leaves the old file whole and no temp file behind', () async {
        final c = cache();
        c.save('m1/k1', snapshot(_conversation(2)), now: true);
        await c.flush();
        final before = File('${dir.path}/m1~k1.tr').readAsStringSync();

        // The temp file cannot be made (its name is taken by a folder).
        Directory('${dir.path}/m1~k1.tr.tmp').createSync();
        c.save('m1/k1', snapshot(_conversation(9)), now: true);
        await c.flush();
        expect(File('${dir.path}/m1~k1.tr').readAsStringSync(), before, reason: 'the old file is untouched');
        expect((await c.read('m1/k1'))!.updates, hasLength(4));
        Directory('${dir.path}/m1~k1.tr.tmp').deleteSync();

        c.save('m1/k1', snapshot(_conversation(9)), now: true);
        await c.flush();
        expect((await c.read('m1/k1'))!.updates, hasLength(18));
        expect(names(), ['m1~k1.tr'], reason: 'the temp file was renamed away, not left');
      });

      test('writes of one session land in order', () async {
        final c = cache();
        for (var i = 1; i <= 5; i++) {
          c.save('m1/k1', snapshot(_conversation(i)), now: true);
        }
        await c.flush();
        expect((await c.read('m1/k1'))!.updates, hasLength(10), reason: 'the last ask wins');
      });

      test('a cache that cannot be written is only a cache that is not there', () async {
        final blocked = File('${dir.path}/file');
        blocked.writeAsStringSync('in the way');
        final c = FileTranscriptCache(() async => Directory('${blocked.path}/sub'), offload: inlineOffload);
        c.save('m1/k1', snapshot(_conversation(1)), now: true);
        await c.flush();
        expect(await c.read('m1/k1'), isNull);
      });
    });

    test('delete forgets one session, a pending write too; deleteMachine all of a machine', () async {
      final c = cache(debounce: const Duration(hours: 1));
      c.save('m1/k1', snapshot(_conversation(1)), now: true);
      c.save('m1/k2', snapshot(_conversation(1)), now: true);
      c.save('m2/k1', snapshot(_conversation(1)), now: true);
      await c.flush();
      expect(names(), ['m1~k1.tr', 'm1~k2.tr', 'm2~k1.tr']);

      c.save('m1/k1', snapshot(_conversation(3)));
      await c.delete('m1/k1');
      await c.flush();
      expect(names(), ['m1~k2.tr', 'm2~k1.tr'], reason: 'the waiting write did not bring it back');

      c.save('m1/k2', snapshot(_conversation(3)));
      await c.deleteMachine('m1');
      await c.flush();
      expect(names(), ['m2~k1.tr']);
    });

    test('retain drops the sessions of a machine that its host no longer has', () async {
      final c = cache();
      for (final k in ['k1', 'k2', 'k3']) {
        c.save('m1/$k', snapshot(_conversation(1)), now: true);
      }
      c.save('m2/k1', snapshot(_conversation(1)), now: true);
      await c.flush();
      await c.retain('m1', {'k1', 'k3'});
      expect(names(), ['m1~k1.tr', 'm1~k3.tr', 'm2~k1.tr']);
    });

    test('a temp file left by a write that died is swept once it is old', () async {
      final c = cache();
      final stale = File('${dir.path}/m1~dead.tr.tmp')..writeAsStringSync('half');
      stale.setLastModifiedSync(DateTime.now().subtract(const Duration(minutes: 5)));
      final fresh = File('${dir.path}/m1~busy.tr.tmp')..writeAsStringSync('being written');
      c.save('m1/k1', snapshot(_conversation(1)), now: true);
      await c.flush();
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue, reason: 'another write may be using it');
    });
  });
}

CachedTranscript _cached(List<String> lines, {String sid = 's1', Object? setup}) => CachedTranscript(
  sessionId: sid,
  asOf: DateTime.utc(2026, 3, 1),
  setup: setup,
  updates: [for (final l in lines) ((jsonDecode(l) as Map)['params'] as Map).cast<Object?, Object?>()],
);

class _NoRequests implements AcpClientHandler {
  @override
  Future<PermissionOutcome> requestPermission(PermissionRequest request, Future<void> cancelled) =>
      throw UnimplementedError();

  @override
  Future<ElicitationResponse> elicit(ElicitationRequest request, Future<void> cancelled) => throw UnimplementedError();
}
