// An omp subagent's conversation, read best-effort from the log omp keeps of it
// on the host (SFTP only): the path it is read from, the incremental read and
// its caps, the cases that must leave the run a plain summary, and the
// cadence (nothing runs unless a screen asks).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_log_path.dart';
import 'package:herdr_mobile/data/acp/subagents/subagent_run.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/subagent_transcripts.dart';
import 'package:herdr_mobile/data/services/remote_files.dart';

import 'support/fake_fs.dart';
import 'support/fake_transport.dart';

const _sid = '01a10ae2-9247-7303-bcff-280a4fc94489';
const _cwd = '/tmp/scratch';
const _project = '/home/dev/.omp/agent/sessions/-tmp-scratch';
const _sessionFile = '$_project/2026-10-05T07-06-23-175Z_$_sid.jsonl';
const _artifactDir = '$_project/2026-10-05T07-06-23-175Z_$_sid';
const _logPath = '$_artifactDir/PongReply.jsonl';

/// The log of a real `task` subagent PongReply (omp 18.4.12, an ACP session).
final _real = File('test/fixtures/omp_logs/subagent_artifact_acp.jsonl').readAsLinesSync();

String _text(Iterable<String> lines) => '${lines.join('\n')}\n';

RemoteFiles _files(FakeFs? fs) => RemoteFiles(FakeTransport()..fs = fs);

/// A host that has the parent session file and, when [log] is given, the
/// subagent's log.
FakeFs _host({Object? log, bool session = true}) {
  final fs = FakeFs();
  if (session) fs.addFile(_sessionFile, '{"type":"session","version":3}\n');
  fs.addDir(_artifactDir);
  if (log != null) fs.addFile(_logPath, log);
  return fs;
}

SubagentRun _run({String? name = 'PongReply', SubagentStatus status = SubagentStatus.running, SubagentRoute route = SubagentRoute.omp}) =>
    SubagentRun(id: 'call#0', route: route, parentToolCallId: 'call', name: name, status: status);

/// One controller over [fs], with the run the reducer would hold in [run].
class _Rig {
  _Rig(FakeFs? fs, {SubagentRun? run, this.reader, String? sid = _sid}) : run = run ?? _run() {
    this.fs = fs;
    controller = SubagentTranscripts(
      files: _files(fs),
      sessionId: () => sid,
      cwd: _cwd,
      runOf: (id) => id == this.run.id ? this.run : null,
      onChange: () => changes++,
      readerFor: reader == null ? null : (path, parent) => reader!(_files(fs), path, parent),
    );
  }

  late final FakeFs? fs;
  late final SubagentTranscripts controller;
  SubagentRun run;
  final SubagentLogReader Function(RemoteFiles files, String path, String? parent)? reader;
  var changes = 0;

  SubagentLogStatus get status => controller.status(run.id);
  SubagentRun get shown => controller.overlay.run(run)!;
  List<String> get calls => fs!.calls;
  List<String> get reads => [for (final c in calls) if (c.startsWith('read ')) c];

  void watch([bool on = true]) => controller.watch(run.id, on);
}

/// Runs [body] on a fake clock; the rig is disposed afterwards.
void _rigTest(String name, FakeFs? Function() fs, void Function(_Rig r, FakeAsync async) body, {SubagentRun? run, SubagentLogReader Function(RemoteFiles, String, String?)? reader}) =>
    test(name, () {
      fakeAsync((async) {
        final r = _Rig(fs(), run: run, reader: reader);
        body(r, async);
        r.controller.dispose();
      });
    });

void _settle(FakeAsync async) {
  async.elapse(const Duration(milliseconds: 20));
  async.flushMicrotasks();
}

void _tick(FakeAsync async) {
  async.elapse(const Duration(seconds: 3));
  _settle(async);
}

List<TranscriptTool> _tools(AgentSessionState s) => s.items.whereType<TranscriptTool>().toList();

String _entry(String id, String role, String text) => jsonEncode({
  'type': 'message',
  'id': id,
  'message': {
    'role': role,
    'content': [
      {'type': 'text', 'text': text},
    ],
  },
});

String _header({Object? version = 3, String? parent = '$_artifactDir.jsonl'}) =>
    jsonEncode({'type': 'session', 'version': version, 'id': 'x', 'cwd': _cwd, 'parentSession': ?parent});

void main() {
  group('the name that picks the file', () {
    test('plain ids are accepted', () {
      for (final n in ['PongReply', 'Anna-2', 'Anna.Bob', 'a_b', 'x', 'Fix3']) {
        expect(validSubagentName(n), n, reason: n);
      }
    });

    test('a separator, a dot-dot, a leading dot, an absolute path, an extension: refused', () {
      final bad = <String?>[
        null,
        '',
        '../x',
        '..',
        'a/b',
        '/etc/passwd',
        r'a\b',
        'x/../y',
        'a..b',
        '.hidden',
        'x.',
        'x.jsonl',
        'x y',
        'a\u0000b',
        '%2e%2e',
        'é',
        'a' * (maxSubagentNameLength + 1),
      ];
      for (final n in bad) {
        expect(validSubagentName(n), isNull, reason: '$n');
        expect(subagentLogPath('/d/artifacts', n), isNull, reason: '$n');
      }
    });

    test('the path is the artifact dir, one segment, .jsonl', () {
      expect(subagentLogPath('/d/a', 'PongReply'), '/d/a/PongReply.jsonl');
      expect(subagentLogPath('/d/a', 'Anna.Bob'), '/d/a/Anna.Bob.jsonl');
    });

    test('a directory that is not an absolute, clean path gives none', () {
      for (final d in ['', '/', 'rel/dir', '/d/a/', '/d/\u0000']) {
        expect(subagentLogPath(d, 'x'), isNull, reason: d);
      }
    });
  });

  group('finding the artifact folder', () {
    test('omp\'s folder names for a directory', () {
      List<String> n(String cwd, {String home = '/home/dev', String tmp = '/tmp'}) =>
          OmpSessionLocator.projectFolderNames(cwd, home: home, tmp: tmp);
      expect(n('/tmp/scratch'), ['-tmp-scratch', '--tmp-scratch--']);
      expect(n('/home/dev/proj/x'), ['-proj-x', '--home-dev-proj-x--']);
      expect(n('/home/dev'), ['-', '--home-dev--']);
      expect(n('/srv/a:b'), ['--srv-a-b--']);
      expect(
        n('/home/dev/scratchtmp/x', tmp: '/home/dev/scratchtmp'),
        ['-tmp-x', '-scratchtmp-x', '--home-dev-scratchtmp-x--'],
        reason: 'a temp dir inside home: tmp first, home is the shadowed name',
      );
    });

    test('finds the session file by its id and returns the folder without .jsonl', () async {
      final fs = _host();
      fs.addFile('$_project/2026-10-05T07-00-00-000Z_other-session-id-1234.jsonl', '{}\n');
      expect(await OmpSessionLocator(_files(fs)).artifactDir(sessionId: _sid, cwd: _cwd), _artifactDir);
    });

    test('another session in the same project is not taken', () async {
      final fs = FakeFs()..addFile('$_project/2026-10-05T07-00-00-000Z_other-session-id-1234.jsonl', '{}\n');
      expect(await OmpSessionLocator(_files(fs)).artifactDir(sessionId: _sid, cwd: _cwd), isNull);
    });

    test('a temp dir elsewhere: the folder whose name holds the directory\'s own name', () async {
      final fs = _host();
      expect(await OmpSessionLocator(_files(fs)).artifactDir(sessionId: _sid, cwd: '/var/tmp/scratch'), _artifactDir);
    });

    test('XDG sessions root', () async {
      final fs = FakeFs()..addFile('/home/dev/.local/share/omp/sessions/-tmp-scratch/2026-10-05T07-06-23-175Z_$_sid.jsonl', '{}\n');
      expect(
        await OmpSessionLocator(_files(fs)).artifactDir(sessionId: _sid, cwd: _cwd),
        '/home/dev/.local/share/omp/sessions/-tmp-scratch/2026-10-05T07-06-23-175Z_$_sid',
      );
    });

    test('an id or a directory that is not plain is not searched for', () async {
      final fs = _host();
      final locator = OmpSessionLocator(_files(fs));
      expect(await locator.artifactDir(sessionId: '../x', cwd: _cwd), isNull);
      expect(await locator.artifactDir(sessionId: _sid, cwd: 'relative'), isNull);
      expect(fs.calls, isEmpty);
    });
  });

  group('the real log', () {
    test('maps to the conversation of the subagent', () async {
      final fs = _host(log: _text(_real));
      final reader = SubagentLogReader(_files(fs), _logPath, expectedParent: RemotePath.basename(_artifactDir));
      expect(await reader.poll(), LogPoll.updated);
      final s = reader.state;
      final messages = s.items.whereType<TranscriptMessage>().toList();
      expect(messages.first.role, MessageRole.user);
      expect(messages.first.text, 'Complete assignment thoroughly:\n\nReply with the word pong and nothing else.');
      final yielded = _tools(s).single.call;
      expect(yielded.name, 'yield');
      expect(yielded.status, ToolStatus.completed);
      expect(reader.earlierNotShown, isFalse);
      expect(reader.skippedLines, 0);
    });

    test('the run\'s name from the recorded progress is the file name', () {
      final updates = (jsonDecode(File('test/fixtures/omp_logs/acp_task_updates.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
      var state = const AgentSessionState('s');
      for (final u in updates) {
        state = state.apply(SessionUpdate.parse(u));
      }
      final run = state.subagents.single;
      expect(run.route, SubagentRoute.omp);
      expect(run.name, 'PongReply');
      expect(run.status, SubagentStatus.finished);
      expect(run.hasTranscript, isFalse, reason: 'the reducer never makes one for omp');
      expect(subagentLogPath(_artifactDir, run.name), _logPath);
    });
  });

  group('showing it', () {
    _rigTest('a valid artifact gives a transcript that says where it came from', () => _host(log: _text(_real)), (r, async) {
      r.watch();
      expect(r.status, SubagentLogStatus.loading, reason: 'the first read is under way');
      _settle(async);

      expect(r.status, SubagentLogStatus.shown);
      expect(r.shown.hasTranscript, isTrue);
      expect(r.shown.log, isNotNull);
      expect(r.shown.log!.earlierNotShown, isFalse);
      expect(_tools(r.shown.transcript!).single.call.name, 'yield');
      expect(r.changes, greaterThan(0));
      // Only the parent's folders and the one log were touched, by name.
      for (final c in r.calls) {
        final path = c.substring(c.indexOf(' ') + 1).split('@').first;
        expect(
          path == '.' || path.startsWith('/home/dev/.omp/agent/sessions') || path == '/home/dev/.omp/agent/sessions' || path == _cwd || path == '/home/dev/.local/share/omp/sessions',
          isTrue,
          reason: c,
        );
      }
      expect(r.reads, everyElement(startsWith('read $_logPath@')));
    });

    _rigTest('the same run object comes back while nothing changed; a Claude transcript is never replaced', () => _host(log: _text(_real)), (r, async) {
      r.watch();
      _settle(async);
      final a = r.shown;
      expect(identical(r.controller.overlay.run(r.run), a), isTrue);
      final own = SubagentRun(id: 'c', route: SubagentRoute.claude, parentToolCallId: 'c', transcript: const AgentSessionState('own'));
      expect(identical(r.controller.overlay.run(own), own), isTrue);
    });

    _rigTest('a log that grows is read from where it ended, while the run is active', () => _host(log: _text(_real.take(7))), (r, async) {
      r.watch();
      _settle(async);
      expect(r.shown.items.whereType<TranscriptMessage>(), hasLength(2));
      expect(_tools(r.shown.transcript!).single.call.status, ToolStatus.inProgress, reason: 'the yield has no result in the log yet');
      final firstBytes = utf8.encode(_text(_real.take(7))).length;
      final before = r.shown;

      r.fs!.addFile(_logPath, _text(_real));
      r.calls.clear();
      _tick(async);

      expect(_tools(r.shown.transcript!).single.call.status, ToolStatus.completed);
      expect(identical(r.shown, before), isFalse);
      expect(r.reads, hasLength(1));
      expect(r.reads.single, startsWith('read $_logPath@$firstBytes+'), reason: 'not read again from the start');
    });

    _rigTest('an unchanged log is only stat\'ed on each tick', () => _host(log: _text(_real.take(7))), (r, async) {
      r.watch();
      _settle(async);
      final before = r.shown;
      r.calls.clear();
      _tick(async);
      _tick(async);
      expect(r.calls, ['stat $_logPath', 'stat $_logPath']);
      expect(identical(r.shown, before), isTrue);
    });

    _rigTest('a half-written last line waits for its end', () {
      final whole = _text(_real.take(7));
      return _host(log: whole.substring(0, whole.length - 40));
    }, (r, async) {
      r.watch();
      _settle(async);
      final count = r.shown.items.length;
      expect(count, lessThan(3), reason: 'the unfinished assistant line is not mapped');
      r.fs!.addFile(_logPath, _text(_real.take(7)));
      _tick(async);
      expect(r.shown.items.length, greaterThan(count));
      expect(r.shown.items.whereType<TranscriptMessage>().where((m) => m.role == MessageRole.thought), hasLength(1));
    });

    _rigTest('a log replaced by a shorter one starts over', () => _host(log: _text(_real)), (r, async) {
      r.watch();
      _settle(async);
      r.fs!.addFile(_logPath, _text(_real.take(6)));
      _tick(async);
      expect(_tools(r.shown.transcript!), isEmpty);
      expect(r.shown.items.whereType<TranscriptMessage>(), hasLength(1));
    });
  });

  group('cadence', () {
    _rigTest('nothing is read before a screen asks, and nothing after it leaves', () => _host(log: _text(_real.take(7))), (r, async) {
      async.elapse(const Duration(minutes: 2));
      expect(r.calls, isEmpty, reason: 'never opened');
      expect(async.pendingTimers, isEmpty);

      r.watch();
      _settle(async);
      expect(r.calls, isNotEmpty);
      expect(async.pendingTimers, hasLength(1));

      r.watch(false);
      expect(async.pendingTimers, isEmpty);
      r.calls.clear();
      async.elapse(const Duration(minutes: 2));
      expect(r.calls, isEmpty);
    });

    _rigTest('two screens count: the timer stays until the last one leaves', () => _host(log: _text(_real.take(7))), (r, async) {
      r.watch();
      r.watch();
      r.watch(false);
      expect(async.pendingTimers, hasLength(1));
      r.watch(false);
      expect(async.pendingTimers, isEmpty);
    });

    _rigTest('a finished run is read once when opened, not on every tick', () => _host(log: _text(_real)), (r, async) {
      r.run = _run(status: SubagentStatus.finished);
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.shown);
      r.calls.clear();
      async.elapse(const Duration(seconds: 30));
      expect(r.calls, isEmpty);
    });

    _rigTest('a run that ends gets one more read, then none', () => _host(log: _text(_real.take(7))), (r, async) {
      r.watch();
      _settle(async);
      r.fs!.addFile(_logPath, _text(_real));
      r.run = _run(status: SubagentStatus.finished);
      r.calls.clear();
      _tick(async);
      expect(_tools(r.shown.transcript!).single.call.status, ToolStatus.completed, reason: 'the last entries are in');
      r.calls.clear();
      async.elapse(const Duration(seconds: 30));
      expect(r.calls, isEmpty);
    });

    _rigTest('opening a finished run again reads what was added since', () => _host(log: _text(_real.take(7))), (r, async) {
      r.run = _run(status: SubagentStatus.finished);
      r.watch();
      _settle(async);
      r.watch(false);
      r.fs!.addFile(_logPath, _text(_real));
      r.calls.clear();
      r.watch();
      _settle(async);
      expect(r.reads, hasLength(1));
      expect(_tools(r.shown.transcript!).single.call.status, ToolStatus.completed);
    });

    _rigTest('a call that has not started has no id yet: nothing is read', () => _host(log: _text(_real)), (r, async) {
      r.run = _run(status: SubagentStatus.waiting);
      r.watch();
      _settle(async);
      expect(r.calls, isEmpty);
      expect(r.status, SubagentLogStatus.idle);
    });

    _rigTest('another agent\'s run is not touched', () => _host(log: _text(_real)), (r, async) {
      r.run = _run(route: SubagentRoute.codex);
      r.watch();
      _settle(async);
      expect(r.calls, isEmpty);
      expect(r.status, SubagentLogStatus.idle);
    });
  });

  group('the summary stays', () {
    for (final name in ['../x', '..', 'a/b', '/etc/passwd', r'a\b', 'x/../y', 'x.jsonl', '.hidden', '', 'a b']) {
      _rigTest('a name the agent made up (${jsonEncode(name)}) reads nothing', () => _host(log: _text(_real)), (r, async) {
        r.run = _run(name: name);
        r.watch();
        _settle(async);
        expect(r.calls, isEmpty, reason: 'no SFTP call of any kind');
        expect(r.status, SubagentLogStatus.unavailable);
        expect(r.shown.hasTranscript, isFalse);
        expect(r.controller.overlay.isEmpty, isTrue);
      });
    }

    _rigTest('no name', () => _host(log: _text(_real)), (r, async) {
      r.run = _run(name: null);
      r.watch();
      _settle(async);
      expect(r.calls, isEmpty);
      expect(r.status, SubagentLogStatus.unavailable);
    });

    _rigTest('no such log', () => _host(), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
      expect(r.shown.hasTranscript, isFalse);
    });

    _rigTest('no session file on the host', () => _host(session: false, log: _text(_real)), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
      r.calls.clear();
      _tick(async);
      expect(r.calls, isEmpty, reason: 'not found is believed for a few ticks, not searched for on every one');
    });

    _rigTest('a host without SFTP', () => null, (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
      expect(r.shown.hasTranscript, isFalse);
      _tick(async);
      expect(r.status, SubagentLogStatus.unavailable);
    });

    _rigTest('a log the user may not read', () {
      final fs = _host(log: _text(_real))..deny.add(_logPath);
      return fs;
    }, (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable, reason: 'permission will not change: no retry offer');
    });

    _rigTest('a format version this app does not know', () => _host(log: _text([_header(version: 4), ..._real.skip(2)])), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
      expect(r.shown.hasTranscript, isFalse);
    });

    _rigTest('no version at all', () => _host(log: _text([_header(version: null), ..._real.skip(2)])), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
    });

    _rigTest('a log of another parent session', () => _host(log: _text([_header(parent: '/x/other-session.jsonl'), ..._real.skip(2)])), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
    });

    _rigTest('a file that is not a log', () => _host(log: 'hello\nworld\n{"a":1}\n[1,2]\nnull\n'), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
      expect(r.shown.hasTranscript, isFalse);
    });

    _rigTest('a log with a header and nothing that maps', () => _host(log: _text([_header(), '{"type":"model_change","id":"a"}'])), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
    });

    _rigTest('a binary file', () => _host(log: Uint8List.fromList(List.generate(3000, (i) => (i * 31) % 256))), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
    });

    _rigTest('a directory where the log should be', () {
      final fs = _host();
      fs.addDir(_logPath);
      return fs;
    }, (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
    });

    _rigTest('an empty log of a running subagent is looked at again', () => _host(log: ''), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
      r.fs!.addFile(_logPath, _text(_real));
      _tick(async);
      expect(r.status, SubagentLogStatus.shown);
    });

    _rigTest('a log that appears later is found for a running subagent', () => _host(), (r, async) {
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.unavailable);
      r.fs!.addFile(_logPath, _text(_real));
      _tick(async);
      expect(r.status, SubagentLogStatus.shown);
    });
  });

  group('when the connection fails', () {
    _rigTest('failed, with the summary kept; a retry reads again', () => _host(log: _text(_real)), (r, async) {
      r.fs!.fail = RemoteFileException(RemoteFileErrorKind.network, 'down');
      r.watch();
      _settle(async);
      expect(r.status, SubagentLogStatus.failed);
      expect(r.shown.hasTranscript, isFalse);

      r.fs!.fail = null;
      r.controller.retry(r.run.id);
      _settle(async);
      expect(r.status, SubagentLogStatus.shown);
    });

    _rigTest('a transcript already shown survives a failed refresh', () => _host(log: _text(_real.take(7))), (r, async) {
      r.watch();
      _settle(async);
      final shown = r.shown;
      r.fs!.fail = RemoteFileException(RemoteFileErrorKind.network, 'down');
      _tick(async);
      expect(r.status, SubagentLogStatus.shown);
      expect(identical(r.shown, shown), isTrue);
    });

    _rigTest('a failed read of a running subagent is tried again on the next tick', () => _host(log: _text(_real)), (r, async) {
      r.fs!.fail = RemoteFileException(RemoteFileErrorKind.network, 'down');
      r.watch();
      _settle(async);
      r.fs!.fail = null;
      _tick(async);
      expect(r.status, SubagentLogStatus.shown);
    });

    _rigTest('a failed read of a finished subagent is not settled: it stays retryable', () => _host(log: _text(_real)), (r, async) {
      r.run = _run(status: SubagentStatus.finished);
      r.fs!.fail = RemoteFileException(RemoteFileErrorKind.network, 'down');
      r.watch();
      _settle(async);
      r.fs!.fail = null;
      _tick(async);
      expect(r.status, SubagentLogStatus.shown);
    });

    _rigTest('a read that finishes after the session is gone shows nothing', () => _host(log: _text(_real)), (r, async) {
      r.fs!.gate = Completer<void>();
      r.watch();
      _settle(async);
      r.controller.dispose();
      r.fs!.gate!.complete();
      _settle(async);
      expect(r.controller.overlay.isEmpty, isTrue);
    });
  });

  group('caps', () {
    SubagentLogReader reader(FakeFs fs, {int bytes = 1024 * 1024, int lines = 4000, int line = 256 * 1024}) =>
        SubagentLogReader(_files(fs), _logPath, expectedParent: RemotePath.basename(_artifactDir), maxReadBytes: bytes, maxLines: lines, maxLineBytes: line);

    List<String> many(int n, {String prefix = 'm'}) => [for (var i = 0; i < n; i++) _entry('$prefix$i', 'user', 'message number $i')];

    test('a long log is read from its tail, from a line boundary, and says the start is missing', () async {
      final body = [_header(), ...many(400)];
      final fs = _host(log: _text(body));
      final r = reader(fs, bytes: 8000);
      expect(await r.poll(), LogPoll.updated);
      expect(r.earlierNotShown, isTrue);
      final texts = [for (final m in r.state.items.whereType<TranscriptMessage>()) m.text];
      expect(texts.last, 'message number 399');
      expect(texts.first, startsWith('message number '));
      expect(texts.length, lessThan(400));
      expect(texts.length, greaterThan(20));
      // Every line that was mapped is a whole one: consecutive numbers to the end.
      final first = int.parse(texts.first.split(' ').last);
      expect(texts, [for (var i = first; i < 400; i++) 'message number $i']);
      expect(fs.calls.where((c) => c.startsWith('read ')).every((c) => !c.contains('+${1024 * 1024}')), isTrue);
    });

    test('the header is checked on a log whose start is cut off', () async {
      final body = [_header(version: 9), ...many(400)];
      final r = reader(_host(log: _text(body)), bytes: 8000);
      expect(await r.poll(), LogPoll.unusable);
      expect(r.state.items, isEmpty);
    });

    test('a line cap keeps the newest lines', () async {
      final r = reader(_host(log: _text([_header(), ...many(100)])), lines: 10);
      await r.poll();
      expect(r.state.items.whereType<TranscriptMessage>(), hasLength(10));
      expect(r.earlierNotShown, isTrue);
      expect(r.state.items.whereType<TranscriptMessage>().last.text, 'message number 99');
    });

    test('a line over the size cap is skipped and counted, its neighbours are shown', () async {
      final huge = _entry('big', 'user', 'x' * 5000);
      final r = reader(_host(log: _text([_header(), _entry('a', 'user', 'first'), huge, _entry('b', 'user', 'last')])), line: 2000);
      await r.poll();
      expect([for (final m in r.state.items.whereType<TranscriptMessage>()) m.text], ['first', 'last']);
      expect(r.skippedLines, 1);
      expect(r.info.skippedLines, 1);
      expect(r.earlierNotShown, isFalse);
    });

    test('an oversized line still being written is skipped until it ends', () async {
      final fs = _host(log: '${_text([_header(), _entry('a', 'user', 'first')])}${'y' * 3000}');
      final r = reader(fs, line: 2000);
      await r.poll();
      expect(r.skippedLines, 1);
      fs.addFile(_logPath, '${_text([_header(), _entry('a', 'user', 'first')])}${'y' * 3000}${'z' * 10}\n${_entry('b', 'user', 'after')}\n');
      await r.poll();
      expect([for (final m in r.state.items.whereType<TranscriptMessage>()) m.text], ['first', 'after']);
      expect(r.skippedLines, 1, reason: 'one line, counted once');
    });

    test('items stay under the cap, the cut is counted', () async {
      final n = SubagentRun.maxItems + 300;
      final r = reader(_host(log: _text([_header(), ...many(n)])));
      await r.poll();
      expect(r.state.items, hasLength(SubagentRun.maxItems));
      expect(r.droppedItems, 300);
      expect((r.state.items.last as TranscriptMessage).text, 'message number ${n - 1}');
    });

    test('a log that grew by more than the cap since the last read starts over from its tail', () async {
      final fs = _host(log: _text([_header(), ...many(10)]));
      final r = reader(fs, bytes: 6000);
      await r.poll();
      fs.addFile(_logPath, _text([_header(), ...many(10), ...many(300, prefix: 'n')]));
      expect(await r.poll(), LogPoll.updated);
      expect(r.earlierNotShown, isTrue);
      expect((r.state.items.last as TranscriptMessage).text, 'message number 299');
    });

    test('odd lines never throw', () async {
      final lines = [
        _header(),
        '{',
        'null',
        '[1,2]',
        '"text"',
        '{"type":"message"}',
        '{"type":"message","message":{"role":"assistant","content":7}}',
        '{"type":"message","message":{"role":"assistant","content":[{"type":"toolCall"}]}}',
        '{"type":"custom","customType":5}',
        _entry('ok', 'user', 'survivor'),
      ];
      final bytes = BytesBuilder()
        ..add(utf8.encode('${lines.join('\n')}\n'))
        ..add([0xFF, 0xFE, 0x0A])
        ..add(utf8.encode('${_entry('ok2', 'user', 'after the bad bytes')}\n'));
      final r = reader(_host(log: bytes.takeBytes()));
      expect(await r.poll(), LogPoll.updated);
      final texts = [for (final m in r.state.items.whereType<TranscriptMessage>()) m.text];
      expect(texts, containsAll(['survivor', 'after the bad bytes']));
    });

    test('a host that answers a read in short pieces is read to the end', () async {
      final fs = _host(log: _text([_header(), ...many(50)]));
      final files = RemoteFiles(_ShortReads()..fs = fs);
      final r = SubagentLogReader(files, _logPath, expectedParent: RemotePath.basename(_artifactDir));
      expect(await r.poll(), LogPoll.updated);
      expect(r.state.items.whereType<TranscriptMessage>(), hasLength(50));
      expect(fs.calls.where((c) => c.startsWith('read ')).length, greaterThan(10));
    });
  });
}

/// A transport that never returns more than 100 bytes from one read, as an
/// SFTP server may.
class _ShortReads extends FakeTransport {
  @override
  Future<Uint8List> readFile(String path, {int offset = 0, int length = remoteReadCap}) =>
      super.readFile(path, offset: offset, length: length < 100 ? length : 100);
}
