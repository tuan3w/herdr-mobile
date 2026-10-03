// Renders the raw store screenshots (412x892 dp at 3x) into $HERDR_RAW_DIR
// (default /tmp/herdr_raw). Run with `tool/screenshots/run.sh`, which then
// composes the framed images. Not part of `flutter test`: the folder is
// `screenshot_test`, not `test`.
//
// All names below are invented demo data.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../test/support/shot.dart';
import '../test/ui/ui_harness.dart';

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

MachineProfile _machine(String id, String label, String host, String user,
        {SshAuth auth = SshAuth.key}) =>
    MachineProfile(id: id, label: label, host: host, username: user, auth: auth);

Future<UiHarness> _fleet() => UiHarness.create([
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

Widget Function(Widget) _providers(UiHarness h, {TransportFactory? factory}) => (app) => MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.machines),
        ChangeNotifierProvider.value(value: h.fleet),
        ChangeNotifierProvider.value(value: h.terminalSettings),
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
  }
}

/// A host that never answers: the form stays on "waiting for sign-in".
class _HangingTransport extends UiTransport {
  _HangingTransport(this._never) : super(snapshotWith(const []));

  final Completer<Map<String, dynamic>> _never;

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) =>
      _never.future;
}
