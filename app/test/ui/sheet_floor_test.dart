// Every sheet has the same floor ([SheetFrame.minHeight]): none opens as a
// sliver, and what arrives after a sheet opened (a list's rows) does not move
// its top edge under the thumb while it still fits the floor.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

Widget _app(WidgetBuilder sheet) => MaterialApp(
  theme: AppTheme.light(),
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: GestureDetector(
          onTap: () => showAppSheet<void>(context, builder: sheet),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester, WidgetBuilder sheet, {Size size = const Size(412, 892)}) async {
  tester.view
    ..physicalSize = size * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(sheet));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Rect _sheet(WidgetTester tester) => tester.getRect(find.byType(SheetSurface));

Widget _confirm(BuildContext context) => SheetScaffold(
  title: 'Close agent',
  kind: SheetKind.message,
  actions: [
    AppButton(label: 'Close 1 agent', kind: AppButtonKind.danger, expand: true, onPressed: () {}),
    AppButton(label: 'Cancel', kind: AppButtonKind.secondary, expand: true, onPressed: () {}),
  ],
  child: const Text('This ends the session.'),
);

Widget _two(BuildContext context) => SheetScaffold(
  title: 'Options',
  kind: SheetKind.actions,
  child: Column(
    children: [
      for (final t in ['Rename', 'Duplicate']) PressRow(onTap: () {}, child: Text(t)),
    ],
  ),
);

/// A list sheet whose body is a note until [rows] says there are rows.
class _Arriving extends StatefulWidget {
  const _Arriving(this.rows);

  final ValueNotifier<int> rows;

  @override
  State<_Arriving> createState() => _ArrivingState();
}

class _ArrivingState extends State<_Arriving> {
  @override
  Widget build(BuildContext context) => SheetScaffold(
    title: 'Ports',
    kind: SheetKind.list,
    child: ValueListenableBuilder<int>(
      valueListenable: widget.rows,
      builder: (context, n, _) => n == 0
          ? const Padding(padding: EdgeInsets.all(Gap.lg), child: Text('Looking for open ports…'))
          : Column(
              children: [for (var i = 0; i < n; i++) PressRow(onTap: () {}, child: Text('Port ${3000 + i}'))],
            ),
    ),
  );
}

void main() {
  testWidgets('a short confirmation opens at the floor, not as a sliver', (tester) async {
    await _open(tester, _confirm);
    expect(_sheet(tester).height, SheetFrame.minHeight);
  });

  testWidgets('two rows of actions open at the same floor', (tester) async {
    await _open(tester, _two);
    expect(_sheet(tester).height, SheetFrame.minHeight);
  });

  testWidgets('rows arriving in a sheet that fits the floor do not move its top edge', (tester) async {
    final rows = ValueNotifier(0);
    addTearDown(rows.dispose);
    await _open(tester, (_) => _Arriving(rows));
    final top = _sheet(tester).top;

    rows.value = 3;
    await tester.pump();
    expect(_sheet(tester).top, top, reason: 'the ports arrived under the person\'s thumb: nothing moved');
  });

  testWidgets('on a short screen the floor gives way to the room there is', (tester) async {
    await _open(tester, _confirm, size: const Size(892, 300));
    expect(tester.takeException(), isNull);
    expect(_sheet(tester).height, lessThanOrEqualTo(300));
  });
}
