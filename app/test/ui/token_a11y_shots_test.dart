// Renders what the colour-token fixes and the keyboard focus ring touch, for
// review: the dark terminal's ANSI colours, a pane's key row with a key held
// down, a failure toast, the machines tab, the board, and the kit's colour
// sheet, switch, text actions and chips. Light and dark at 412x892; the focus
// ring also at 320x640, text scale 1.6. Off by default; it writes files:
//
//   TOKEN_SHOTS=1 TOKEN_SHOTS_PHASE=before flutter test test/ui/token_a11y_shots_test.dart
//
// Output: $TOKEN_SHOTS_DIR (default /dev/shm/token_shots)/<id>-<phase>-<light|dark>[-320x1.6].png
// where <phase> is `before` or `after` (TOKEN_SHOTS_PHASE, default `after`).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/kit/kit_catalog.dart';
import 'package:herdr_mobile/ui/features/kit/kit_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/render/terminal/terminal_view.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart';
import 'board_support.dart';
import 'ui_harness.dart';

const _esc = '\x1b';

/// Every ANSI colour as text on the terminal page, the way a TUI uses them
/// (`ls`, a diff, dim hints).
final _ansiScreen = [
  for (var row = 0; row < 2; row++)
    [
      for (var i = 0; i < 8; i++)
        '$_esc[${(row == 0 ? 30 : 90) + i}m${(row * 8 + i).toString().padLeft(2)} ${_names[i].padRight(7)}$_esc[0m',
    ].join('\r\n'),
  '',
  '$_esc[1;30mbold black$_esc[0m  $_esc[2mdim default$_esc[0m  $_esc[90mhint: press enter$_esc[0m',
  '$_esc[37;40m white on black $_esc[0m $_esc[30;47m black on white $_esc[0m',
].join('\r\n');

const _names = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white'];

HerdrTransport _noTransport(
  MachineProfile profile,
  MachineSecrets secrets,
  void Function(String) onPin,
  void Function(String) onNotice,
) => throw StateError('shots never open a connection');

MachineProfile _m(String id, String label, {bool enabled = true}) =>
    MachineProfile(id: id, label: label, host: '$id.example', username: 'dev', enabled: enabled);

List<Pane> _agents(int n, {int blocked = 0}) => [
  for (var i = 0; i < n; i++) (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: i < blocked ? 'blocked' : 'working'),
];

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  if (Platform.environment['TOKEN_SHOTS'] == null) {
    test('token shots are off (set TOKEN_SHOTS=1)', () {}, skip: 'set TOKEN_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['TOKEN_SHOTS_DIR'] ?? '/dev/shm/token_shots';
  final phase = Platform.environment['TOKEN_SHOTS_PHASE'] ?? 'after';

  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  String path(String id, Brightness b, [String tag = '']) => '$out/$id-$phase-${b.name}$tag.png';

  for (final b in Brightness.values) {
    testWidgets('ansi colours on the dark terminal, ${b.name} theme', (tester) async {
      await shoot(
        tester,
        Scaffold(
          body: SafeArea(child: TerminalView(text: _ansiScreen)),
        ),
        path('t1-ansi', b),
        brightness: b,
      );
    });

    testWidgets('key row with one key held down, ${b.name}', (tester) async {
      await shoot(
        tester,
        Scaffold(
          body: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Wrap(
                  spacing: Gap.sm,
                  children: [
                    KeyCap(label: 'esc', onTap: () {}),
                    KeyCap(label: 'tab', onTap: () {}),
                    KeyCap(label: 'ctrl', active: true, onTap: () {}),
                    KeyCap(icon: LucideIcons.arrowUp, semanticLabel: 'Up', onTap: () {}),
                    KeyCap(label: 'enter', onTap: () {}),
                  ],
                ),
              ),
            ),
          ),
        ),
        path('t2-keys-pressed', b),
        brightness: b,
        pump: (t) async {
          await t.startGesture(t.getCenter(find.text('tab')));
          await t.pump(const Duration(milliseconds: 300));
        },
      );
    });

    testWidgets('a failure toast, ${b.name}', (tester) async {
      await shoot(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: AppButton(
                label: 'Show',
                onPressed: () => showToast(
                  context,
                  'Could not send. Check the connection and try again.',
                  kind: ToastKind.failed,
                  action: ToastAction('Retry', () {}),
                ),
              ),
            ),
          ),
        ),
        path('t2-toast-failed', b),
        brightness: b,
        pump: (t) async {
          await t.tap(find.text('Show'));
          await t.pump();
          await t.pump(const Duration(milliseconds: 500));
        },
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('machines tab, ${b.name}', (tester) async {
      final h = await UiHarness.create([
        (profile: _m('online', 'workstation'), snapshot: snapshotWith(_agents(3, blocked: 2))),
        (profile: _m('offline', 'laptop'), snapshot: snapshotWith(_agents(1))),
        (profile: _m('sleepy', 'sleepy', enabled: false), snapshot: snapshotWith(const [])),
      ]);
      h.fleet.connection('offline')!.goOffline();
      await shoot(
        tester,
        const MachinesScreen(),
        path('t2-machines', b),
        brightness: b,
        wrap: (app) => MultiProvider(
          providers: [
            Provider<TransportFactory>.value(value: _noTransport),
            ChangeNotifierProvider.value(value: h.machines),
            ChangeNotifierProvider.value(value: h.fleet),
            attentionSetProvider(),
          ],
          child: app,
        ),
        pump: _flush,
      );
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('the board, ${b.name}', (tester) async {
      final h = await BoardHarness.create([
        (
          profile: const MachineProfile(id: 'a', label: 'studio-mac', host: 'a.example', username: 'dev'),
          snapshot: snapshotWith([
            (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
            (id: 'w1:p2', ws: 'w1', agent: 'codex', status: 'working'),
            (id: 'w1:p3', ws: 'w1', agent: 'claude', status: 'idle'),
          ], title: (id) => 'payments-api ${id.substring(id.length - 1)}'),
        ),
      ]);
      h.previews.set('a/w1:p1', ['…']);
      h.previews.set('a/w1:p2', ['reading schema.sql', 'running tests']);
      await shoot(
        tester,
        const HomeShell(),
        path('t2-board', b),
        brightness: b,
        wrap: (app) => MultiProvider(providers: h.providers, child: app),
        pump: _flush,
      );
      await teardownBoard(tester, h);
    });

    for (final slug in ['colour-roles', 'keycap', 'appswitch-switchrow', 'textaction', 'appchip', 'listrow']) {
      testWidgets('kit $slug, ${b.name}', (tester) async {
        final entry = kitCatalog.firstWhere((e) => e.slug == slug);
        await shoot(
          tester,
          KitEntryPage(entry: entry, dark: b == Brightness.dark),
          path('t2-kit-$slug', b),
          brightness: b,
          pump: (t) async {
            final body = t.getSize(find.byKey(KitEntryPage.bodyKey)).height;
            final view = t.getSize(find.byKey(KitEntryPage.scrollKey)).height;
            if (body > view) {
              t.view.physicalSize = Size(phone.width, phone.height + body - view) * phoneDpr;
              await t.pump();
              await t.pump(const Duration(milliseconds: 500));
            }
          },
        );
      });
    }

    testWidgets('disabled text actions, was and is, ${b.name}', (tester) async {
      // `was` redraws the old dimming (the label at 40% alpha) so before and
      // after sit in one picture; `is` is the real, disabled TextAction.
      Widget was(BuildContext context, String label, Color rest) => Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Text(label, style: Type.labelStrong.copyWith(color: Ds.fade(rest, 0.4))),
      );
      await shoot(
        tester,
        Builder(
          builder: (context) {
            final ds = context.ds;
            Widget column(String title, Color bg) => Container(
              color: bg,
              padding: const EdgeInsets.symmetric(vertical: Gap.lg, horizontal: Gap.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Type.caption.copyWith(color: ds.textMuted)),
                  was(context, 'Read all (was)', ds.accentText),
                  TextAction(label: 'Read all (is)', onTap: () {}, enabled: false),
                  was(context, 'Cancel request (was)', ds.textSecondary),
                  TextAction(label: 'Cancel request (is)', tone: TextActionTone.quiet, onTap: () {}, enabled: false),
                  TextAction(label: 'Read all (enabled)', onTap: () {}),
                ],
              ),
            );
            return Scaffold(
              backgroundColor: ds.bg,
              body: SafeArea(
                child: Column(
                  children: [
                    column('on the page', ds.bg),
                    column('on a sheet', ds.surface),
                    column('on a panel', ds.fill),
                  ],
                ),
              ),
            );
          },
        ),
        path('t5-textaction-disabled', b),
        brightness: b,
      );
    });

    // Keyboard focus: tab to the n-th control, then capture. Before the ring
    // existed nothing was focusable, so these show the page unchanged.
    for (final (id, tabs) in [('row', 1), ('chip', 2), ('key', 4), ('button', 6)]) {
      for (final (size, scale) in [(phone, 1.0), (const Size(320, 640), 1.6)]) {
        final tag = size == phone ? '' : '-320x1.6';
        testWidgets('focus ring on the $id, ${b.name} $size', (tester) async {
          await shoot(
            tester,
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: const _FocusPage(),
              ),
            ),
            path('t3-focus-$id', b, tag),
            brightness: b,
            size: size,
            pump: (t) async {
              for (var i = 0; i < tabs; i++) {
                await t.sendKeyEvent(LogicalKeyboardKey.tab);
              }
              await t.pump(const Duration(milliseconds: 300));
            },
          );
        });
      }
    }
  }
}

/// One of each control kind that takes a press, in tab order: a row, a chip, a
/// key, a primary button.
class _FocusPage extends StatelessWidget {
  const _FocusPage();

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Scaffold(
      backgroundColor: ds.bg,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: Gap.lg),
          children: [
            ListRow(
              title: 'payments-api',
              subtitle: 'studio-mac · waiting for you',
              onTap: () {},
              trailing: Icon(LucideIcons.chevronRight, size: IconSize.row, color: ds.textTertiary),
            ),
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.sm,
                children: [
                  AppChip(label: 'Needs you', count: 2, selected: true, onTap: () {}),
                  AppChip(label: 'All', onTap: () {}),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
              child: Wrap(
                spacing: Gap.sm,
                children: [
                  KeyCap(label: 'esc', onTap: () {}),
                  KeyCap(label: 'tab', onTap: () {}),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(Gap.lg),
              child: AppButton(label: 'Send', onPressed: () {}),
            ),
          ],
        ),
      ),
    );
  }
}
