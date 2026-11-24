import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/path_hints.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/path_finder.dart';
import 'package:herdr_mobile/ui/features/files/files_navigation.dart';

import 'support/fake_fs.dart';
import 'support/files_support.dart';

const _cwd = '/work/proj';

var _n = 0;

TranscriptItem _run(String command, {String? cwd, Map<String, Object?> input = const {}}) => TranscriptTool(
  ToolCall(
    toolCallId: 't${_n++}',
    kind: ToolKind.execute,
    status: ToolStatus.completed,
    rawInput: {'command': command, ...input},
    meta: cwd == null
        ? null
        : {
            'terminal_info': {'cwd': cwd},
          },
  ),
);

TranscriptItem _touch(String path, {ToolKind kind = ToolKind.read}) => TranscriptTool(
  ToolCall(
    toolCallId: 't${_n++}',
    kind: kind,
    status: ToolStatus.completed,
    locations: [ToolLocation(path: path)],
  ),
);

FakeFs _fs() => FakeFs()..addDir(_cwd);

void main() {
  group('pathHintsOf', () {
    test('lists the folders calls ran in and the files they touched, newest first', () {
      final hints = pathHintsOf([
        _touch('/work/proj/app/lib/old.dart'),
        _run('ls', cwd: '/work/proj/backend'),
        _run('cd tools && make', input: {'cwd': '/work/other'}),
        _touch('/work/proj/app/lib/new.dart'),
      ], cwd: _cwd);

      expect(hints.touched, ['/work/proj/app/lib/new.dart', '/work/proj/app/lib/old.dart']);
      expect(hints.folders, ['/work/other/tools', '/work/other', '/work/proj/backend']);
    });

    test('a cd moves where the command ran; the session folder itself is not a hint', () {
      final hints = pathHintsOf([_run('cd /work/proj && ls'), _run('cd app/ui; cd ../data && ls')], cwd: _cwd);

      expect(hints.folders, ['/work/proj/app/data']);
    });

    test('a relative path in a call is taken against the folder that call ran in', () {
      final hints = pathHintsOf([
        TranscriptTool(
          ToolCall(
            toolCallId: 'x',
            kind: ToolKind.read,
            status: ToolStatus.completed,
            rawInput: {'cwd': '/work/proj/app', 'path': 'lib/a.dart'},
          ),
        ),
      ], cwd: _cwd);

      expect(hints.touched, ['/work/proj/app/lib/a.dart']);
    });

    test('only the newest calls are read', () {
      final items = [_touch('/work/proj/ancient.txt'), for (var i = 0; i < 400; i++) _touch('/work/proj/f$i.txt')];
      final hints = pathHintsOf(items, cwd: _cwd);

      expect(hints.touched, isNot(contains('/work/proj/ancient.txt')));
      expect(hints.touched.first, '/work/proj/f399.txt');
    });
  });

  group('hintSteps', () {
    const hints = PathHints(
      folders: ['/work/proj/app/sub'],
      touched: ['/work/proj/app/lib/ui/core/theme.dart', '/tmp/run/out.log'],
    );

    test('the agent folder first, then touched files by name, then the folders of touched files', () {
      final steps = hintSteps('theme.dart', hints, cwd: _cwd);

      expect(steps.map((s) => s.kind), [HintStepKind.agentFolder, HintStepKind.touched, HintStepKind.touchedFolder]);
      expect(steps[0].paths, ['/work/proj/app/sub/theme.dart']);
      expect(steps[1].paths, ['/work/proj/app/lib/ui/core/theme.dart']);
      expect(steps[2].paths, ['/tmp/run/theme.dart']);
    });

    test('a path with folders matches the end of a touched path, not just its name', () {
      final steps = hintSteps('core/theme.dart', hints, cwd: _cwd);

      expect(steps.firstWhere((s) => s.kind == HintStepKind.touched).paths, ['/work/proj/app/lib/ui/core/theme.dart']);
      expect(hintSteps('other/theme.dart', hints, cwd: _cwd).where((s) => s.kind == HintStepKind.touched), isEmpty);
    });

    test('what the plain lookup already tried is not asked again', () {
      final steps = hintSteps(
        'x.txt',
        const PathHints(folders: ['/work/proj', '/work'], touched: ['/work/proj/x.txt']),
        cwd: _cwd,
      );

      expect(steps, isEmpty);
    });

    test('absolute and home paths take no hints', () {
      expect(hintSteps('/tmp/run/out.log', hints, cwd: _cwd), isEmpty);
      expect(hintSteps('~/out.log', hints, cwd: _cwd), isEmpty);
    });

    test('a step is bounded', () {
      final many = PathHints(touched: [for (var i = 0; i < 100; i++) '/w/d$i/a.txt']);
      final steps = hintSteps('b.txt', many, cwd: _cwd);

      expect(steps.single.kind, HintStepKind.touchedFolder);
      expect(steps.single.paths.length, lessThanOrEqualTo(24));
    });
  });

  group('wasTouched', () {
    const hints = PathHints(touched: ['/tmp/run/out.log', '/work/proj/app/a.dart']);

    test('the same absolute path, or a relative text that ends a touched path', () {
      expect(wasTouched('/tmp/run/out.log', hints), isTrue);
      expect(wasTouched('out.log', hints), isTrue);
      expect(wasTouched('app/a.dart', hints), isTrue);
      expect(wasTouched('/tmp/other/out.log', hints), isFalse);
      expect(wasTouched('b/app/a.dart', hints), isTrue);
      expect(wasTouched('pp/a.dart', hints), isFalse);
    });
  });

  group('resolveRemotePath with hints', () {
    test('a name taken against the folder the agent ran in opens it, with no search', () async {
      final fs = _fs()..addFile('$_cwd/app/sub/runner.py', 'x');
      final r = await resolveRemotePath(
        machineWithFiles(fs),
        'runner.py:9',
        cwd: _cwd,
        hints: const PathHints(folders: ['$_cwd/app/sub']),
      );

      expect(
        r,
        isA<PathFound>().having((f) => f.stat.path, 'path', '$_cwd/app/sub/runner.py').having((f) => f.line, 'line', 9),
      );
      expect((r as PathFound).from, 'Found in app/sub');
      expect(fs.calls.where((c) => c.startsWith('list ') || c.startsWith('read ')), isEmpty);
    });

    test('a bare name next to a file the agent touched is found without searching', () async {
      // 4 folders deep: beyond what a shallow search sees, and cheaper to ask directly.
      final fs = _fs()
        ..addFile('$_cwd/app/lib/ui/core/theme.dart', 'a')
        ..addFile('$_cwd/app/lib/ui/core/motion.dart', 'b');
      final r = await resolveRemotePath(
        machineWithFiles(fs),
        'motion.dart',
        cwd: _cwd,
        hints: const PathHints(touched: ['$_cwd/app/lib/ui/core/theme.dart']),
      );

      expect((r as PathFound).stat.path, '$_cwd/app/lib/ui/core/motion.dart');
      expect(r.from, 'Found in app/lib/ui/core');
      expect(fs.calls.where((c) => c.startsWith('list ')), isEmpty);
    });

    test('a file outside the session folder that a call touched opens', () async {
      final fs = _fs()..addFile('/tmp/run/out.log', 'log text');
      final r = await resolveRemotePath(
        machineWithFiles(fs),
        'out.log',
        cwd: _cwd,
        hints: const PathHints(touched: ['/tmp/run/out.log']),
      );

      expect((r as PathFound).stat.path, '/tmp/run/out.log');
      expect(r.from, 'Found in run');
    });

    test('two touched files of that name are offered, in the order the agent touched them', () async {
      final fs = _fs()
        ..addFile('/a/x/notes.txt', '1', modified: DateTime.utc(2026, 5, 1))
        ..addFile('/b/y/notes.txt', '2', modified: DateTime.utc(2026, 1, 1));
      final r = await resolveRemotePath(
        machineWithFiles(fs),
        'notes.txt',
        cwd: _cwd,
        hints: const PathHints(touched: ['/b/y/notes.txt', '/a/x/notes.txt']),
      );

      expect((r as PathChoices).candidates.map((c) => c.path), ['/b/y/notes.txt', '/a/x/notes.txt']);
    });

    test('a file the agent used that is gone says so, not that it is missing from the folder', () async {
      final fs = _fs();
      await expectLater(
        resolveRemotePath(
          machineWithFiles(fs),
          '/tmp/run/out.log',
          cwd: _cwd,
          hints: const PathHints(touched: ['/tmp/run/out.log']),
        ),
        throwsA(
          isA<PathNotFound>()
              .having((e) => e.kind, 'kind', RemoteFileErrorKind.notFound)
              .having((e) => e.message, 'message', '/tmp/run/out.log isn’t there any more (the agent used it earlier)'),
        ),
      );
    });

    test('a hint that fails for another reason is skipped, not shown', () async {
      final fs = _fs()
        ..addFile('/locked/notes.txt', 'x')
        ..deny.add('/locked/notes.txt')
        ..addFile('/ok/notes.txt', 'y');
      final r = await resolveRemotePath(
        machineWithFiles(fs),
        'notes.txt',
        cwd: _cwd,
        hints: const PathHints(touched: ['/locked/notes.txt', '/ok/notes.txt']),
      );

      expect((r as PathFound).stat.path, '/ok/notes.txt');
    });

    test('with no hints the answer is what it was: one stat for a file that is there', () async {
      final fs = _fs()..addFile('$_cwd/a.txt', 'x');
      await resolveRemotePath(machineWithFiles(fs), 'a.txt', cwd: _cwd);

      expect(fs.calls, ['stat $_cwd/a.txt']);
    });

    test('the name search now reaches folders six levels down', () async {
      final fs = _fs()..addFile('$_cwd/a/b/c/d/e/deep_target_file.txt', 'x');
      final r = await resolveRemotePath(machineWithFiles(fs), 'deep_target_file.txt', cwd: _cwd);

      expect((r as PathFound).stat.path, '$_cwd/a/b/c/d/e/deep_target_file.txt');
      expect(r.from, 'Found in a/b/c/d/e');
    });

    test('Back while hints are being asked stops the asking', () async {
      final fs = _fs()..addFile('/ok/n.txt', 'y');
      final cancel = SearchCancel()..cancel();
      await expectLater(
        resolveRemotePath(
          machineWithFiles(fs),
          'n.txt',
          cwd: _cwd,
          cancel: cancel,
          hints: const PathHints(touched: ['/ok/n.txt']),
        ),
        throwsA(isA<PathNotFound>()),
      );
      expect(fs.calls.where((c) => c == 'stat /ok/n.txt'), isEmpty);
    });
  });
}
