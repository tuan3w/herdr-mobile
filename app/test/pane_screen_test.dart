import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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

  /// Fails every `pane.send_input` with this while set.
  Object? sendFailure;

  /// Fails every `pane.read` with this while set.
  Object? readFailure;

  /// `source` of every `pane.read`.
  List<String> get sources => [
        for (final (method, params) in calls)
          if (method == 'pane.read') params['source']! as String,
      ];

  /// What was typed or pressed in the pane: `line:<text>`, `keys:<combo>`.
  List<String> get sent => [
        for (final (method, params) in calls)
          if (method == 'pane.send_input')
            'line:${params['text']}'
          else if (method == 'pane.send_keys')
            'keys:${(params['keys']! as List).join('+')}',
      ];

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (method == 'pane.send_input' && sendFailure != null) {
      calls.add((method, params));
      return Future.error(sendFailure!);
    }
    if (method != 'pane.read') return super.request(method, params);
    calls.add((method, params));
    if (readFailure != null) return Future.error(readFailure!);
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

  MachineConnection newMachine(String label) => MachineConnection(
        profile: MachineProfile(id: 'm', label: label, host: 'h', username: 'u'),
        api: HerdrApi(transport),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      );

  setUp(() {
    transport = _PaneTransport();
    machine = newMachine('box');
    store = MemoryTerminalSettingsStore();
    settings = TerminalSettings(store);
  });

  Future<void> pumpPane(WidgetTester tester, {Widget? home}) async {
    machine.start();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: home ?? PaneScreen(machine: machine, paneId: _pane),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    machine.dispose();
  }

  /// The machine's event stream fails and it falls back to reconnecting.
  Future<void> goOffline(WidgetTester tester) async {
    const failure = HerdrTransportException('network down');
    transport.failure = failure;
    transport.dropEvents(failure);
    await tester.runAsync(() => eventually(
          () => machine.state == LinkState.reconnecting,
          reason: 'reconnecting',
        ));
    await _settle(tester);
  }

  Finder send() => find.bySemanticsLabel('Send');
  Finder composer() => find.byType(TextField);

  testWidgets('shows the terminal rows by default', (tester) async {
    await pumpPane(tester);

    expect(transport.sources, ['recent']);
    expect(find.text('rows as the terminal has them'), findsOneWidget);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).wrap, isFalse);
    expect(find.byTooltip('Wrap lines to screen'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('names the pane, where it lives and what it is doing',
      (tester) async {
    await pumpPane(tester);

    expect(find.text('claude'), findsOneWidget);
    expect(find.text('Working · box'), findsOneWidget);
    expect(find.text(' · $_pane'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('a very long machine label gives way instead of overflowing',
      (tester) async {
    machine.dispose();
    machine = newMachine(
      'bartholomew.fitzgerald@northwind-industries-holdings.example.com',
    );
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await pumpPane(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(' · $_pane'), findsOneWidget, reason: 'the id is never cut');
    await teardown(tester);
  });

  testWidgets('the back button leaves the pane', (tester) async {
    machine.start();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: Builder(
            builder: (context) => GestureDetector(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => PaneScreen(machine: machine, paneId: _pane),
              )),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.byType(PaneScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await _settle(tester);

    expect(find.byType(PaneScreen), findsNothing);
    await teardown(tester);
  });

  testWidgets('the wrap button switches to unwrapped lines and back, and '
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

  group('composer', () {
    testWidgets('sends the text as a line and clears the field', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.enterText(composer(), 'ls -la');
      await tester.pump();
      await tester.tap(send());
      await _settle(tester);

      expect(transport.sent, ['line:ls -la']);
      expect(tester.widget<TextField>(composer()).controller!.text, isEmpty);
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('the send button does nothing while empty or only spaces',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.tap(send());
      await tester.pump();
      await tester.enterText(composer(), '   ');
      await tester.pump();
      await tester.tap(send());
      await _settle(tester);

      expect(transport.sent, isEmpty);
      expect(tester.widget<TextField>(composer()).controller!.text, '   ',
          reason: 'what was typed stays put');
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets("the keyboard's send key on an empty field presses enter",
        (tester) async {
      await pumpPane(tester);

      await tester.showKeyboard(composer());
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _settle(tester);

      expect(transport.sent, ['keys:enter']);
      await teardown(tester);
    });

    testWidgets('spaces alone are never typed into the pane', (tester) async {
      await pumpPane(tester);

      await tester.enterText(composer(), '  ');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _settle(tester);

      expect(transport.sent, ['keys:enter']);
      await teardown(tester);
    });

    testWidgets('keeps what was typed when sending fails', (tester) async {
      final semantics = tester.ensureSemantics();
      transport.sendFailure = const HerdrTransportException('write failed');
      await pumpPane(tester);

      await tester.enterText(composer(), 'important command');
      await tester.pump();
      await tester.tap(send());
      await _settle(tester);

      expect(tester.widget<TextField>(composer()).controller!.text,
          'important command');
      expect(find.text('write failed'), findsOneWidget);
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('grows with its text and stops at five lines', (tester) async {
      await pumpPane(tester);
      double height() => tester.getSize(composer()).height;

      final one = height();
      await tester.enterText(composer(), 'a\nb\nc');
      await tester.pump();
      final three = height();
      await tester.enterText(composer(), List.filled(5, 'x').join('\n'));
      await tester.pump();
      final five = height();
      await tester.enterText(composer(), List.filled(12, 'x').join('\n'));
      await tester.pump();

      expect(three, greaterThan(one));
      expect(five, greaterThan(three));
      expect(height(), five, reason: 'capped at five lines');
      await teardown(tester);
    });

    testWidgets('says why it cannot be used while offline', (tester) async {
      await pumpPane(tester);
      expect(find.text('Message claude…'), findsOneWidget);

      await goOffline(tester);

      expect(find.text('Offline — reconnecting'), findsOneWidget);
      expect(tester.widget<TextField>(composer()).enabled, isFalse);
      await teardown(tester);
    });
  });

  group('quick keys', () {
    testWidgets('press the keys they are labelled with', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.tap(find.text('esc'));
      await tester.tap(find.text('ctrl+c'));
      await tester.tap(find.bySemanticsLabel('Up'));
      await tester.tap(find.byIcon(LucideIcons.cornerDownLeft));
      await tester.pump();

      expect(transport.sent, ['keys:esc', 'keys:ctrl+c', 'keys:up', 'keys:enter']);
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('are inert while the machine is not live', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);
      await goOffline(tester);

      await tester.tap(find.text('esc'));
      await tester.tap(find.bySemanticsLabel('Down'));
      await tester.pump();

      expect(transport.sent, isEmpty);
      semantics.dispose();
      await teardown(tester);
    });
  });

  group('when the machine is not live', () {
    testWidgets('says so, and Retry reads the pane again', (tester) async {
      await pumpPane(tester);
      await goOffline(tester);

      expect(find.text('network down'), findsOneWidget);
      final reads = transport.sources.length;

      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(transport.sources.length, greaterThan(reads));
      await teardown(tester);
    });

    testWidgets('a read failure is shown and goes away once it succeeds',
        (tester) async {
      await pumpPane(tester);
      expect(find.text('Retry'), findsNothing);

      transport.readFailure = const HerdrTransportException('read failed');
      transport.emit({
        'event': 'pane_updated',
        'data': {'pane': {'pane_id': _pane}},
      });
      await _settle(tester);
      expect(find.text('read failed'), findsOneWidget);

      transport.readFailure = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(find.text('read failed'), findsNothing);
      await teardown(tester);
    });
  });
}
