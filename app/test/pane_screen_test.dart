import 'dart:async';

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

  /// While set, `pane.send_input` waits for it before succeeding.
  Completer<void>? sendGate;

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
    if (method == 'pane.send_input' && sendGate != null) {
      calls.add((method, params));
      return sendGate!.future.then((_) => {'type': 'ok'});
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

  /// The strip's message is rich text (title, then quieter detail).
  Finder banner(String text) => find.textContaining(text, findRichText: true);
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

  testWidgets('names the pane by its task, with the agent and where it lives',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPane(tester);

    // The fake snapshot gives every pane the title "title <id>".
    expect(find.text('title $_pane'), findsOneWidget);
    expect(find.text('claude · box'), findsOneWidget);
    expect(find.text(' · $_pane'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('title $_pane')),
      matchesSemantics(label: 'title $_pane', isHeader: true),
    );
    expect(find.bySemanticsLabel('Working'), findsOneWidget,
        reason: 'the status is named once, by the glyph');
    semantics.dispose();
    await teardown(tester);
  });

  testWidgets('a pane without a task title is named by its agent',
      (tester) async {
    final panes = transport.snapshot['panes']! as List;
    (panes.single as Map<String, dynamic>)['terminal_title_stripped'] = '';

    await pumpPane(tester);

    expect(find.text('claude'), findsOneWidget);
    expect(find.text('box'), findsOneWidget,
        reason: 'the agent is not repeated on the subtitle line');
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
      expect(banner('write failed'), findsOneWidget);
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

      expect(banner('network down'), findsOneWidget);
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
      expect(banner('read failed'), findsOneWidget);

      transport.readFailure = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(banner('read failed'), findsNothing);
      await teardown(tester);
    });
  });

  group('the keyboard send key', () {
    testWidgets('sends and keeps the keyboard open', (tester) async {
      await pumpPane(tester);

      await tester.showKeyboard(composer());
      await tester.enterText(composer(), 'ls');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await _settle(tester);

      expect(transport.sent, ['line:ls']);
      expect(tester.state<EditableTextState>(find.byType(EditableText)).widget.focusNode.hasFocus,
          isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await teardown(tester);
    });

    testWidgets('does not send twice while a send is in flight', (tester) async {
      transport.sendGate = Completer<void>();
      await pumpPane(tester);

      await tester.showKeyboard(composer());
      await tester.enterText(composer(), 'ls');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();

      expect(transport.sent, ['line:ls']);
      transport.sendGate!.complete();
      await _settle(tester);
      await teardown(tester);
    });

    testWidgets('leaving the pane mid-send does not touch the composer',
        (tester) async {
      transport.sendGate = Completer<void>();
      await pumpPane(tester);

      await tester.enterText(composer(), 'ls');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      transport.sendGate!.complete();
      await _settle(tester);

      expect(tester.takeException(), isNull);
      machine.dispose();
    });
  });

  group('when the pane is closed', () {
    Future<void> closePane(WidgetTester tester) async {
      (transport.snapshot['panes']! as List).clear();
      await tester.runAsync(machine.refresh);
      await _settle(tester);
    }

    testWidgets('says so, disables the composer and the keys, and keeps its name',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);
      expect(banner('This pane was closed'), findsNothing);

      await closePane(tester);

      expect(banner('This pane was closed'), findsOneWidget);
      expect(find.text('Pane closed'), findsOneWidget);
      expect(tester.widget<TextField>(composer()).enabled, isFalse);
      expect(find.text('title $_pane'), findsOneWidget,
          reason: 'still says which task this was');
      expect(find.text('Retry'), findsNothing, reason: 'there is nothing to retry');

      await tester.tap(find.text('esc'));
      await tester.tap(find.bySemanticsLabel('Enter'));
      await tester.pump();
      expect(transport.sent, isEmpty);
      semantics.dispose();
      await teardown(tester);
    });
  });

  group('the banner', () {
    testWidgets('closes with its content instead of emptying first',
        (tester) async {
      await pumpPane(tester);
      await goOffline(tester);
      expect(banner('network down'), findsOneWidget);

      transport.failure = null;
      machine.retry();
      await tester.runAsync(() => eventually(() => machine.isLive, reason: 'online'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      expect(banner('network down'), findsOneWidget,
          reason: 'mid-animation the message is still there, fading with the strip');
      await _settle(tester);
      expect(banner('network down'), findsNothing);
      await teardown(tester);
    });
  });

  group('layout', () {
    testWidgets('the five most used keys are on screen at 412dp', (tester) async {
      tester.view.physicalSize = const Size(412, 892);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpPane(tester);

      Rect rectOf(Finder f) => tester.getRect(f);
      Finder key(IconData icon) =>
          find.descendant(of: find.byType(ListView), matching: find.byIcon(icon));
      expect(rectOf(find.text('esc')).right, lessThan(412));
      expect(rectOf(key(LucideIcons.arrowUp)).right, lessThan(412));
      expect(rectOf(key(LucideIcons.arrowDown)).right, lessThan(412));
      expect(rectOf(key(LucideIcons.cornerDownLeft)).right, lessThan(412));
      expect(rectOf(find.text('tab')).right, lessThan(412));
      await teardown(tester);
    });

    testWidgets('the send button and the keys have 44dp touch targets',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      expect(tester.getSize(find.bySemanticsLabel('Send')).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.bySemanticsLabel('Up')).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.bySemanticsLabel('esc')).height, greaterThanOrEqualTo(44));
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('quick keys are each read once', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      expect(find.bySemanticsLabel('esc'), findsOneWidget);
      expect(find.bySemanticsLabel('Up'), findsOneWidget);
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('landscape with the keyboard up keeps six lines of terminal and '
        'folds the keys behind a toggle', (tester) async {
      tester.view.physicalSize = const Size(740, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.reset);
      await pumpPane(tester);

      expect(find.byTooltip('Back'), findsNothing);
      expect(find.text('esc'), findsNothing);
      // Six rows of the terminal at its default size (about 14dp each) plus
      // its own 16dp of padding.
      expect(tester.getSize(find.byType(TerminalView)).height, greaterThanOrEqualTo(100));

      await tester.tap(find.byTooltip('Show keys'));
      await tester.pump();
      expect(find.text('esc'), findsOneWidget);

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pump();
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.byTooltip('Show keys'), findsNothing);
      await teardown(tester);
    });
  });

  group('rebuild scope', () {
    testWidgets('a notify about another pane rebuilds none of this pane',
        (tester) async {
      List<({String id, String ws, String? agent, String status})> panes(String other) => [
            (id: _pane, ws: 'w1', agent: 'claude', status: 'working'),
            (id: 'w1:p2', ws: 'w1', agent: 'omp', status: other),
          ];
      transport.snapshot = snapshotJson(panes: panes('idle'));
      await pumpPane(tester);

      final rebuilt = <String>[];
      debugOnRebuildDirtyWidget = (element, builtOnce) =>
          rebuilt.add(element.widget.runtimeType.toString());
      addTearDown(() => debugOnRebuildDirtyWidget = null);

      var notified = 0;
      void count() => notified++;
      machine.addListener(count);
      transport.snapshot = snapshotJson(panes: panes('blocked'));
      await tester.runAsync(machine.refresh);
      await tester.pump();
      machine.removeListener(count);

      expect(notified, greaterThan(0), reason: 'the machine did notify');
      expect(
        rebuilt.where({'_TopBar', '_Banner', '_QuickKeys', '_Composer', '_TerminalPanel', '_PaneView'}.contains),
        isEmpty,
      );

      // The hook sees rebuilds at all, and this pane's own change reaches
      // only the part that shows it.
      transport.snapshot = snapshotJson(panes: [
        (id: _pane, ws: 'w1', agent: 'claude', status: 'idle'),
        (id: 'w1:p2', ws: 'w1', agent: 'omp', status: 'blocked'),
      ]);
      await tester.runAsync(machine.refresh);
      await tester.pump();
      expect(rebuilt, contains('_TopBar'));
      expect(rebuilt.where({'_QuickKeys', '_Composer', '_Banner'}.contains), isEmpty);
      await teardown(tester);
    });
  });
}
