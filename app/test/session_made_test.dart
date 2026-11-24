import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/background/background_work.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/acp/session_made.dart';
import 'package:herdr_mobile/data/models/made_files.dart';

var _n = 0;

TranscriptItem _say(String text, {MessageRole role = MessageRole.agent}) =>
    TranscriptMessage(key: 'm${_n++}', role: role, blocks: [TextBlock(text)]);

TranscriptItem _run(String command, {String? output, String? cwd, ToolStatus status = ToolStatus.completed}) =>
    TranscriptTool(
      ToolCall(
        toolCallId: 't${_n++}',
        kind: ToolKind.execute,
        status: status,
        rawInput: {'command': command},
        output: output == null ? null : ToolOutput(text: output, exited: true, exitCode: 0),
        meta: cwd == null
            ? null
            : {
                'terminal_info': {'cwd': cwd},
              },
      ),
    );

TranscriptItem _patch(String path, {String? oldText, required String newText}) => TranscriptTool(
  ToolCall(
    toolCallId: 't${_n++}',
    kind: ToolKind.edit,
    status: ToolStatus.completed,
    content: [ToolDiff(path: path, oldText: oldText, newText: newText)],
    locations: [ToolLocation(path: path)],
  ),
);

TranscriptItem _write(String path, {ToolKind kind = ToolKind.edit, ToolStatus status = ToolStatus.completed}) =>
    TranscriptTool(
      ToolCall(
        toolCallId: 't${_n++}',
        kind: kind,
        status: status,
        content: [ToolDiff(path: path, newText: '<h1>x</h1>')],
        locations: [ToolLocation(path: path)],
      ),
    );

TranscriptItem _read(String path) => TranscriptTool(
  ToolCall(
    toolCallId: 't${_n++}',
    kind: ToolKind.read,
    status: ToolStatus.completed,
    locations: [ToolLocation(path: path)],
  ),
);

TranscriptItem _delete(String path) => TranscriptTool(
  ToolCall(
    toolCallId: 't${_n++}',
    kind: ToolKind.delete,
    status: ToolStatus.completed,
    locations: [ToolLocation(path: path)],
  ),
);

List<String> _keys(List<TranscriptItem> items, {String? cwd}) => [for (final a in madeAssetsOf(items, cwd: cwd)) a.key];

List<MadeKind> webAssetsKinds(List<String> names) => [
  for (final n in names)
    if (madeFileKindOf(n) case final k?)
      switch (k) {
        MadeFileKind.page => MadeKind.page,
        MadeFileKind.picture => MadeKind.picture,
        MadeFileKind.video => MadeKind.video,
        MadeFileKind.doc => MadeKind.doc,
      },
];

const _vite =
    '  VITE v5.2.0  ready in 312 ms\n\n  ➜  Local:   http://localhost:5173/\n  ➜  Network: http://192.168.1.20:5173/\n';

void main() {
  group('servers', () {
    test('a launch prints its address on a banner line; one row per port under any loopback spelling', () {
      final items = [
        _run('npm run dev', output: _vite),
        _say('Also on http://127.0.0.1:5173/ and http://0.0.0.0:5173.'),
      ];
      final assets = madeAssetsOf(items);
      expect(assets.map((a) => a.key), ['localhost:5173']);
      expect(assets.single.title, 'localhost:5173');
    });

    test('the banners real dev servers print are read', () {
      for (final banner in [
        '  - Local:        http://localhost:3000\n',
        ' * Running on http://127.0.0.1:5000\n',
        'INFO:     Uvicorn running on http://127.0.0.1:8000 (Press CTRL+C to quit)\n',
        'Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...\n',
        'Project is running at: http://localhost:8080/\n',
        'Web Server is available at http://localhost:1313/\n',
        'Local URL: http://localhost:8501\n',
      ]) {
        expect(_keys([_run('start-it', output: banner)]), hasLength(1), reason: banner);
      }
    });

    test('what a probe or a log prints is not a server the agent started', () {
      // 1,304 of 1,861 rows from 6,000 real sessions came from these.
      final items = [
        _run(
          'curl -s http://localhost:11434/api/tags',
          output: '{"models":[]}\nlocal http://localhost:11434/api/tags\n',
        ),
        _run('cat docker-compose.yml', output: 'local: http://localhost:19530\n'),
        _run("rg 'localhost:9002' src", output: 'src/a.ts: Local: http://localhost:9002\n'),
        _run("ssh box 'npm run dev'", output: _vite),
        _run('docker exec db sh', output: 'Listening on http://localhost:5432\n'),
        _run('make test', output: List.filled(200, 'GET http://localhost:9000/health 200 ok').join('\n')),
        _run('git diff', output: '+  url: http://localhost:3000\n'),
      ];
      expect(_keys(items), isEmpty);
    });

    test('"local" and "network" in a log line are not an address the agent launched', () {
      final items = [
        _run('npm run dev', output: 'Network request to http://localhost:8000/api failed\n'),
        _run('python app.py', output: 'using local proxy http://127.0.0.1:7890\n'),
        _run('npm test', output: 'Server listening on http://127.0.0.1:38211\n'),
        _run('go test ./...', output: 'Server listening on http://127.0.0.1:38212\nLocal: http://localhost:38213/\n'),
        _run('pytest -q', output: 'Uvicorn running on http://127.0.0.1:38214\n'),
        _run('npx vitest run', output: 'Local: http://localhost:38215/\n'),
        _run('cd app && flutter test', output: 'Serving HTTP on 0.0.0.0 port 38216 (http://0.0.0.0:38216/)\n'),
        _run('make check', output: 'Server listening on http://127.0.0.1:38217\n'),
      ];
      expect(_keys(items), isEmpty);
    });

    test('a launch that says "listening on" is still a server, from a command that starts something', () {
      expect(_keys([_run('node server.js', output: 'Server listening on http://127.0.0.1:3001\n')]), [
        'localhost:3001',
      ]);
      expect(_keys([_run('npm run dev', output: _vite)]), ['localhost:5173']);
      expect(_keys([_run('uvicorn app:app', output: 'INFO:     Uvicorn running on http://127.0.0.1:8000\n')]), [
        'localhost:8000',
      ]);
      expect(
        _keys([
          _run('python -m http.server 8000', output: 'Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ...\n'),
        ]),
        ['localhost:8000'],
      );
    });

    test('a command that failed or was cancelled names no server; one still running does', () {
      for (final s in [ToolStatus.failed, ToolStatus.cancelled, ToolStatus.pending]) {
        expect(
          _keys([_run('npm run dev', output: _vite, status: s)]),
          isEmpty,
          reason: '$s',
        );
      }
      expect(_keys([_run('npm run dev', output: _vite, status: ToolStatus.inProgress)]), ['localhost:5173']);
    });

    test('a command\'s own text names no server', () {
      expect(_keys([_run('curl http://localhost:3000/health && npm run dev')]), isEmpty);
    });

    test('the agent\'s own link keeps its path; a bare localhost:port counts too; output only the origin', () {
      final items = [
        _say('Open http://localhost:8000/docs for the API, and the app is on localhost:5173.'),
        _run('npm start', output: 'Local: http://localhost:4000/internal/debug/x\n'),
      ];
      final byKey = {for (final a in madeAssetsOf(items)) a.key: a};
      expect(byKey['localhost:8000/docs']!.title, 'localhost:8000/docs');
      expect(byKey['localhost:5173'], isNotNull);
      expect(byKey['localhost:4000']!.url!.path, '/');
      expect(
        byKey.keys,
        hasLength(3),
        reason: 'the bare port of an item that links to a path of it adds no second row',
      );
    });

    test(
      'a bare 127.0.0.1, 0.0.0.0 or [::1] with a port counts; a tunnel, a database URL or a longer address does not',
      () {
        final items = [
          _say('The API is on 127.0.0.1:8001, the app on 0.0.0.0:8002 and the docs on [::1]:8003.'),
          _say(
            'Tunnel with ssh -L 9100:127.0.0.1:9101 and connect postgres://u@127.0.0.1:9102/db or 10.127.0.0.1:9103.',
          ),
        ];
        expect(_keys(items).toSet(), {'localhost:8001', 'localhost:8002', 'localhost:8003'});
      },
    );

    test('only plain http to the machine itself is a server, spelled the ways a dev server spells it', () {
      final items = [
        _say(
          'https://localhost:8443/admin http://192.168.1.20:3000 http://printer.local:9100/ http://127.0.0.5:6379/ '
          'http://evil.localhost:3000/ http://redis.svc.cluster.local:6379 http://localhost:0/ http://localhost:65536/ '
          'http://localhost@example.com/ http://example.com#@localhost http://127.0.0.1.example.com/ '
          'http://[::1]:5173/ HTTP://LOCALHOST:3000/',
        ),
      ];
      final assets = madeAssetsOf(items);
      expect(
        [
          for (final a in assets)
            if (a.kind == MadeKind.server) a.key,
        ],
        ['localhost:3000', 'localhost:5173'],
      );
      // What is not the machine itself is a link; the machine itself, in any spelling, is never one.
      expect(
        [
          for (final a in assets)
            if (a.kind == MadeKind.link) a.url!.host,
        ],
        ['redis.svc.cluster.local', 'printer.local', '192.168.1.20'],
      );
    });

    test('credentials in a link are not kept', () {
      final s = madeAssetsOf([_say('http://user:secret@localhost:3000/x')]).single;
      expect(s.url.toString(), 'http://localhost:3000/x');
    });

    test('a link the agent set in bold, italics or code is the link without the marks or the full stop', () {
      final cases = {
        '**http://127.0.0.1:8766/**': 'localhost:8766',
        '__http://localhost:3000/docs__': 'localhost:3000/docs',
        'See *http://localhost:3001/a*.': 'localhost:3001/a',
        'See _http://localhost:3002/b_.': 'localhost:3002/b',
        '~~http://localhost:3003/c~~': 'localhost:3003/c',
        '`http://localhost:3004/d`': 'localhost:3004/d',
        '(on http://localhost:3005/e).': 'localhost:3005/e',
        '**http://localhost:3006/f?x=1**!': 'localhost:3006/f',
      };
      for (final c in cases.entries) {
        final s = madeAssetsOf([_say(c.key)]).single;
        expect(s.title, c.value, reason: c.key);
        expect(s.url!.path, isNot(contains('*')), reason: c.key);
        expect(s.url!.toString(), isNot(endsWith('_')), reason: c.key);
      }
      expect(
        madeAssetsOf([_say('**http://localhost:3006/f?x=1**')]).single.url.toString(),
        'http://localhost:3006/f?x=1',
      );
    });

    test('a link that ends in a mark of its own keeps it when nothing opened that mark before it', () {
      final cases = {
        'Open http://localhost:3000/search?q=snake_': 'http://localhost:3000/search?q=snake_',
        'Open http://localhost:3000/?access_token=Ab3dEf_.': 'http://localhost:3000/?access_token=Ab3dEf_',
        'API at http://localhost:3000/api/__': 'http://localhost:3000/api/__',
        'Home: http://localhost:3000/~': 'http://localhost:3000/~',
        '*http://localhost:3000/?q=snake_*': 'http://localhost:3000/?q=snake_',
      };
      for (final c in cases.entries) {
        expect(madeAssetsOf([_say(c.key)]).single.url.toString(), c.value, reason: c.key);
      }
    });

    test('each page of a server the agent named is a row; a page mentioned again moves to the top', () {
      final items = [
        _say('Running http://localhost:3000/'),
        _say('Report at http://localhost:4000/'),
        _say('Try http://localhost:3000/health'),
      ];
      expect(madeAssetsOf(items).map((a) => a.title), ['localhost:3000/health', 'localhost:4000', 'localhost:3000']);
      expect(_keys([...items, _say('and again http://localhost:3000/')]), [
        'localhost:3000',
        'localhost:3000/health',
        'localhost:4000',
      ]);
    });

    test(
      'a dashboard and its tabs, linked in one table, are one row each (a log of a real session lost all but the last)',
      () {
        final table = _say(
          'Links (from elsewhere run `ssh -L 8765:localhost:8765 gpu-3` first):\n\n'
          '| Dashboard | http://localhost:8765/ |\n'
          '| Synth | http://localhost:8765/synth |\n'
          '| Review | http://localhost:8765/review |\n'
          '| Failures | http://localhost:8765/failures |\n',
        );
        expect(_keys([table]), [
          'localhost:8765/failures',
          'localhost:8765/review',
          'localhost:8765/synth',
          'localhost:8765',
        ]);
      },
    );

    test('a banner names the origin; a link in another message adds its page beside it', () {
      final items = [_run('npm run dev', output: _vite), _say('The docs are at http://localhost:5173/docs/intro')];
      expect(_keys(items), ['localhost:5173/docs/intro', 'localhost:5173']);
    });

    test('a server keeps its newest $madeServerPathsCap pages; another port is not pushed out', () {
      final items = [
        _say('http://localhost:9000/'),
        for (var i = 0; i < 12; i++) _say('see http://localhost:8000/p$i'),
      ];
      final keys = _keys(items);
      expect(keys.where((k) => k.startsWith('localhost:8000')), [
        for (var i = 11; i > 11 - madeServerPathsCap; i--) 'localhost:8000/p$i',
      ]);
      expect(keys, contains('localhost:9000'));
    });

    test('a user message is not something the session made', () {
      expect(_keys([_say('Please run http://localhost:3000', role: MessageRole.user)]), isEmpty);
    });

    test(
      'state: running only while a running task names the port; stopped when only ended ones do; else just seen',
      () {
        final server = madeAssetsOf([_say('http://localhost:5173/')]).single;
        BackgroundTask task(String title, BackgroundStatus s) =>
            BackgroundTask(id: title, kind: BackgroundKind.shell, status: s, title: title);
        expect(serverStateOf(server, const []), ServerState.seen);
        expect(serverStateOf(server, [task('vite --port 5173', BackgroundStatus.running)]), ServerState.running);
        expect(
          serverStateOf(server, [task('vite --port 5173', BackgroundStatus.paused)]),
          ServerState.stopped,
          reason: 'paused serves nothing',
        );
        expect(serverStateOf(server, [task('vite --port 5173', BackgroundStatus.finished)]), ServerState.stopped);
        expect(
          serverStateOf(server, [
            task('vite --port 5173', BackgroundStatus.finished),
            task('npm run dev -- --port 5173', BackgroundStatus.running),
          ]),
          ServerState.running,
        );
        expect(
          serverStateOf(server, [task('serve -p 51730', BackgroundStatus.running)]),
          ServerState.seen,
          reason: 'a longer number is another port',
        );
        expect(
          serverStateOf(server, [task('vite --port 5173', BackgroundStatus.running)], live: false),
          ServerState.seen,
          reason: 'a saved copy or a link that is down knows of nothing running now',
        );
      },
    );

    test('launchLabelOf is what started the server: no cd, wrapper, redirect or folder of the program', () {
      expect(
        launchLabelOf('cd /w && nohup /home/u/.venv/bin/python label_server.py --port 8765 > log 2>&1 &'),
        'python label_server.py --port 8765',
      );
      expect(launchLabelOf('PORT=3000 npm run dev'), 'npm run dev');
      expect(launchLabelOf('cd /w'), isNull);
      expect(launchLabelOf('python -m http.server 8000 --directory ${'x' * 80}')!.length, 60);
    });

    test('a launch command names its server, even with no banner; it makes no row by itself', () {
      final launch = _run('cd /w && nohup python label_server.py --port 8765 > log 2>&1 &');
      expect(_keys([launch]), isEmpty, reason: 'a command is not proof that a server came up');
      final servers = madeAssetsOf([launch, _say('Review it at http://localhost:8765/review')]);
      expect(servers.single.launch, 'python label_server.py --port 8765');

      final banner = madeAssetsOf([_run('npm run dev', output: _vite)]);
      expect(banner.single.launch, 'npm run dev');

      expect(
        madeAssetsOf([_run('pytest --port 8765'), _say('http://localhost:8765/')]).single.launch,
        isNull,
        reason: 'a test run launches nothing',
      );
      expect(
        madeAssetsOf([_run('curl -p 8765 http://localhost:8765/x'), _say('http://localhost:8765/')]).single.launch,
        isNull,
        reason: 'a probe launches nothing',
      );
    });

    test('a launch is kept with the row through a kept history, and the newest launch of a port wins', () {
      final first = MadeFold()..addAll([_run('python a.py --port 8765'), _say('http://localhost:8765/')]);
      final history = first.history(100);
      final restored = MadeHistory.fromBytes(history.toBytes())!;
      expect(restored.assets.single.launch, 'python a.py --port 8765');
      final next = MadeFold(from: restored)
        ..addAll([_run('python b.py --port 8765'), _say('again http://localhost:8765/x')]);
      expect(next.assets.map((a) => a.launch), everyElement('python b.py --port 8765'));
    });

    test('madeAppsOf: the pages of one port are one app, opening on its root when the agent named it', () {
      final assets = madeAssetsOf([
        _say('http://localhost:8790/'),
        _say('http://localhost:8765/label'),
        _say('http://localhost:8765/'),
        _say('http://localhost:8765/review'),
        _say('http://localhost:8765/failures'),
      ]).where((a) => a.kind == MadeKind.server).toList();
      final apps = madeAppsOf(assets);
      expect(apps.map((a) => a.port), [8765, 8790], reason: 'in the order each port first appears, newest first');
      expect(apps.first.entry.route, '/');
      expect(apps.first.pages.map((p) => p.route), ['/failures', '/review', '/label']);
      expect(apps.last.pages, isEmpty);
      expect(madeCountOf(assets), 2);

      final noRoot = madeAppsOf(
        madeAssetsOf([_say('http://localhost:8765/label'), _say('http://localhost:8765/review')]),
      );
      expect(noRoot.single.entry.route, '/review', reason: 'no root named: the newest page opens');
    });

    test('serverNameOf: a running task\'s command, else the one the transcript launched it with', () {
      final server = madeAssetsOf([_run('python old.py --port 5173'), _say('http://localhost:5173/')]).single;
      BackgroundTask task(String title, BackgroundStatus s) =>
          BackgroundTask(id: title, kind: BackgroundKind.shell, status: s, title: title);
      expect(serverNameOf(server, const []), 'python old.py --port 5173');
      expect(
        serverNameOf(server, [
          task('vite --port 5173', BackgroundStatus.running),
          task('serve -p 5173', BackgroundStatus.finished),
        ]),
        'vite --port 5173',
      );
      expect(
        serverNameOf(server, [task('serve -p 51730', BackgroundStatus.running)]),
        'python old.py --port 5173',
        reason: 'another port',
      );
    });
  });

  group('pages the agent wrote', () {
    test(
      'a file a tool wrote is a page; a file it only read is not; an edit that has not completed changed nothing',
      () {
        final items = [
          _write('/home/dev/app/report.html'),
          _read('/home/dev/app/old.html'),
          _write('/home/dev/app/main.dart'),
          _write('/a/pending.html', status: ToolStatus.pending),
        ];
        expect(_keys(items), ['/home/dev/app/report.html']);
      },
    );

    test('a page that was deleted or moved away is not listed', () {
      final items = [
        _write('/a/one.html'),
        _write('/a/two.html'),
        _write('/a/three.html'),
        _delete('/a/one.html'),
        _run('rm /a/two.html'),
        _run('mv /a/three.html /a/four.html'),
      ];
      expect(_keys(items), ['/a/four.html']);
    });

    test('a page written again is one row, newest first', () {
      expect(_keys([_write('/a/one.html'), _write('/a/two.html'), _write('/a/one.html')]), [
        '/a/one.html',
        '/a/two.html',
      ]);
    });

    test('dependencies and system files are not the session\'s pages', () {
      final items = [
        _write('/w/node_modules/pkg/index.html'),
        _write('/usr/share/doc/x/index.html'),
        _write('/w/.git/a.html'),
        _write('/w/mine.html'),
      ];
      expect(_keys(items), ['/w/mine.html']);
    });
  });

  group('pages a command writes', () {
    test('a redirect, tee, an output flag, a copy target and open name what the command makes', () {
      final items = [
        _run('python gen_report.py > reports/q3.html', cwd: '/home/dev/app'),
        _run('python gen.py | tee out/b.html', cwd: '/home/dev/app'),
        _run('coverage html --output=cov/index.html', cwd: '/home/dev/app'),
        _run('cp template.html site/c.html', cwd: '/home/dev/app'),
        _run('xdg-open site/c.html', cwd: '/home/dev/app'),
      ];
      expect(_keys(items), [
        '/home/dev/app/site/c.html',
        '/home/dev/app/cov/index.html',
        '/home/dev/app/out/b.html',
        '/home/dev/app/reports/q3.html',
      ]);
    });

    test('a command that did not run wrote and removed nothing', () {
      for (final s in [ToolStatus.pending, ToolStatus.inProgress, ToolStatus.failed, ToolStatus.cancelled]) {
        expect(
          _keys([_run('echo x > a.html', cwd: '/w', status: s)]),
          isEmpty,
          reason: '$s writes nothing',
        );
        expect(_keys([_run('echo x > a.html', cwd: '/w'), _run('rm a.html', cwd: '/w', status: s)]), [
          '/w/a.html',
        ], reason: '$s removes nothing');
        expect(
          _keys([_run('python shot.py', output: 'Saved screenshot to screenshots/a.png\n', cwd: '/w', status: s)]),
          isEmpty,
          reason: '$s',
        );
      }
    });

    test('a leading cd moves where a relative name is taken from', () {
      final items = [
        _run('cd /tmp/scratch/report && python gen.py > out.html', cwd: '/home/dev/app'),
        _run('cd sub && cd deep; echo x > y.html', cwd: '/w'),
      ];
      expect(_keys(items), ['/w/sub/deep/y.html', '/tmp/scratch/report/out.html']);
    });

    test('a command that only mentions a file, reads it, lists it or downloads it made nothing', () {
      // 417 of 513 page rows in 6,000 real sessions were these.
      final items = [
        _run('grep -n title report.html', cwd: '/w'),
        _run('cat site/index.html', cwd: '/w'),
        _run('ls htmlcov', output: 'index.html\nz_1_a_py.html\n', cwd: '/w'),
        _run('curl -sL -o page.html https://example.com/a', cwd: '/w'),
        _run('wget -O page2.html https://example.com/b', cwd: '/w'),
        _run('git diff -- docs/a.html', cwd: '/w'),
        _run('python gen.py', cwd: '/w'),
      ];
      expect(_keys(items), isEmpty);
    });

    test('the body of a heredoc is a file\'s content, not something the agent made', () {
      final items = [
        _run(
          "cat > site/index.html <<'EOF'\n<a href=\"about.html\">x</a>\n<a href=\"/contact.html\">y</a>\nEOF",
          cwd: '/w',
        ),
      ];
      expect(_keys(items), ['/w/site/index.html']);
    });

    test('shell variables, urls and Windows paths are not paths of the machine', () {
      final items = [_run(r'echo hi > $OUT/flow/t.html', cwd: '/w'), _run(r'echo hi > C:\Users\me\a.html', cwd: '/w')];
      expect(_keys(items), isEmpty);
    });

    test('a relative name with no folder to take it from is not guessed', () {
      expect(_keys([_run('echo x > a.html')]), isEmpty);
      expect(_keys([_run('echo x > a.html')], cwd: ''), isEmpty, reason: 'an empty folder is an unknown one');
      expect(_keys([_run('echo x > a.html')], cwd: '/w'), ['/w/a.html']);
    });
  });

  group('pages the agent names', () {
    test('a path with a folder in it counts; a markdown link too; a code block does not', () {
      final items = [
        _say(
          'See `coverage/index.html` and [the chart](diagrams/architecture.svg).\n```html\n<img src="logo.svg"><a href="reports/x.html">x</a>\n```',
        ),
      ];
      expect(_keys(items, cwd: '/home/dev/app'), [
        '/home/dev/app/diagrams/architecture.svg',
        '/home/dev/app/coverage/index.html',
      ]);
    });

    test('a bare file name counts only right after a word of making', () {
      expect(_keys([_say('The index.html in a Vite app is the entry point.')], cwd: '/w'), isEmpty);
      expect(_keys([_say('I created report.html for you.')], cwd: '/w'), ['/w/report.html']);
      expect(_keys([_say('Đã tạo report.html cho bạn.')], cwd: '/w'), ['/w/report.html']);
    });

    test('the word of making must be right before the path, in the same clause', () {
      for (final said in [
        'I created the new handler and then updated the README.md accordingly',
        'I opened README.md and read it',
        'I built the app, and the usage is documented in docs/usage.md',
        'Wrote the script. The file docs/old-spec.pdf was left unchanged.',
        'I created the handler and then updated the README.md',
        'Output: README.md',
      ]) {
        expect(_keys([_say(said)], cwd: '/w'), isEmpty, reason: said);
      }
      for (final (said, key) in [
        ('I saved the chart to charts/x.png', '/w/charts/x.png'),
        ('I created docs/spec.md', '/w/docs/spec.md'),
        ('Wrote report.pdf', '/w/report.pdf'),
        ('I built dist/index.html', '/w/dist/index.html'),
        ('I created a new report.html', '/w/report.html'),
        ('I fixed the bug and then created summary.md', '/w/summary.md'),
      ]) {
        expect(_keys([_say(said)], cwd: '/w'), [key], reason: said);
      }
    });

    test('a line number, an anchor, a full stop and file:// are not part of the path', () {
      final items = [
        _say('Wrote /tmp/out/final.html. Then /tmp/out/a.html:12 and /tmp/out/b.html#top and file:///tmp/out/c.html.'),
      ];
      expect(_keys(items), ['/tmp/out/c.html', '/tmp/out/b.html', '/tmp/out/a.html', '/tmp/out/final.html']);
    });

    test('a path inside a url is not a page, and a server is still found', () {
      expect(_keys([_say('Wrote /tmp/out/final.html. Then http://localhost:8000/not-a-page.html is served.')]), [
        '/tmp/out/final.html',
        'localhost:8000/not-a-page.html',
      ]);
    });

    test('the same file under its spellings is one row', () {
      final items = [
        _say('see ./reports/a.html and reports/a.html and ../app/reports/a.html and /w/app/reports/a.html'),
      ];
      expect(_keys(items, cwd: '/w/app'), ['/w/app/reports/a.html']);
    });
  });

  group('bounds', () {
    test('a session lists at most madeAssetsCap rows and one item at most 40 mentions', () {
      final many = [for (var i = 0; i < 400; i++) _say('http://localhost:${3000 + i}/')];
      final assets = madeAssetsOf(many);
      expect(assets, hasLength(madeAssetsCap));
      expect(assets.first.key, 'localhost:3399', reason: 'the newest are kept');
      final oneMessage = _say([for (var i = 0; i < 200; i++) 'http://localhost:${4000 + i}/'].join(' '));
      expect(madeAssetsOf([oneMessage]).length, lessThanOrEqualTo(40));
    });

    test('a flood of one kind never pushes another kind out', () {
      final items = [
        _say('http://localhost:3000/'),
        for (var i = 0; i < madeAssetsCap + 50; i++) _say('I saved shots/$i.png'),
      ];
      final assets = madeAssetsOf(items, cwd: '/w');
      expect(assets.where((a) => a.kind == MadeKind.server), hasLength(1));
      final pictures = assets.where((a) => a.kind == MadeKind.picture).toList();
      expect(pictures, hasLength(madeAssetsCap));
      expect(pictures.first.key, '/w/shots/${madeAssetsCap + 49}.png');
      expect(pictures.last.key, '/w/shots/50.png', reason: 'each kind keeps its newest');
      expect(assets.last.key, 'localhost:3000', reason: 'still newest first overall');
    });

    test('text with no break in it is read in linear time', () {
      // A lazy match with a following lookahead was quadratic: 64 KB took 30 s.
      final blob = 'a' * 60000;
      final dots = 'a.' * 30000;
      final b64 = 'data:image/png;base64,${'QUJD' * 15000}';
      final watch = Stopwatch()..start();
      madeAssetsOf([_say(blob), _say(dots), _say(b64), _run('echo ${'x' * 30000} > out.html', cwd: '/w')]);
      expect(watch.elapsedMilliseconds, lessThan(1500));
    });
  });

  group('the list', () {
    test('the same list answers from memory, per folder', () {
      final items = [_say('http://localhost:3000/'), _write('/a/one.html')];
      expect(identical(madeAssetsOf(items, cwd: '/a'), madeAssetsOf(items, cwd: '/a')), isTrue);
      final other = madeAssetsOf(items, cwd: '/b');
      expect(
        identical(madeAssetsOf(items, cwd: '/a'), madeAssetsOf(items, cwd: '/a')),
        isTrue,
        reason: 'another folder does not evict',
      );
      expect(other, isNotNull);
    });

    test('a longer list scans only what is new and keeps newest first', () {
      final items = [_say('http://localhost:3000/'), _write('/a/one.html')];
      final longer = [...items, _say('http://localhost:4000/')];
      expect(_keys(longer), ['localhost:4000', '/a/one.html', 'localhost:3000']);
    });

    test('a streaming tool call keeps its server while its output grows', () {
      final call = ToolCall(
        toolCallId: 'x',
        kind: ToolKind.execute,
        status: ToolStatus.inProgress,
        rawInput: {'command': 'npm run dev'},
      );
      TranscriptItem at(String text) => TranscriptTool(call.copyWith(output: ToolOutput(text: text)));
      expect(_keys([at('starting\n')]), isEmpty);
      expect(_keys([at(_vite)]), ['localhost:5173']);
      expect(_keys([at('$_vite${'GET / 200\n' * 500}')]), ['localhost:5173']);
    });

    test('sameMadeAssets compares what the rows show, not the list that holds them', () {
      final a = madeAssetsOf([_say('http://localhost:3000/'), _run('ls', output: 'a\n')]);
      final b = madeAssetsOf([_say('http://localhost:3000/'), _run('ls', output: 'a\nb\n')]);
      expect(identical(a, b), isFalse);
      expect(sameMadeAssets(a, b), isTrue);
      expect(sameMadeAssets(a, madeAssetsOf([_say('http://localhost:3000/health')])), isFalse);
    });
  });

  group('pictures and documents', () {
    TranscriptItem create(String path) => TranscriptTool(
      ToolCall(
        toolCallId: 't${_n++}',
        kind: ToolKind.edit,
        status: ToolStatus.completed,
        content: [ToolDiff(path: path, newText: '# x')],
      ),
    );

    TranscriptItem edit(String path) => TranscriptTool(
      ToolCall(
        toolCallId: 't${_n++}',
        kind: ToolKind.edit,
        status: ToolStatus.completed,
        content: [ToolDiff(path: path, oldText: 'a', newText: 'b')],
      ),
    );

    test('the kind comes from the name; svg is a page, source and data are nothing', () {
      expect(
        webAssetsKinds([
          '/a/x.png',
          '/a/x.JPG',
          '/a/x.svg',
          '/a/x.html',
          '/a/x.md',
          '/a/x.pdf',
          '/a/x.csv',
          '/a/x.dart',
          '/a/x.json',
          '/a/x.txt',
          '/a/x.log',
        ]),
        [MadeKind.picture, MadeKind.picture, MadeKind.page, MadeKind.page, MadeKind.doc, MadeKind.doc, MadeKind.doc],
      );
    });

    test('a document counts when the agent created it, not when it edited one', () {
      final items = [create('/w/docs/design.md'), edit('/w/README.md'), edit('/w/docs/old.pdf')];
      expect(_keys(items), ['/w/docs/design.md']);
    });

    test('a picture or document a command writes counts; one it only reads or downloads does not', () {
      final items = [
        _run('python plot.py --output out/chart.png', cwd: '/w'),
        _run('pandoc notes.md -o out/report.pdf', cwd: '/w'),
        _run('cat > docs/plan.md <<EOF\n# Plan\nEOF', cwd: '/w'),
        _run('grep -n x docs/old.md', cwd: '/w'),
        _run('curl -o logo.png https://example.com/logo.png', cwd: '/w'),
        _run('cp shots/a.png /tmp/keep/a.png', cwd: '/w'),
      ];
      expect(_keys(items), ['/tmp/keep/a.png', '/w/docs/plan.md', '/w/out/report.pdf', '/w/out/chart.png']);
    });

    test('a tool that says it saved a file is believed; a listing is not', () {
      final items = [
        _run('python shot.py', output: 'Saved screenshot to screenshots/checkout.png\nDone\n', cwd: '/w'),
        _run('ls screenshots', output: 'checkout.png\nother.png\n', cwd: '/w'),
        _run('git status', output: 'new file: docs/a.md\nwrote nothing\n', cwd: '/w'),
      ];
      expect(_keys(items), ['/w/screenshots/checkout.png']);
    });

    test('in the agent\'s words a picture or document needs a word of making; a page with a folder does not', () {
      final items = [
        _say('Please update docs/guide.md and look at screenshots/old.png.'),
        _say('I saved screenshots/new.png and created docs/summary.md.'),
        _say('Open reports/q3.html'),
      ];
      expect(_keys(items, cwd: '/w'), ['/w/reports/q3.html', '/w/docs/summary.md', '/w/screenshots/new.png']);
    });

    test('a removed picture or document leaves the list', () {
      final items = [
        create('/w/docs/a.md'),
        _run('rm /w/docs/a.md'),
        _run('python p.py -o /w/out.png'),
        _delete('/w/out.png'),
      ];
      expect(_keys(items), isEmpty);
    });

    test(
      'a patch that leaves nothing behind removes the file, as Codex deletes one; an empty new file is no document',
      () {
        final items = [
          _patch('/w/a.html', newText: '<p>x</p>'),
          _patch('/w/docs/b.md', newText: '# b'),
          _patch('/w/a.html', oldText: '<p>x</p>', newText: ''),
          _patch('/w/docs/b.md', oldText: '# b', newText: ''),
          _patch('/w/docs/empty.md', newText: ''),
        ];
        expect(_keys(items), isEmpty);
        expect(
          _keys([
            _patch('/w/a.html', newText: '<p>x</p>'),
            _patch('/w/a.html', oldText: '<p>x</p>', newText: '<p>y</p>'),
          ]),
          ['/w/a.html'],
        );
      },
    );

    test('the kinds are told apart on the rows', () {
      final items = [
        create('/w/a.md'),
        _write('/w/p.html'),
        _run('python p.py -o /w/c.png'),
        _say('http://localhost:3000/'),
      ];
      expect(
        [for (final a in madeAssetsOf(items, cwd: '/w')) a.kind],
        [MadeKind.server, MadeKind.picture, MadeKind.page, MadeKind.doc],
      );
    });
  });

  group('videos', () {
    test('a render a command writes and one the agent announces are rows of kind video; a bare mention is not', () {
      final assets = madeAssetsOf([
        _run('npx hyperframes render -o renders/intro.mp4', cwd: '/w/app'),
        _say('I saved demo/walk.mov'),
        _say('See also demo/old.webm'),
        _run('curl -sLo /tmp/clip.mp4 https://example.com/clip.mp4'),
      ], cwd: '/w');
      expect(
        [for (final a in assets) (a.kind, a.key)],
        [(MadeKind.video, '/w/demo/walk.mov'), (MadeKind.video, '/w/app/renders/intro.mp4')],
      );
      expect(assets.last.title, 'intro.mp4');
      expect(assets.last.where, 'renders/');
    });
  });

  group('links the agent said, opened or shipped', () {
    const repo = 'https://github.com/tuan3w/herdr-mobile';

    test('a pull request, an issue, a release and a CI run are rows, named from the command that made them', () {
      final assets = madeAssetsOf([
        _run(
          'gh pr create --base main --head feat/x --title "feat(observed): send while it works"',
          output: '$repo/pull/93\n',
        ),
        _run('gh issue create -t "Flaky test" -b x', output: '$repo/issues/94\n'),
        _run('gh release create v0.1.51 --notes x', output: '$repo/releases/tag/v0.1.51\n'),
        _run('gh run view 123', output: 'View this run on GitHub: $repo/actions/runs/123/job/9\n'),
      ]);
      expect(
        [for (final a in assets) (a.kind, a.title, a.where, a.url.toString())],
        [
          (MadeKind.link, 'Actions run 123', 'tuan3w/herdr-mobile', '$repo/actions/runs/123'),
          (MadeKind.link, 'Release v0.1.51', 'tuan3w/herdr-mobile', '$repo/releases/tag/v0.1.51'),
          (MadeKind.link, 'Issue #94 Flaky test', 'tuan3w/herdr-mobile', '$repo/issues/94'),
          (MadeKind.link, 'PR #93 feat(observed): send while it works', 'tuan3w/herdr-mobile', '$repo/pull/93'),
        ],
      );
    });

    test('what only reads, offers or failed makes no row', () {
      final items = [
        _run('gh pr view 93', output: '$repo/pull/93\n'),
        _run('gh release list', output: 'v0.1.51\n$repo/releases/tag/v0.1.51\n'),
        _run(
          'git push -u origin feat/x',
          output:
              "remote: Create a pull request for 'feat/x' on GitHub by visiting:\nremote:   $repo/pull/new/feat/x\n",
        ),
        _run('gh pr create --title x', output: '$repo/pull/95\n', status: ToolStatus.failed),
        _run('gh pr create --title x', output: '$repo/issues/96\n'),
        _run('cat NOTES.md', output: '$repo/pull/97\n'),
        // Real gh prints no address for these: nothing to read.
        _run('gh run watch 123', output: 'Run CI (123) completed with success\n'),
        _run('gh release upload v0.1.51 a.zip', output: ''),
      ];
      expect(_keys(items), isEmpty);
    });

    test('in the agent’s words every link is a row, a GitHub one named by what it is', () {
      final items = [
        _say('Opened PR: $repo/pull/93'),
        _say('The release is out, I published v0.1.51: $repo/releases/tag/v0.1.51'),
        _say('The earlier discussion is in $repo/issues/85'),
        _say('See the release notes $repo/releases/tag/v0.1.40'),
        _say('The walkthrough is on https://www.youtube.com/watch?v=abc and https://us3.datadoghq.com/dashboard/x'),
        _say('I created https://github.com/tuan3w/herdr-mobile/tree/main'),
      ];
      expect(
        [for (final a in madeAssetsOf(items)) a.title],
        [
          'github.com/tuan3w/herdr-mobile/tree/main',
          'us3.datadoghq.com/dashboard/x',
          'www.youtube.com/watch?v=abc',
          'Release v0.1.40',
          'Issue #85',
          'Release v0.1.51',
          'PR #93',
        ],
      );
    });

    // Recorded on 2026-11-24: agents announce dashboards on the machine's tailnet or
    // LAN address (186 mentions in 31 sessions on one machine, against 37 for
    // localhost) and the person asked "web link ?" each time. Such a link opens in the
    // phone's browser; localhost would open the phone's own.
    test('a dashboard announced on the machine’s tailnet or LAN address is a link, named with its port', () {
      final assets = madeAssetsOf([
        _say('Dashboard: http://100.87.64.16:8792 (LAN: http://192.168.0.108:8792/runs?x=1#top)'),
      ]);
      expect(
        [for (final a in assets) (a.kind, a.title, a.where, a.url.toString())],
        [
          (MadeKind.link, '192.168.0.108:8792/runs?x=1', '', 'http://192.168.0.108:8792/runs?x=1'),
          (MadeKind.link, '100.87.64.16:8792', '', 'http://100.87.64.16:8792/'),
        ],
      );
    });

    test('a markdown link is named by its label; credentials and the fragment are not kept', () {
      final assets = madeAssetsOf([
        _say(
          'Run [the sweep](https://user:pw@wandb.ai/me/p/runs/abc#charts) and [the paper](https://arxiv.org/abs/2401.00001).',
        ),
      ]);
      expect(
        [for (final a in assets) (a.title, a.where, a.url.toString())],
        [
          ('the paper', 'arxiv.org', 'https://arxiv.org/abs/2401.00001'),
          ('the sweep', 'wandb.ai', 'https://wandb.ai/me/p/runs/abc'),
        ],
      );
    });

    test('what is not a place to look at is no row: a code block, the machine itself, a placeholder, a template', () {
      final items = [
        _say('Run:\n```\ncurl https://api.vendor.com/v1/items\n```'),
        _say('http://127.0.0.1:3000/a http://localhost/b http://[::1]:80/c http://app.localhost:3000/d'),
        _say('POST https://example.com/api, the namespace https://www.w3.org/2000/svg and http://intranet/wiki'),
        _say('Use https://api.vendor.com/v1/items/{id}/\$name'),
      ];
      expect(madeAssetsOf(items).where((a) => a.kind == MadeKind.link), isEmpty);
    });

    test('a link is said, not made: not counted, and said again it is one row as new as the later mention', () {
      final assets = madeAssetsOf([
        _say('https://wandb.ai/me/p'),
        _say('Live at https://wandb.ai/me/p again'),
        _say('http://localhost:5173/'),
      ]);
      final links = assets.where((a) => a.kind == MadeKind.link).toList();
      expect(links, hasLength(1));
      expect(links.single.order ~/ 1000, 1);
      expect(madeCountOf(assets), 1, reason: 'the server; the link was said');
    });

    test('the same address said again keeps the longer name', () {
      final items = [
        _run('gh pr create --title "feat: a"', output: '$repo/pull/93\n'),
        _say('Opened PR: $repo/pull/93'),
      ];
      final assets = madeAssetsOf(items);
      expect(assets.map((a) => a.title), ['PR #93 feat: a']);
      expect(assets.single.order ~/ 1000, 1, reason: 'but it is as new as the later mention');
    });

    test('gh with a global flag before the subcommand is still the command that made it', () {
      final items = [
        _run('gh -R tuan3w/herdr-mobile pr create --title "feat: b"', output: '$repo/pull/98\n'),
        _run('gh --repo tuan3w/herdr-mobile release create v2', output: '$repo/releases/tag/v2\n'),
      ];
      expect(madeAssetsOf(items).map((a) => a.title), ['Release v2', 'PR #98 feat: b']);
    });

    test('a link in bold is the link, not the marks after it (a release was opened as `v1**`, a 404)', () {
      final items = [
        _say('Published the release: **$repo/releases/tag/v0.1.51**'),
        _say('Opened the pull request **$repo/pull/93**'),
      ];
      expect(madeAssetsOf(items).map((a) => a.url.toString()), ['$repo/pull/93', '$repo/releases/tag/v0.1.51']);
    });

    test('the owner and repository are read without case: one row for one pull request', () {
      final items = [
        _run('gh pr create --title "feat: a"', output: '$repo/pull/93\n'),
        _say('Opened PR: https://github.com/Tuan3w/Herdr-Mobile/pull/93'),
      ];
      expect(madeAssetsOf(items), hasLength(1));
    });
  });

  group('pictures a tool returned', () {
    ImageBlock block(String data) => ImageBlock(data: data, mimeType: 'image/png');

    TranscriptItem returned(
      String id,
      List<ContentBlock> blocks, {
      ToolKind kind = ToolKind.other,
      String title = 'Screenshot',
      ToolStatus status = ToolStatus.completed,
    }) => TranscriptTool(
      ToolCall(
        toolCallId: id,
        title: title,
        kind: kind,
        status: status,
        content: [for (final b in blocks) ToolContentBlock(b)],
      ),
    );

    test('a browser screenshot is a row of kind picture that holds the block; no file, no path', () {
      final b = block('AAAA');
      final assets = madeAssetsOf([
        returned('t1', [b]),
      ]);
      final a = assets.single;
      expect((a.kind, a.key, a.title, a.path), (MadeKind.picture, 'shot:t1:0', 'Screenshot', null));
      expect(identical(a.image, b), isTrue);
    });

    test(
      'what the agent only looked at is not made: a read, a search, a fetch, a call that failed, a bare address',
      () {
        final items = [
          returned('r', [block('AAAA')], kind: ToolKind.read),
          returned('s', [block('AAAA')], kind: ToolKind.search),
          returned('f', [block('AAAA')], kind: ToolKind.fetch),
          returned('x', [block('AAAA')], status: ToolStatus.failed),
          returned('u', [const ImageBlock(data: '', mimeType: 'image/png', uri: 'file:///tmp/a.png')]),
          returned('d', [const ImageBlock(data: '', mimeType: 'image/png')]),
        ];
        expect(_keys(items), isEmpty);
      },
    );

    test('a tool that returns forty frames has not made forty things: the first six', () {
      final items = [
        returned('t', [for (var i = 0; i < 40; i++) block('A$i')]),
      ];
      expect(madeAssetsOf(items).map((a) => a.key), [for (var i = 5; i >= 0; i--) 'shot:t:$i']);
    });

    test('the history keeps files, never a returned picture: in memory, on disk, or against the cap', () {
      final history =
          (MadeFold(cwd: '/w')..addAll([
                for (var i = 0; i < madeAssetsCap + 10; i++) _say('I saved shots/f$i.png'),
                for (var i = 0; i < 30; i++) returned('t$i', [block('AAAA')]),
              ]))
              .history(10);
      expect(history.assets, hasLength(madeAssetsCap), reason: 'the screenshots do not push files out of the cap');
      expect(history.assets.every((a) => a.image == null && a.path != null), isTrue);
      final back = MadeHistory.fromBytes(history.toBytes())!;
      expect(back.assets.map((a) => a.key), history.assets.map((a) => a.key));
    });
  });

  group('a file the agent says it left alone', () {
    List<String> kept(List<String> said) => _keys([for (final s in said) _say(s)], cwd: '/w');

    test('is named, not made, even with a folder in its path or in a list', () {
      expect(
        kept([
          'I left /tmp/old_build.html alone.',
          'Untouched: reports/stale.html',
          'I did not touch reports/other.html',
          'Files I did not touch:\n- /tmp/legacy/index.html\n- docs/old.html',
        ]),
        isEmpty,
      );
    });

    test('what it made is still there, also next to a "not": a verb of making right before the path wins', () {
      expect(
        kept([
          'I wrote /tmp/new_build.html',
          'Serving the page at /tmp/live/index.html',
          'Not the stylesheet: I wrote docs/a.html',
          'Overwrote the existing out/report.html',
        ]),
        ['/w/out/report.html', '/w/docs/a.html', '/tmp/live/index.html', '/tmp/new_build.html'],
      );
    });
  });

  group('history (the part of a long log the phone did not load)', () {
    MadeHistory read(List<TranscriptItem> items, {int upTo = 1000, MadeHistory? from}) =>
        (MadeFold(cwd: '/w', from: from)..addAll(items)).history(upTo);

    test(
      'what the earlier part made is listed beneath what the shown part made, whichever order they were read in',
      () {
        final older = read([_say('http://localhost:8790/'), _write('/w/old.html')]);
        final shown = [_say('http://localhost:8765/')];
        final keys = [for (final a in madeAssetsOf(shown, cwd: '/w', history: older)) a.key];
        expect(keys, ['localhost:8765', '/w/old.html', 'localhost:8790']);
      },
    );

    test('the shown part still removes and replaces what the earlier part made', () {
      final older = read([_write('/w/gone.html'), _say('http://localhost:3000/')]);
      final shown = [_delete('/w/gone.html'), _say('Now http://localhost:3000/health')];
      expect(
        [for (final a in madeAssetsOf(shown, cwd: '/w', history: older)) a.key],
        ['localhost:3000/health', 'localhost:3000'],
      );
    });

    test('reading the same lines again on top of a history (a wider tail overlaps it) changes nothing', () {
      final items = [
        _say('http://localhost:3000/'),
        _write('/w/a.html'),
        _delete('/w/a.html'),
        _say('http://localhost:4000/'),
      ];
      final whole = [for (final a in madeAssetsOf(items, cwd: '/w')) a.key];
      final overlapped = [for (final a in madeAssetsOf(items.sublist(1), cwd: '/w', history: read(items))) a.key];
      expect(overlapped.toSet(), whole.toSet());
    });

    test('a history goes on from where an earlier one stopped', () {
      final first = read([_say('http://localhost:3000/')], upTo: 10);
      final second = read([_say('http://localhost:4000/')], upTo: 20, from: first);
      expect(second.span, 2);
      expect(second.upTo, 20);
      expect([for (final a in second.assets) a.key], ['localhost:4000', 'localhost:3000']);
    });

    test('kept bytes read back to the same rows; damage and older rules are a history that does not exist', () {
      final h = read([
        _say('http://localhost:3000/docs'),
        _write('/w/a.html'),
        _say('I created docs/spec.md'),
      ], upTo: 4242);
      final back = MadeHistory.fromBytes(h.toBytes())!;
      expect(back.upTo, 4242);
      expect(back.span, h.span);
      expect(sameMadeAssets(back.assets, h.assets), isTrue);
      expect(back.assets.map((a) => a.order), h.assets.map((a) => a.order));
      expect(MadeHistory.fromBytes(Uint8List.fromList(utf8.encode('{"v":0,"span":1,"upTo":1,"assets":[]}'))), isNull);
      expect(
        MadeHistory.fromBytes(
          Uint8List.fromList(utf8.encode('{"v":$madeScanVersion,"span":1,"upTo":1,"assets":[{"kind":"nope"}]}')),
        ),
        isNull,
      );
      expect(MadeHistory.fromBytes(Uint8List.fromList(utf8.encode('not json'))), isNull);
    });
  });
}
