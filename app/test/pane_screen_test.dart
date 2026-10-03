import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:provider/provider.dart';

import 'support/fake_transport.dart';
import 'support/memory_terminal_settings_store.dart';

const _pane = 'w1:p1';

/// Answers `pane.read` with text that depends on the requested source.
class _PaneTransport extends FakeTransport {
  _PaneTransport()
      : super(snapshotJson(
          panes: [(id: _pane, ws: 'w1', agent: 'claude', status: 'working')],
        ));

  /// `source` of every `pane.read`.
  List<String> get sources => [
        for (final (method, params) in calls)
          if (method == 'pane.read') params['source']! as String,
      ];

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (method != 'pane.read') return super.request(method, params);
    calls.add((method, params));
    final text = params['source'] == 'recent_unwrapped'
        ? 'joined line from herdr'
        : 'rows as the terminal has them';
    return Future.value({
      'type': 'pane_read',
      'read': {'text': text, 'truncated': false},
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  late _PaneTransport transport;
  late MachineConnection machine;
  late MemoryTerminalSettingsStore store;
  late TerminalSettings settings;

  setUp(() {
    transport = _PaneTransport();
    machine = MachineConnection(
      profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
      api: HerdrApi(transport),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
    );
    store = MemoryTerminalSettingsStore();
    settings = TerminalSettings(store);
  });

  Future<void> pumpPane(WidgetTester tester) async {
    machine.start();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: PaneScreen(machine: machine, paneId: _pane),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    machine.dispose();
  }

  testWidgets('shows the terminal rows by default', (tester) async {
    await pumpPane(tester);

    expect(transport.sources, ['recent']);
    expect(find.text('rows as the terminal has them'), findsOneWidget);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).wrap, isFalse);
    expect(find.byTooltip('Wrap lines to screen'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the app bar button switches to unwrapped lines and back, and '
      'remembers', (tester) async {
    await pumpPane(tester);

    await tester.tap(find.byTooltip('Wrap lines to screen'));
    await _settle(tester);

    expect(transport.sources, ['recent', 'recent_unwrapped']);
    expect(find.text('joined line from herdr'), findsOneWidget);
    expect(find.text('rows as the terminal has them'), findsNothing);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).wrap, isTrue);
    expect(find.byTooltip('Show exact terminal layout'), findsOneWidget);
    expect(settings.wrap, isTrue);
    expect(store.wrap, isTrue);

    await tester.tap(find.byTooltip('Show exact terminal layout'));
    await _settle(tester);

    expect(transport.sources.last, 'recent');
    expect(find.text('rows as the terminal has them'), findsOneWidget);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).wrap, isFalse);
    expect(store.wrap, isFalse);
    await teardown(tester);
  });

  testWidgets('opens in wrap mode when it was left on', (tester) async {
    store.wrap = true;
    await settings.load();

    await pumpPane(tester);

    expect(transport.sources.first, 'recent_unwrapped');
    expect(find.text('joined line from herdr'), findsOneWidget);
    expect(find.byTooltip('Show exact terminal layout'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('pinching sets the font size, and saves it when the fingers lift',
      (tester) async {
    await pumpPane(tester);
    final center = tester.getCenter(find.byType(TerminalView));

    final a = await tester.startGesture(center - const Offset(50, 0), pointer: 1);
    final b = await tester.startGesture(center + const Offset(50, 0), pointer: 2);
    await tester.pump();
    await a.moveTo(center - const Offset(75, 0));
    await b.moveTo(center + const Offset(75, 0)); // 100 -> 150 apart
    await tester.pump();

    expect(settings.fontSize, closeTo(defaultTerminalFontSize * 1.5, 0.3));
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).fontSize,
        settings.fontSize);
    expect(store.fontSize, isNull, reason: 'not saved mid-pinch');

    await a.up();
    await b.up();
    await tester.pump();

    expect(store.fontSize, settings.fontSize);
    await teardown(tester);
  });

  testWidgets('opens at the saved font size', (tester) async {
    store.fontSize = 16;
    await settings.load();

    await pumpPane(tester);

    expect(tester.widget<TerminalView>(find.byType(TerminalView)).fontSize, 16);
    await teardown(tester);
  });
}
