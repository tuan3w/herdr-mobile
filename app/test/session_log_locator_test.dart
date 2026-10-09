import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/observed/claude_locator.dart';
import 'package:herdr_mobile/data/observed/codex_locator.dart';
import 'package:herdr_mobile/data/observed/session_log_locator.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

Pane _pane({String agent = 'claude', AgentSessionRef? session, String cwd = '/work/app'}) => Pane(
  id: 'w1:p1',
  workspaceId: 'w1',
  tabId: 'w1:t1',
  focused: false,
  cwd: cwd,
  title: '',
  agent: agent,
  status: AgentStatus.idle,
  session: session,
);

AgentSessionRef _ref(String agent, String kind, String value) => AgentSessionRef(agent: agent, kind: kind, value: value);

RemoteFiles _files(FakeFs fs) => RemoteFiles(FakeTransport()..fs = fs);

const _sid = '3f1c9a52-7d0e-4b6a-9a11-0c5d2e8b7f41';

Future<List<PaneProcess>> _noProcesses(String _) async => const [];

void main() {
  group('Claude', () {
    late ClaudeLocator locator;
    setUp(() => locator = ClaudeLocator());
    final inCwd = '/home/dev/.claude/projects/-work-app/$_sid.jsonl';

    test('a path from herdr is the log once the file exists, and not yet before the first message', () async {
      final pane = _pane(session: _ref('claude', 'path', inCwd));
      final before = await locator.locateWith(_files(FakeFs()), _noProcesses, pane);
      expect(before, isA<NotYet>(), reason: 'Claude writes the file with the first message');

      final fs = FakeFs()..addFile(inCwd, '{}\n');
      expect((await locator.locateWith(_files(fs), _noProcesses, pane) as Located).path, inCwd);
    });

    test('a session whose folders were all looked into is not scanned again on the next poll', () async {
      final fs = FakeFs()..addDir('/home/dev/.claude/projects/-other');
      final pane = _pane(session: _ref('claude', 'id', _sid));
      await locator.locateWith(_files(fs), _noProcesses, pane);
      fs.calls.clear();

      expect(await locator.locateWith(_files(fs), _noProcesses, pane), isA<NotYet>());
      expect(fs.calls.where((c) => c.startsWith('list')), isEmpty);
    });

    test('a path with .. or a control character is refused, not followed', () async {
      for (final bad in ['/home/dev/../etc/x.jsonl', '/home/dev/a\nb.jsonl', 'relative.jsonl']) {
        final found = await locator.locateWith(_files(FakeFs()), _noProcesses, _pane(session: _ref('claude', 'path', bad)));
        expect(found, isA<Unlinked>(), reason: bad);
      }
    });

    test('the running process wins over a session herdr reported earlier', () async {
      const other = '9d2e0c11-4a52-4f0e-8a3b-77aa11bb22cc';
      final stale = '/home/dev/.claude/projects/-work-app/$other.jsonl';
      final fs = FakeFs()
        ..addFile(stale, '{}\n')
        ..addFile(inCwd, '{}\n')
        ..addFile('/home/dev/.claude/sessions/4242.json', '{"pid":4242,"sessionId":"$_sid","cwd":"/work/app","kind":"interactive"}');

      final found = await locator.locateWith(
        _files(fs),
        (_) async => [const PaneProcess(pid: 4242, name: '2.1.293', argv0: 'claude')],
        _pane(session: _ref('claude', 'path', stale)),
      );

      expect((found as Located).path, inCwd);
    });

    test('with no process to ask, the reported session is used', () async {
      final fs = FakeFs()..addFile(inCwd, '{}\n');
      final found = await locator.locateWith(_files(fs), (_) => throw HerdrUnsupportedException('pane.process_info'), _pane(session: _ref('claude', 'path', inCwd)));
      expect((found as Located).path, inCwd);
    });

    test('an id is found in the folder its working directory names', () async {
      final fs = FakeFs()..addFile(inCwd, '{}\n');
      final found = await locator.locateWith(_files(fs), _noProcesses, _pane(session: _ref('claude', 'id', _sid)));
      expect((found as Located).path, inCwd);
    });

    test('an id is found by scanning the project folders when the cwd names another one', () async {
      final fs = FakeFs()
        ..addDir('/home/dev/.claude/projects/-other')
        ..addFile('/home/dev/.claude/projects/-private-work-app/$_sid.jsonl', '{}\n');
      final found = await locator.locateWith(_files(fs), _noProcesses, _pane(session: _ref('claude', 'id', _sid)));
      expect((found as Located).path, '/home/dev/.claude/projects/-private-work-app/$_sid.jsonl');
    });

    test('an id whose file is not there yet is "not yet", not a failure', () async {
      final fs = FakeFs()..addDir('/home/dev/.claude/projects/-work-app');
      final found = await locator.locateWith(_files(fs), _noProcesses, _pane(session: _ref('claude', 'id', _sid)));
      expect(found, isA<NotYet>());
    });

    test('without a session reference the running claude process names its session', () async {
      final fs = FakeFs()
        ..addFile('/home/dev/.claude/sessions/4242.json', '{"pid":4242,"sessionId":"$_sid","cwd":"/work/app","kind":"interactive"}')
        ..addFile(inCwd, '{}\n');
      final found = await locator.locateWith(
        _files(fs),
        (_) async => [
          const PaneProcess(pid: 1, name: 'zsh'),
          // An MCP helper with .claude in its path, and Claude itself, whose name herdr gives as the version.
          const PaneProcess(pid: 99, name: 'node', argv0: 'node', cmdline: 'node /home/dev/.claude/plugins/x/server.js'),
          const PaneProcess(pid: 4242, name: '2.1.293', argv0: 'claude', cmdline: 'claude --resume'),
        ],
        _pane(),
      );
      expect((found as Located).path, inCwd);
    });

    test('no reference and no pid file says how to link it', () async {
      final found = await locator.locateWith(
        _files(FakeFs()),
        (_) async => [const PaneProcess(pid: 4242, name: 'claude')],
        _pane(),
      );
      expect((found as Unlinked).why, contains('herdr integration install claude'));
    });

    test('an old herdr without pane.process_info is unlinked, not an error', () async {
      final found = await locator.locateWith(_files(FakeFs()), (_) => throw HerdrUnsupportedException('pane.process_info'), _pane());
      expect(found, isA<Unlinked>());
    });

    test('a pid file that is not an interactive session, belongs to another pid, or has a bad id, is not used', () async {
      for (final body in [
        '{"pid":7,"sessionId":"$_sid","cwd":"/work/app","kind":"interactive"}',
        '{"pid":4242,"sessionId":"$_sid","cwd":"/work/app","kind":"sdk"}',
        '{"pid":4242,"sessionId":"../../x","cwd":"/work/app","kind":"interactive"}',
        'not json',
      ]) {
        final fs = FakeFs()..addFile('/home/dev/.claude/sessions/4242.json', body);
        final found = await locator.locateWith(_files(fs), (_) async => [const PaneProcess(pid: 4242, name: 'claude')], _pane());
        expect(found, isA<Unlinked>(), reason: body);
      }
    });

    test('the board offers the chat for any claude pane', () {
      expect(locator.mayLocate(_pane()), isTrue);
      expect(locator.mayLocate(_pane(agent: 'omp')), isFalse);
    });
  });

  group('Codex', () {
    // 2026-09-06T14:03:17.xxxZ, a UUIDv7.
    const id = '01a07707-d5c0-7b3a-8c11-5d0e2f9a4b67';

    String rollout(String stamp, [String ext = 'jsonl']) => 'rollout-$stamp-$id.$ext';

    test('a v7 id is found in the day folder of its creation time', () async {
      final fs = FakeFs()..addFile('/home/dev/.codex/sessions/2026/09/06/${rollout('2026-09-06T21-03-17')}', '{}\n');
      final locator = CodexLocator();
      final found = await locator.locateWith(_files(fs), _pane(agent: 'codex', session: _ref('codex', 'id', id)));
      expect((found as Located).path, '/home/dev/.codex/sessions/2026/09/06/${rollout('2026-09-06T21-03-17')}');
      expect(fs.calls.where((c) => c.startsWith('list')).length, lessThanOrEqualTo(2), reason: 'no scan');
    });

    test('and in the next day folder when the host clock is ahead of UTC', () async {
      final fs = FakeFs()..addFile('/home/dev/.codex/sessions/2026/09/07/${rollout('2026-09-07T05-03-17')}', '{}\n');
      final found = await CodexLocator().locateWith(_files(fs), _pane(agent: 'codex', session: _ref('codex', 'id', id)));
      expect(found, isA<Located>());
    });

    test('an id that is not v7 is found by walking the date folders, newest first, within 40 listings', () async {
      const old = '00000000-0000-4000-8000-0123456789ab';
      final fs = FakeFs()..addFile('/home/dev/.codex/sessions/2025/03/02/rollout-2025-03-02T10-00-00-$old.jsonl', '{}\n');
      for (var d = 1; d <= 9; d++) {
        fs.addFile('/home/dev/.codex/sessions/2026/09/0$d/rollout-2026-09-0$d-other.jsonl', '{}\n');
      }
      final found = await CodexLocator().locateWith(_files(fs), _pane(agent: 'codex', session: _ref('codex', 'id', old)));
      expect(found, isA<Located>());
      expect(fs.calls.where((c) => c.startsWith('list')).length, lessThanOrEqualTo(CodexLocator.maxLists));
    });

    test('a session only found compressed says to resume it', () async {
      final fs = FakeFs()..addFile('/home/dev/.codex/sessions/2026/09/06/${rollout('2026-09-06T21-03-17', 'jsonl.zst')}', 'x');
      final found = await CodexLocator().locateWith(_files(fs), _pane(agent: 'codex', session: _ref('codex', 'id', id)));
      expect((found as Unlinked).why, contains('Resume it in Codex'));
    });

    test('nothing yet is "not yet": Codex writes the file with the first prompt', () async {
      final fs = FakeFs()..addDir('/home/dev/.codex/sessions');
      final found = await CodexLocator().locateWith(_files(fs), _pane(agent: 'codex', session: _ref('codex', 'id', id)));
      expect(found, isA<NotYet>());
    });

    test('a pane with no session reference cannot be linked and says how', () async {
      final locator = CodexLocator();
      expect(locator.mayLocate(_pane(agent: 'codex')), isFalse);
      final found = await locator.locateWith(_files(FakeFs()), _pane(agent: 'codex'));
      expect((found as Unlinked).why, contains('herdr integration install codex'));
    });

    test('an id that is not a uuid never reaches a path', () async {
      final fs = FakeFs();
      final found = await CodexLocator().locateWith(_files(fs), _pane(agent: 'codex', session: _ref('codex', 'id', '../../etc/passwd')));
      expect(found, isA<NotYet>());
      expect(fs.calls, isEmpty);
    });

    test('a found file is remembered: the second look lists nothing', () async {
      final fs = FakeFs()..addFile('/home/dev/.codex/sessions/2026/09/06/${rollout('2026-09-06T21-03-17')}', '{}\n');
      final locator = CodexLocator();
      final pane = _pane(agent: 'codex', session: _ref('codex', 'id', id));
      await locator.locateWith(_files(fs), pane, machineId: 'm');
      fs.calls.clear();
      expect(await locator.locateWith(_files(fs), pane, machineId: 'm'), isA<Located>());
      expect(fs.calls, isEmpty);
    });
  });
}
