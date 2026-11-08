// Renders the app sheet in its states to PNGs for review: a tall sheet (a
// file's lines) at half height, dragged to full and pulled past it; a tall
// form whose buttons stay on the screen at half; a short confirmation; a form
// on the keyboard. Light and dark, 412x892 and 320x640, text scale 1 and 1.6.
// Off by default; it writes files:
//
//   SHEET_SHOTS=1 flutter test test/ui/sheet_shots_test.dart
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import '../support/shot.dart';

/// A file as an evidence sheet shows it: numbered lines, some long.
Widget _file(BuildContext context) => SheetScaffold(
  title: 'lib/data/repositories/machine_connection_repository_impl.dart',
  kind: SheetKind.list,
  scrolls: true,
  child: ListView.builder(
    padding: const EdgeInsets.only(left: Gap.lg, right: Gap.lg, bottom: Gap.lg),
    itemCount: 240,
    itemBuilder: (context, i) => Text(
      '${i + 1}'.padLeft(4) +
          (i % 7 == 3
              ? '  final transport = await _factory.connect(profile, onHostKey: _verifyHostKey, keepAlive: true);'
              : '  // line ${i + 1}'),
      style: Mono.input.copyWith(color: context.ds.text),
    ),
  ),
);

Widget _tallForm(BuildContext context) => SheetScaffold(
  title: 'Message agents',
  kind: SheetKind.form,
  actions: [
    AppButton(label: 'Message 14 agents', expand: true, onPressed: () {}),
    AppButton(label: 'Cancel', kind: AppButtonKind.secondary, expand: true, onPressed: () {}),
  ],
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < 30; i++)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
          child: Text('Agent ${i + 1} · herdr-mobile/feature-${i * 13}', style: Type.cell),
        ),
    ],
  ),
);

Widget _confirm(BuildContext context) => SheetScaffold(
  title: 'Close agents',
  kind: SheetKind.message,
  actions: [
    AppButton(label: 'Close 3 agents', kind: AppButtonKind.danger, expand: true, onPressed: () {}),
    AppButton(label: 'Cancel', kind: AppButtonKind.secondary, expand: true, onPressed: () {}),
  ],
  child: Text(
    'This closes these terminal panes and ends these agent sessions. Whatever runs in them stops, and it can’t be undone.',
    style: Type.compact.copyWith(color: context.ds.textSecondary),
  ),
);

Widget _rename(BuildContext context) =>
    const SheetScaffold(title: 'Rename workspace', kind: SheetKind.form, child: TextField(autofocus: true));

Widget _opener(WidgetBuilder sheet) => Builder(
  builder: (context) => ColoredBox(
    color: context.ds.bg,
    child: Center(
      child: GestureDetector(
        onTap: () => showAppSheet<void>(context, builder: sheet),
        child: Text('open', style: Type.cell.copyWith(color: context.ds.text)),
      ),
    ),
  ),
);

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester) => tester.getRect(find.byType(SheetSurface)).top;

void main() {
  if (Platform.environment['SHEET_SHOTS'] == null) {
    test('sheet shots are off (set SHEET_SHOTS=1)', () {}, skip: 'set SHEET_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['SHEET_SHOTS_DIR'] ?? '/tmp/sheet_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  final cases = <String, (WidgetBuilder, Future<void> Function(WidgetTester))>{
    'file_half': (_file, _openSheet),
    'file_full': (
      _file,
      (tester) async {
        await _openSheet(tester);
        await tester.timedDragFrom(Offset(200, _top(tester) + 120), const Offset(0, -600), const Duration(seconds: 1));
        await tester.pumpAndSettle();
      },
    ),
    'file_stretched': (
      _file,
      (tester) async {
        await _openSheet(tester);
        await tester.timedDragFrom(Offset(200, _top(tester) + 10), const Offset(0, -500), const Duration(seconds: 1));
        await tester.pumpAndSettle();
        final g = await tester.startGesture(Offset(200, _top(tester) + 10));
        for (var i = 0; i < 12; i++) {
          await g.moveBy(const Offset(0, -25));
          await tester.pump(const Duration(milliseconds: 16));
        }
        addTearDown(g.up);
      },
    ),
    'file_pulled_down': (
      _file,
      (tester) async {
        await _openSheet(tester);
        final g = await tester.startGesture(Offset(200, _top(tester) + 10));
        for (var i = 0; i < 10; i++) {
          await g.moveBy(const Offset(0, 20));
          await tester.pump(const Duration(milliseconds: 16));
        }
        addTearDown(g.up);
      },
    ),
    'tall_form_half': (_tallForm, _openSheet),
    'confirm': (_confirm, _openSheet),
    'rename_keyboard': (
      _rename,
      (tester) async {
        await _openSheet(tester);
        tester.view.viewInsets = FakeViewPadding(bottom: 300 * phoneDpr);
        await tester.pumpAndSettle();
      },
    ),
  };

  for (final MapEntry(key: name, value: (sheet, act)) in cases.entries) {
    for (final brightness in Brightness.values) {
      for (final (label, size) in [('412', phone), ('320', const Size(320, 640))]) {
        for (final scale in [1.0, 1.6]) {
          final file = '$out/${name}_${brightness.name}_${label}_x$scale.png';
          testWidgets(file, (tester) async {
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
            addTearDown(tester.view.resetViewInsets);
            await shoot(tester, _opener(sheet), file, brightness: brightness, size: size, pump: act);
          });
        }
      }
    }
  }
}
