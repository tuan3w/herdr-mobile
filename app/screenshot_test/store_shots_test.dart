// Renders the raw store screenshots (412x892 dp at 3x) into $HERDR_RAW_DIR
// (default /tmp/herdr_raw). Run with `tool/screenshots/run.sh`, which then
// composes the framed images. Not part of `flutter test`: the folder is
// `screenshot_test`, not `test`.
//
// All names below are invented demo data.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/new_session_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/features/create/new_session_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../test/support/create_harness.dart' show MemoryNewSessionStore;
import '../test/support/fake_fs.dart';
import '../test/support/fake_transport.dart' show eventually;
import '../test/support/shot.dart';
import '../test/ui/ui_harness.dart';
import 'dashboard_png.dart';

final _raw = Directory(Platform.environment['HERDR_RAW_DIR'] ?? '/tmp/herdr_raw');

const _esc = '\x1b';
String _c(int r, int g, int b, String s) => '$_esc[38;2;$r;$g;${b}m$s$_esc[0m';
String _dim(String s) => '$_esc[2m$s$_esc[0m';
String _bold(String s) => '$_esc[1m$s$_esc[0m';
String _bg(int r, int g, int b, String s) => '$_esc[48;2;$r;$g;${b}m$s$_esc[0m';

/// A coding agent's session: tool calls, a diff, a passing test run and a
/// permission prompt waiting for an answer.
String _agentSession() {
  const w = 50;
  String pad(String s, int n) => s.length >= n ? s : s + ' ' * (n - s.length);
  String green(String s) => _c(76, 183, 130, s);
  const addBg = (30, 58, 40);
  const delBg = (66, 30, 34);
  String diff(String no, String sign, String code, (int, int, int) bg) {
    final line = pad('  $no $sign $code', 47);
    return _bg(bg.$1, bg.$2, bg.$3, line);
  }

  final box = <String>[
    '╭${'─' * (w - 2)}╮',
    '│ ${_bold(pad('Apply migration to the staging database?', w - 4))} │',
    '│ ${' ' * (w - 4)} │',
    '│ ${_c(154, 163, 242, pad('❯ 1. Yes', w - 4))} │',
    '│ ${pad('  2. Yes, and do not ask again this session', w - 4)} │',
    '│ ${pad('  3. No, tell the agent what to do instead', w - 4)} │',
    '╰${'─' * (w - 2)}╯',
  ];

  String ctx(String no, String code) => _dim(pad('  $no   $code', 47));
  return [
    ' ${_c(154, 163, 242, '>')} Migrate ledger amounts to BIGINT and add a',
    '   currency column. Keep the tests green.',
    '',
    ' ${green('●')} I will start by finding where the table is used.',
    '',
    ' ${green('●')} ${_bold('Search')}(pattern: "ledger_entries")',
    _dim('   └ Found 9 files'),
    _dim('     db/migrations/0042_ledger.sql'),
    _dim('     services/ledger/repository.go'),
    _dim('     services/ledger/repository_test.go'),
    '',
    ' ${green('●')} ${_bold('Read')}(db/migrations/0042_ledger.sql)',
    _dim('   └ Read 48 lines'),
    '',
    ' ${green('●')} ${_bold('Update')}(db/migrations/0042_ledger.sql)',
    _dim('   └ Updated with 3 additions and 1 removal'),
    ctx('41', 'CREATE TABLE ledger_entries ('),
    diff('42', '-', 'amount INTEGER NOT NULL,', delBg),
    diff('42', '+', 'amount BIGINT NOT NULL,', addBg),
    diff('43', '+', "currency CHAR(3) NOT NULL DEFAULT 'EUR',", addBg),
    diff('44', '+', 'fx_rate NUMERIC(12, 6),', addBg),
    ctx('45', 'created_at TIMESTAMPTZ NOT NULL'),
    '',
    ' ${green('●')} ${_bold('Update')}(services/ledger/repository.go)',
    _dim('   └ Updated with 8 additions and 5 removals'),
    '',
    ' ${green('●')} ${_bold('Bash')}(make test-db)',
    '   └ ${green('128 passed')} ${_dim('in 14.2s')}',
    '',
    ' ${_c(226, 192, 90, '●')} Ready to migrate staging. This is the last',
    '   step before the release branch can merge.',
    '',
    ...box,
    _dim('  ↑↓ to select · enter to confirm · esc to cancel'),
  ].join('\n');
}

/// A test run where the output carries things worth tapping: file paths with
/// a line number, and a link to the docs.
String _linksSession() {
  String green(String s) => _c(76, 183, 130, s);
  String red(String s) => _c(235, 87, 87, s);
  String pad(String s, int n) => s.length >= n ? s : s + ' ' * (n - s.length);
  String diff(String no, String sign, String code, (int, int, int) bg) =>
      _bg(bg.$1, bg.$2, bg.$3, pad('     $no $sign $code', 47));
  const addBg = (30, 58, 40);
  const delBg = (66, 30, 34);
  return [
    ' ${_c(154, 163, 242, '>')} Upgrade Flutter, then get analyze and the',
    '   tests passing again.',
    '',
    ' ${green('●')} ${_bold('Bash')}(flutter upgrade)',
    _dim('   └ Flutter is now on the latest stable'),
    '',
    ' ${green('●')} ${_bold('Bash')}(flutter analyze)',
    _dim('   └ 2 issues found'),
    '     lib/ui/core/chrome.dart:118:9',
    _dim('       deprecated_member_use'),
    '     lib/ui/shell/home_shell.dart:64:21',
    _dim('       unused_local_variable'),
    '',
    ' ${green('●')} ${_bold('Update')}(lib/ui/core/chrome.dart)',
    _dim('   └ Updated with 1 addition and 1 removal'),
    diff('118', '-', 'final hit = Size.square(40);', delBg),
    diff('118', '+', 'final hit = Size.square(44);', addBg),
    '',
    ' ${green('●')} ${_bold('Update')}(lib/ui/shell/home_shell.dart)',
    _dim('   └ Updated with 0 additions and 1 removal'),
    '',
    ' ${green('●')} ${_bold('Bash')}(flutter test)',
    '   └ ${red('1 failed')}, 214 passed',
    '     ${red('✗')} CircleButton keeps a 44dp tap target',
    '       test/ui/chrome_test.dart:42:7',
    '',
    ' ${green('●')} The button was 40dp after the upgrade. I',
    '   fixed it in lib/ui/core/chrome.dart:118.',
    '   The Material 3 notes are here:',
    '   https://docs.flutter.dev/ui/design/material',
    '',
    ' ${green('●')} ${_bold('Bash')}(flutter test)',
    '   └ ${green('215 passed')} ${_dim('in 12.4s')}',
    '',
    ' ${green('●')} ${_bold('Bash')}(flutter analyze)',
    '   └ ${green('No issues found!')}',
    '',
    ' ${green('●')} Done. Tests and analyze are both clean.',
    '   Review the change in lib/ui/core/chrome.dart',
    '   and the new test in test/ui/chrome_test.dart.',
  ].join('\n');
}

/// The source file the viewer shows (tabs, as a Go file has them).
const _repositoryGo = '''package ledger

import (
\t"context"
\t"database/sql"
\t"fmt"
)

// Entry is one row of ledger_entries.
type Entry struct {
\tID       int64
\tAccount  string
\tAmount   int64  // minor units
\tCurrency string // ISO 4217
\tFXRate   sql.NullFloat64
}

type Repository struct {
\tdb *sql.DB
}

func NewRepository(db *sql.DB) *Repository {
\treturn &Repository{db: db}
}

// Insert stores e and returns its new ID.
func (r *Repository) Insert(
\tctx context.Context, e Entry,
) (int64, error) {
\tconst q = `
INSERT INTO ledger_entries
  (account, amount, currency, fx_rate)
VALUES (\$1, \$2, \$3, \$4)
RETURNING id`
\tvar id int64
\terr := r.db.QueryRowContext(ctx, q,
\t\te.Account, e.Amount, e.Currency,
\t\te.FXRate,
\t).Scan(&id)
\tif err != nil {
\t\treturn 0, fmt.Errorf("insert entry: %w", err)
\t}
\treturn id, nil
}
''';

const _studioHome = '/Users/maya';
const _projectDir = '$_studioHome/code/payments-api';
const _chartPath = '$_projectDir/docs/checkout-latency.png';

/// What each machine's file browser can reach. Every machine gets a file
/// system, which is what puts the Files button in the pane's top bar.
FakeFs _studioFs(Uint8List chart) {
  final now = DateTime.now();
  DateTime ago(Duration d) => now.subtract(d);
  final fs = FakeFs(home: _studioHome);
  void dir(String path, Duration age) {
    fs.addDir(path);
    fs.nodes[path] = FakeNode.dir(modified: ago(age));
  }

  void file(String path, int size, Duration age) =>
      fs.addFile(path, Uint8List(size), modified: ago(age));

  dir('$_projectDir/cmd', const Duration(days: 12));
  dir('$_projectDir/db', const Duration(hours: 2));
  dir('$_projectDir/db/migrations', const Duration(hours: 2));
  dir('$_projectDir/docs', const Duration(minutes: 6));
  dir('$_projectDir/internal', const Duration(days: 3));
  dir('$_projectDir/scripts', const Duration(days: 21));
  dir('$_projectDir/services', const Duration(hours: 2));
  dir('$_projectDir/services/ledger', const Duration(hours: 2));
  dir('$_projectDir/.git', const Duration(minutes: 40));
  dir('$_projectDir/.github', const Duration(days: 30));
  file('$_projectDir/README.md', 2400, const Duration(days: 9));
  file('$_projectDir/Makefile', 1100, const Duration(days: 4));
  file('$_projectDir/Dockerfile', 640, const Duration(days: 18));
  file('$_projectDir/docker-compose.yml', 1800, const Duration(days: 18));
  file('$_projectDir/go.mod', 1500, const Duration(hours: 5));
  file('$_projectDir/go.sum', 61000, const Duration(hours: 5));
  file('$_projectDir/.env.example', 320, const Duration(days: 40));
  file('$_projectDir/.gitignore', 120, const Duration(days: 40));
  file('$_projectDir/db/migrations/0041_accounts.sql', 900, const Duration(days: 8));
  file('$_projectDir/db/migrations/0042_ledger.sql', 1300, const Duration(hours: 2));
  fs.addFile('$_projectDir/docs/checkout-latency.png', chart, modified: ago(const Duration(minutes: 6)));
  file('$_projectDir/docs/architecture.md', 5200, const Duration(days: 15));
  fs.addFile(
    '$_projectDir/services/ledger/repository.go',
    _repositoryGo,
    modified: ago(const Duration(hours: 2)),
  );
  file('$_projectDir/services/ledger/repository_test.go', 4100, const Duration(hours: 2));
  file('$_studioHome/code/mobile-app/lib/ui/core/chrome.dart', 9100, const Duration(minutes: 20));
  return fs;
}

MachineProfile _machine(String id, String label, String host, String user,
        {SshAuth auth = SshAuth.key}) =>
    MachineProfile(id: id, label: label, host: host, username: user, auth: auth);

Future<UiHarness> _fleet({Uint8List? chart}) async {
  final h = await UiHarness.create([
      (
        profile: _machine('a', 'studio-mac', 'studio-mac.tail1a2b.ts.net', 'maya', auth: SshAuth.none),
        snapshot: snapshotWith(
          const [
            (id: 'a1:p1', ws: 'a1', agent: 'claude', status: 'blocked'),
            (id: 'a1:p2', ws: 'a1', agent: 'omp', status: 'working'),
            (id: 'a2:p1', ws: 'a2', agent: 'codex', status: 'working'),
          ],
          workspaces: const [
            (id: 'a1', label: 'payments-api'),
            (id: 'a2', label: 'mobile-app'),
          ],
          title: (id) => const {
                'a1:p1': 'Approve migration for payments ledger',
                'a1:p2': 'Fix flaky retry test in checkout',
                'a2:p1': 'Upgrade Flutter and fix analyzer warnings',
              }[id] ??
              '',
          cwd: (id) => id.startsWith('a1') ? '/Users/maya/code/payments-api' : '/Users/maya/code/mobile-app',
        ),
      ),
      (
        profile: _machine('b', 'build-server', '10.0.4.21', 'deploy'),
        snapshot: snapshotWith(
          const [
            (id: 'b1:p1', ws: 'b1', agent: 'omp', status: 'blocked'),
            (id: 'b1:p2', ws: 'b1', agent: 'claude', status: 'done'),
            (id: 'b1:p3', ws: 'b1', agent: 'omp', status: 'idle'),
          ],
          workspaces: const [(id: 'b1', label: 'infra')],
          title: (id) => const {
                'b1:p1': 'Delete unused feature flags?',
                'b1:p2': 'Rotate staging TLS certificates',
                'b1:p3': 'Triage overnight CI failures',
              }[id] ??
              '',
          cwd: (_) => '/srv/infra',
        ),
      ),
      (
        profile: _machine('c', 'gpu-box', 'gpu-box.lab.local', 'maya'),
        snapshot: snapshotWith(
          const [
            (id: 'c1:p1', ws: 'c1', agent: 'omp', status: 'working'),
            (id: 'c1:p2', ws: 'c1', agent: 'claude', status: 'idle'),
          ],
          workspaces: const [(id: 'c1', label: 'research')],
          title: (id) => const {
                'c1:p1': 'Profile training step and tune the optimizer',
                'c1:p2': 'Summarise eval results for the weekly report',
              }[id] ??
              '',
          cwd: (_) => '/home/maya/research',
        ),
      ),
    ]);
  h.transports['a']!.fs = _studioFs(chart ?? Uint8List(0));
  h.transports['b']!.fs = FakeFs(home: '/home/deploy');
  h.transports['c']!.fs = FakeFs(home: '/home/maya');
  return h;
}

Widget Function(Widget) _providers(UiHarness h, {TransportFactory? factory, NewSessionSettings? newSession}) =>
    (app) => MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: h.machines),
            ChangeNotifierProvider.value(value: h.fleet),
            ChangeNotifierProvider.value(value: h.terminalSettings),
            if (newSession != null) ChangeNotifierProvider.value(value: newSession),
            Provider<TransportFactory>.value(
              value: factory ?? (profile, secrets, onPin, onNotice) => UiTransport(snapshotWith(const [])),
            ),
          ],
          child: app,
        );

void main() {
  setUpAll(() async {
    await loadAppFonts();
    _raw.createSync(recursive: true);
  });

  for (final b in Brightness.values) {
    final tone = b.name;

    testWidgets('agents $tone', (tester) async {
      final h = await _fleet();
      await shoot(tester, const HomeShell(), '${_raw.path}/agents_$tone.png',
          brightness: b, wrap: _providers(h), imageScale: 3);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('machines $tone', (tester) async {
      final h = await _fleet();
      await shoot(tester, const HomeShell(), '${_raw.path}/machines_$tone.png',
          brightness: b, wrap: _providers(h), imageScale: 3, pump: (t) async {
        await t.tap(find.text('Machines').last);
        await t.pump(const Duration(milliseconds: 600));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('pane $tone', (tester) async {
      final h = await _fleet();
      h.transports['a']!.paneText = _agentSession();
      await shoot(tester, const HomeShell(), '${_raw.path}/pane_$tone.png',
          brightness: b, wrap: _providers(h), imageScale: 3, pump: (t) async {
        await t.tap(find.textContaining('Approve migration'));
        await t.pump(const Duration(milliseconds: 800));
        await t.pump(const Duration(milliseconds: 800));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('reply $tone', (tester) async {
      final h = await _fleet();
      h.transports['a']!.paneText = _agentSession();
      await shoot(tester, const HomeShell(), '${_raw.path}/reply_$tone.png',
          brightness: b, wrap: _providers(h), imageScale: 3, pump: (t) async {
        await t.tap(find.textContaining('Approve migration'));
        await t.pump(const Duration(milliseconds: 800));
        await t.pump(const Duration(milliseconds: 800));
        await t.enterText(find.byType(TextField), '1');
        await t.pump(const Duration(milliseconds: 300));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('tailscale $tone', (tester) async {
      final h = await _fleet();
      final pending = Completer<Map<String, dynamic>>();
      addTearDown(() {
        if (!pending.isCompleted) pending.completeError(const HerdrTransportException('done'));
      });
      HerdrTransport factory(MachineProfile profile, MachineSecrets s, void Function(String) onPin,
          void Function(String) onNotice) {
        scheduleMicrotask(() => onNotice(
              '# Tailscale SSH requires an additional check.\n'
              '# To authenticate, visit: https://login.tailscale.com/a/l3a91f0c2d7b5e',
            ));
        return _HangingTransport(pending);
      }
      await shoot(tester, const MachineFormScreen(),
          '${_raw.path}/tailscale_$tone.png',
          brightness: b, wrap: _providers(h, factory: factory), imageScale: 3, pump: (t) async {
        final fields = find.byType(TextFormField);
        await t.enterText(fields.at(0), 'studio-mac');
        await t.enterText(fields.at(1), 'studio-mac.tail1a2b.ts.net');
        await t.enterText(fields.at(3), 'maya');
        await t.tap(find.text('Tailscale').first);
        await t.pump(const Duration(milliseconds: 400));
        await t.tap(find.text('Test connection'));
        await t.pump(const Duration(milliseconds: 600));
        await t.pump(const Duration(milliseconds: 600));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('links $tone', (tester) async {
      final h = await _fleet();
      h.transports['a']!.paneText = _linksSession();
      await shoot(tester, const HomeShell(), '${_raw.path}/links_$tone.png',
          brightness: b, wrap: _providers(h), imageScale: 3, pump: (t) async {
        await t.tap(find.textContaining('Upgrade Flutter'));
        await t.pump(const Duration(milliseconds: 800));
        await t.pump(const Duration(milliseconds: 800));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('files $tone', (tester) async {
      final h = await _fleet();
      await shoot(
        tester,
        FileViewerScreen(
          machine: h.fleet.connection('a')!,
          stat: _stat(h, '$_projectDir/services/ledger/repository.go'),
          line: 13,
        ),
        '${_raw.path}/files_$tone.png',
        brightness: b,
        wrap: _providers(h),
        imageScale: 3,
      );
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('browser $tone', (tester) async {
      final h = await _fleet();
      await shoot(
        tester,
        FileBrowserScreen(machine: h.fleet.connection('a')!, path: _projectDir),
        '${_raw.path}/browser_$tone.png',
        brightness: b,
        wrap: _providers(h),
        imageScale: 3,
      );
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('image $tone', (tester) async {
      final h = await _fleet(chart: await dashboardPng(tester, dark: b == Brightness.dark));
      await shoot(
        tester,
        FileViewerScreen(machine: h.fleet.connection('a')!, stat: _stat(h, _chartPath)),
        '${_raw.path}/image_$tone.png',
        brightness: b,
        wrap: _providers(h),
        imageScale: 3,
        pump: (t) async {
          for (var i = 0; i < 80 && find.byType(RawImage).evaluate().isEmpty; i++) {
            await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
            await t.pump();
          }
          await t.pump(const Duration(milliseconds: 600));
        },
      );
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('new-session $tone', (tester) async {
      final h = await _fleet();
      await tester.runAsync(() => eventually(() => h.fleet.connections.every((c) => c.isLive)));
      final settings = NewSessionSettings(MemoryNewSessionStore());
      Finder field(String label) => find.descendant(
            of: find.byWidgetPredicate((w) => w is LabeledField && w.label == label),
            matching: find.byType(TextFormField),
          );
      await shoot(
        tester,
        const NewSessionScreen(machineId: 'a'),
        '${_raw.path}/new-session_$tone.png',
        brightness: b,
        wrap: _providers(h, newSession: settings),
        imageScale: 3,
        pump: (t) async {
          await t.enterText(field('Folder'), _projectDir);
          await t.pump(const Duration(milliseconds: 300));
          final claude = find.widgetWithText(AppChip, 'claude');
          await t.ensureVisible(claude);
          await flush(t);
          await t.tap(claude);
          await flush(t);
          await t.enterText(
            field('First message (optional)'),
            'Migrate ledger amounts to BIGINT and add a currency column. Keep the tests green.',
          );
          await t.pump(const Duration(milliseconds: 300));
          // Scroll the title away so the folder, agent, command and first
          // message are on screen together.
          await t.drag(find.byType(CustomScrollView), const Offset(0, -205));
          await flush(t);
        },
      );
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });
  }
}

/// Lets queued microtasks and animations run (the form's view model answers
/// through futures that a bare `pump` does not wait for).
Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The stat the browser would hand the viewer for [path].
RemoteStat _stat(UiHarness h, String path) {
  final node = h.transports['a']!.fs!.nodes[path]!;
  return RemoteStat(
    path: path,
    kind: RemoteEntryKind.file,
    size: node.bytes.length,
    modified: node.modified,
  );
}

/// A host that never answers: the form stays on "waiting for sign-in".
class _HangingTransport extends UiTransport {
  _HangingTransport(this._never) : super(snapshotWith(const []));

  final Completer<Map<String, dynamic>> _never;

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) =>
      _never.future;
}
