// What the demo agents' terminals show. All names are invented. Rows stay
// within ~50 columns so they fit the pane without wrapping, and the last rows
// read well in a board card (a card shows the final 2 to 3 rows).
const _esc = '\x1b';
String _c(int r, int g, int b, String s) => '$_esc[38;2;$r;$g;${b}m$s$_esc[0m';
String _dim(String s) => '$_esc[2m$s$_esc[0m';
String _bold(String s) => '$_esc[1m$s$_esc[0m';
String _bg(int r, int g, int b, String s) => '$_esc[48;2;$r;$g;${b}m$s$_esc[0m';

String _green(String s) => _c(76, 183, 130, s);
String _red(String s) => _c(235, 87, 87, s);
String _amber(String s) => _c(226, 192, 90, s);
String _accent(String s) => _c(154, 163, 242, s);
final _sgr = RegExp('\x1b\\[[0-9;]*m');

/// [s] padded with spaces to [n] visible columns (escape codes take none).
String _pad(String s, int n) {
  final visible = s.replaceAll(_sgr, '').length;
  return visible >= n ? s : s + ' ' * (n - visible);
}

const _addBg = (30, 58, 40);
const _delBg = (66, 30, 34);

String _diff(String no, String sign, String code, (int, int, int) bg, {int indent = 2}) =>
    _bg(bg.$1, bg.$2, bg.$3, _pad('${' ' * indent}$no $sign $code', 47));

String _ctx(String no, String code) => _dim(_pad('  $no   $code', 47));

/// A box in the style of an agent's permission dialog (50 columns).
List<String> _box(List<String> rows) {
  const w = 50;
  return [
    '╭${'─' * (w - 2)}╮',
    for (final r in rows) '│ ${_pad(r, w - 4)} │',
    '╰${'─' * (w - 2)}╯',
  ];
}

/// claude on studio-mac, blocked on a numbered permission menu.
String claudeMigrationSession() => [
      ' ${_accent('>')} Migrate ledger amounts to BIGINT and add a',
      '   currency column. Keep the tests green.',
      '',
      ' ${_green('●')} I will start by finding where the table is used.',
      '',
      ' ${_green('●')} ${_bold('Search')}(pattern: "ledger_entries")',
      _dim('   └ Found 9 files'),
      _dim('     db/migrations/0042_ledger.sql'),
      _dim('     services/ledger/repository.go'),
      _dim('     services/ledger/repository_test.go'),
      '',
      ' ${_green('●')} ${_bold('Read')}(db/migrations/0042_ledger.sql)',
      _dim('   └ Read 48 lines'),
      '',
      ' ${_green('●')} ${_bold('Update')}(db/migrations/0042_ledger.sql)',
      _dim('   └ Updated with 3 additions and 1 removal'),
      _ctx('41', 'CREATE TABLE ledger_entries ('),
      _diff('42', '-', 'amount INTEGER NOT NULL,', _delBg),
      _diff('42', '+', 'amount BIGINT NOT NULL,', _addBg),
      _diff('43', '+', "currency CHAR(3) NOT NULL DEFAULT 'EUR',", _addBg),
      _diff('44', '+', 'fx_rate NUMERIC(12, 6),', _addBg),
      _ctx('45', 'created_at TIMESTAMPTZ NOT NULL'),
      '',
      ' ${_green('●')} ${_bold('Update')}(services/ledger/repository.go)',
      _dim('   └ Updated with 8 additions and 5 removals'),
      '',
      ' ${_green('●')} ${_bold('Bash')}(make test-db)',
      '   └ ${_green('128 passed')} ${_dim('in 14.2s')}',
      '',
      ' ${_amber('●')} Ready to migrate staging. This is the last',
      '   step before the release branch can merge.',
      '',
      ..._box([
        _bold('Do you want to proceed?'),
        'Bash command: make migrate ENV=staging',
        '',
        _accent('❯ 1. Yes'),
        "  2. Yes, and don't ask again for make migrate",
        '  3. No, and tell Claude what to do (esc)',
      ]),
    ].join('\n');

/// omp on studio-mac, running a test loop.
String ompFlakyTestSession() => [
      ' ${_accent('>')} Fix the flaky retry test in checkout. It fails',
      '   about one run in five.',
      '',
      ' ${_green('●')} I will reproduce it with a loop first.',
      '',
      ' ${_green('●')} ${_bold('Search')}(pattern: "TestRetryBackoff")',
      _dim('   └ Found 2 files'),
      _dim('     services/checkout/retry_test.go'),
      _dim('     services/checkout/retry.go'),
      '',
      ' ${_green('●')} ${_bold('Bash')}(go test ./services/checkout -count=20)',
      '   └ ${_red('FAIL')} after 7 runs',
      _dim('     --- FAIL: TestRetryBackoff (0.31s)'),
      _dim('       retry_test.go:58: waited 140ms, want 200ms'),
      '',
      ' ${_green('●')} ${_bold('Read')}(services/checkout/retry.go)',
      _dim('   └ Read 96 lines'),
      '',
      ' ${_green('●')} The test measures wall time, and the backoff',
      '   adds jitter. I will inject a fake clock.',
      '',
      ' ${_green('●')} ${_bold('Update')}(services/checkout/retry.go)',
      _dim('   └ Updated with 6 additions and 1 removal'),
      _ctx('31', 'func NewRetrier(c Clock, cfg Config) {'),
      _diff('32', '-', 'return &Retrier{cfg: cfg}', _delBg),
      _diff('32', '+', 'return &Retrier{clock: c, cfg: cfg}', _addBg),
      '',
      ' ${_green('●')} ${_bold('Update')}(services/checkout/retry_test.go)',
      _dim('   └ Updated with 4 additions and 2 removals'),
      _ctx('56', 'clock := newFakeClock()'),
      _diff('57', '-', 'start := time.Now()', _delBg),
      _diff('58', '-', 'assert.GreaterOrEqual(elapsed, 200ms)', _delBg),
      _diff('57', '+', 'r := NewRetrier(clock, cfg)', _addBg),
      _diff('58', '+', 'assert.Equal(200*time.Millisecond,', _addBg),
      _diff('59', '+', '    clock.Slept())', _addBg),
      '',
      ' ${_green('●')} ${_bold('Bash')}(go test ./services/checkout -count=50)',
      '   └ ${_dim('Running tests... (esc to interrupt)')}',
    ].join('\n');

/// codex on studio-mac, with paths and a link in its output. [finished] is the
/// state after the last command ended.
String codexFlutterSession({bool finished = false}) => [
      ' ${_accent('>')} Upgrade Flutter, then get analyze and the',
      '   tests passing again.',
      '',
      ' ${_green('●')} ${_bold('Bash')}(flutter upgrade)',
      _dim('   └ Flutter is now on the latest stable'),
      '',
      ' ${_green('●')} ${_bold('Bash')}(flutter analyze)',
      _dim('   └ 2 issues found'),
      '     lib/ui/core/chrome.dart:118:9',
      _dim('       deprecated_member_use'),
      '     lib/ui/shell/home_shell.dart:64:21',
      _dim('       unused_local_variable'),
      '',
      ' ${_green('●')} ${_bold('Update')}(lib/ui/core/chrome.dart)',
      _dim('   └ Updated with 1 addition and 1 removal'),
      _diff('118', '-', 'final hit = Size.square(40);', _delBg, indent: 5),
      _diff('118', '+', 'final hit = Size.square(44);', _addBg, indent: 5),
      '',
      ' ${_green('●')} ${_bold('Bash')}(flutter test)',
      '   └ ${_red('1 failed')}, 214 passed',
      '     ${_red('✗')} CircleButton keeps a 44dp tap target',
      '       test/ui/chrome_test.dart:42:7',
      '',
      ' ${_green('●')} The button was 40dp after the upgrade. I',
      '   fixed it in lib/ui/core/chrome.dart:118.',
      '   The Material 3 notes are here:',
      '   https://docs.flutter.dev/ui/design/material',
      '',
      ' ${_green('●')} ${_bold('Bash')}(flutter test)',
      '   └ ${_green('215 passed')} ${_dim('in 12.4s')}',
      '',
      if (finished) ...[
        ' ${_green('●')} ${_bold('Bash')}(flutter analyze)',
        '   └ ${_green('No issues found!')}',
        '',
        ' ${_green('●')} Done. Tests and analyze are both clean.',
        '   Review lib/ui/core/chrome.dart and the new',
        '   test in test/ui/chrome_test.dart.',
      ] else ...[
        ' ${_green('●')} ${_bold('Bash')}(flutter analyze)',
        '   └ ${_dim('Running analyze... (esc to interrupt)')}',
      ],
    ].join('\n');

/// omp on build-server, removing dead feature flags.
String ompFlagsSession() => [
      ' ${_accent('>')} Find feature flags nobody reads any more and',
      '   remove them.',
      '',
      ' ${_green('●')} ${_bold('Bash')}(grep -rn "flag_" config services)',
      _dim('   └ Found 41 matches in 12 files'),
      '',
      ' ${_green('●')} ${_bold('Read')}(config/flags.yaml)',
      _dim('   └ Read 120 lines'),
      '',
      ' ${_green('●')} 6 flags have no references in the code:',
      '     beta_checkout, legacy_sso, new_nav_v2,',
      '     promo_banner, retry_v1, ui_dark_preview',
      '',
      ' ${_green('●')} ${_bold('Update')}(config/flags.yaml)',
      _dim('   └ Updated with 0 additions and 6 removals'),
      '',
      ' ${_green('●')} ${_bold('Bash')}(make test)',
      '   └ ${_dim('Running tests... (esc to interrupt)')}',
    ].join('\n');

/// claude on build-server, finished.
String claudeCertsSession() => [
      ' ${_accent('>')} Rotate the staging TLS certificates.',
      '',
      ' ${_green('●')} ${_bold('Bash')}(./scripts/rotate-certs.sh staging)',
      _dim('   └ Renewed 3 certificates'),
      '',
      ' ${_green('●')} ${_bold('Bash')}(./scripts/check-tls.sh staging)',
      '   └ ${_green('12 of 12 handshakes OK')}',
      '',
      ' ${_green('●')} Done. Rotated 3 certificates on staging.',
      '   All 12 TLS checks pass; next expiry in 89 days.',
    ].join('\n');

/// omp on raspi-lab, finished.
String ompSensorsSession() => [
      ' ${_accent('>')} Calibrate the temperature sensors against',
      '   the reference probe.',
      '',
      ' ${_green('●')} ${_bold('Bash')}(python calibrate.py --all)',
      '   └ ${_green('4 of 4 sensors within 0.2 °C')}',
      '',
      ' ${_green('●')} Done. Offsets are saved to sensors.toml.',
      '   The next calibration is due in 90 days.',
    ].join('\n');

/// omp on gpu-box, benchmarking.
String ompProfileSession() => [
      ' ${_accent('>')} Profile the training step and tune the',
      '   optimizer.',
      '',
      ' ${_green('●')} ${_bold('Bash')}(python profile_step.py --steps 200)',
      _dim('   └ data 12% · forward 31% · backward 44%'),
      _dim('     optimizer 13%'),
      '',
      ' ${_green('●')} The optimizer step is launch-bound. I will',
      '   try the fused AdamW kernel.',
      '',
      ' ${_green('●')} ${_bold('Update')}(train/optim.py)',
      _dim('   └ Updated with 6 additions and 2 removals'),
      '',
      ' ${_green('●')} ${_bold('Bash')}(python bench.py --opt fused-adamw)',
      _dim('   └ warmup 20 steps, timing 200 steps'),
      '   ${_dim('Running benchmark... (esc to interrupt)')}',
    ].join('\n');

/// Idle agents: their last answer and an empty prompt.
String idleSession(String summary) => [
      ' ${_green('●')} $summary',
      '',
      ..._box([_dim('> ')]),
    ].join('\n');

/// The Go file shown by the file viewer (tabs, as gofmt writes it).
const repositoryGo = '''package ledger

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
