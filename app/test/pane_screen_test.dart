import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/terminal_cells.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_bar.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/features/pane/quick_keys.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import 'support/fake_fs.dart';
import 'support/fake_network.dart';
import 'support/fake_transport.dart';
import 'support/memory_quick_phrases_store.dart';
import 'support/memory_stores.dart';
import 'support/memory_terminal_settings_store.dart';
import 'support/terminal_rows.dart';

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

  /// What every `pane.read` answers, when set.
  String? readText;

  /// Answers `pane.read` from its parameters, as (text, truncated), when set.
  (String, bool) Function(Map<String, dynamic> params)? readFor;

  /// `lines` of every `pane.read`.
  List<int> get lines => [
        for (final (method, params) in calls)
          if (method == 'pane.read') params['lines']! as int,
      ];

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
    final custom = readFor?.call(params);
    final text = custom?.$1 ??
        readText ??
        (params['source'] == 'recent_unwrapped'
            ? 'joined line from herdr'
            : 'rows as the terminal has them');
    return Future.value({
      'type': 'pane_read',
      'read': {'text': text, 'truncated': custom?.$2 ?? false},
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
  late QuickPhrases phrases;

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
    phrases = QuickPhrases(MemoryQuickPhrasesStore());
  });

  late FleetRepository fleet;
  late AgentScreens screens;
  late PanePreviews previews;

  PaneAgent agent() => PaneAgent(machine.profile.id, _pane);

  /// The pane screen as the app opens it: [machine] in a fleet, its pane's
  /// screen in front. [home] replaces the screen (to test opening it).
  Future<void> pumpPane(WidgetTester tester, {Widget? home}) async {
    final repo = MachineRepository(
      profiles: MemoryProfileStore(),
      secrets: MemorySecretStore(),
    );
    await repo.load();
    fleet = FleetRepository(
      machines: repo,
      network: FakeNetwork(),
      connect: (profile, secrets) => machine,
    );
    await repo.save(machine.profile, secrets: const MachineSecrets(password: 'x'));
    await fleet.settled();
    screens = AgentScreens();
    previews = PanePreviews(changes: fleet, connection: fleet.connection);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider.value(value: phrases),
          ChangeNotifierProvider.value(value: fleet),
          ChangeNotifierProvider.value(value: screens),
          Provider<PanePreviews>.value(value: previews),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: home ?? PaneScreen(agent: agent()),
        ),
      ),
    );
    await _settle(tester);
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    previews.dispose();
    screens.dispose();
    fleet.dispose();
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

  /// Text in the top bar.
  Finder inBar(String text) =>
      find.descendant(of: find.byType(PaneTopBar), matching: find.text(text));

  /// The strip's message is rich text (title, then quieter detail).
  Finder banner(String text) => find.textContaining(text, findRichText: true);
  Finder send() => find.bySemanticsLabel('Send');
  Finder composer() => find.byType(TextField);

  testWidgets('shows the terminal rows by default', (tester) async {
    await pumpPane(tester);

    expect(transport.sources, ['recent']);
    expect(terminalRow('rows as the terminal has them'), findsOneWidget);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).wrap, isFalse);
    expect(find.byTooltip('Wrap lines to screen'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('names the pane by its task, with the agent and where it lives, '
      'and shows no raw pane id', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPane(tester);

    // The fake snapshot gives every pane the title "title <id>".
    expect(inBar('title $_pane'), findsOneWidget);
    expect(inBar('claude · box'), findsOneWidget);
    for (final raw in [' · $_pane', _pane]) {
      expect(
        find.descendant(of: find.byType(PaneTopBar), matching: find.text(raw)),
        findsNothing,
        reason: 'the id is for the actions sheet, not the header',
      );
    }
    // The glyph, the title and the second line are one node: a header that
    // reads status, task and place once.
    final node = tester.getSemantics(inBar('title $_pane'));
    expect(node.label, contains('title $_pane'));
    expect(node.label, contains('Working'));
    expect(node.label, contains('claude · box'));
    expect(node, isSemantics(isHeader: true));
    semantics.dispose();
    await teardown(tester);
  });

  testWidgets('a pane without a task title is named by its agent',
      (tester) async {
    final panes = transport.snapshot['panes']! as List;
    (panes.single as Map<String, dynamic>)['terminal_title_stripped'] = '';

    await pumpPane(tester);

    expect(inBar('claude'), findsOneWidget);
    expect(inBar('box'), findsOneWidget,
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
    expect(inBar('title $_pane'), findsOneWidget);
    expect(find.byTooltip('Wrap lines to screen'), findsOneWidget,
        reason: 'the buttons keep their room');
    await teardown(tester);
  });

  testWidgets('the back button leaves the pane', (tester) async {
    await pumpPane(
      tester,
      home: Builder(
        builder: (context) => GestureDetector(
          onTap: () => openAgent(context, agent(), view: AgentView.terminal),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _settle(tester);
    expect(find.byType(PaneScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await _settle(tester);

    expect(find.byType(PaneScreen), findsNothing);
    expect(find.text('open'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('the wrap button switches to unwrapped lines and back, and '
      'remembers', (tester) async {
    await pumpPane(tester);

    await tester.tap(find.byTooltip('Wrap lines to screen'));
    await _settle(tester);

    expect(transport.sources, ['recent', 'recent_unwrapped']);
    expect(terminalRow('joined line from herdr'), findsOneWidget);
    expect(terminalRow('rows as the terminal has them'), findsNothing);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).wrap, isTrue);
    expect(find.byTooltip('Show exact terminal layout'), findsOneWidget);
    expect(settings.wrap, isTrue);
    expect(store.wrap, isTrue);

    await tester.tap(find.byTooltip('Show exact terminal layout'));
    await _settle(tester);

    expect(transport.sources.last, 'recent');
    expect(terminalRow('rows as the terminal has them'), findsOneWidget);
    expect(tester.widget<TerminalView>(find.byType(TerminalView)).wrap, isFalse);
    expect(store.wrap, isFalse);
    await teardown(tester);
  });

  testWidgets('opens in wrap mode when it was left on', (tester) async {
    store.wrap = true;
    await settings.load();

    await pumpPane(tester);

    expect(transport.sources.first, 'recent_unwrapped');
    expect(terminalRow('joined line from herdr'), findsOneWidget);
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

    testWidgets('asks for the keyboard when the finger lands, not when it lifts',
        (tester) async {
      await pumpPane(tester);
      final focus = tester.widget<TextField>(composer()).focusNode!;
      expect(focus.hasFocus, isFalse);

      final finger = await tester.startGesture(tester.getCenter(composer()));
      await tester.pump();

      // The keyboard app needs a few hundred ms to start moving: every ms the
      // request waits for the finger to lift is added to that.
      expect(focus.hasFocus, isTrue);
      await finger.up();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
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

  group('slash palette', () {
    testWidgets('a slash lists the agent commands, and a tap fills the composer', (tester) async {
      await pumpPane(tester);

      await tester.enterText(composer(), '/co');
      await tester.pump();
      await tester.pump();

      expect(find.text('/compact'), findsOneWidget);
      expect(find.text('/context'), findsOneWidget);
      expect(find.text('/exit'), findsNothing, reason: 'does not match "co"');

      await tester.tap(find.text('/compact'));
      await tester.pump();

      final field = tester.widget<TextField>(composer()).controller!;
      expect(field.text, '/compact ');
      expect(field.selection, const TextSelection.collapsed(offset: 9));
      expect(find.text('/context'), findsNothing, reason: 'chosen: the palette goes');
      expect(transport.sent, isEmpty, reason: 'filling is not sending');
      await teardown(tester);
    });

    testWidgets('plain text and a slash after the first word show nothing', (tester) async {
      await pumpPane(tester);

      await tester.enterText(composer(), 'hello');
      await tester.pump();
      await tester.pump();
      expect(find.text('/compact'), findsNothing);

      await tester.enterText(composer(), 'explain /co');
      await tester.pump();
      expect(find.text('/compact'), findsNothing);
      await teardown(tester);
    });

    testWidgets('the slash key brings the palette up', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.scrollUntilVisible(
        find.text('/'),
        100,
        scrollable: find.descendant(of: find.byType(QuickKeys), matching: find.byType(Scrollable)),
      );
      await tester.tap(find.text('/'));
      await tester.pump();
      await tester.pump();

      expect(find.text('/compact'), findsOneWidget);
      semantics.dispose();
      await teardown(tester);
    });
  });

  group('quick phrases', () {
    Finder chip(String phrase) => find.widgetWithText(AppChip, phrase);

    testWidgets('a tap fills the empty composer and sends nothing', (tester) async {
      await pumpPane(tester);
      expect(chip('continue'), findsNothing, reason: 'not before the composer is focused');

      await tester.showKeyboard(composer());
      await tester.pump();
      await tester.tap(chip('run the tests'));
      await tester.pump();

      final field = tester.widget<TextField>(composer());
      expect(field.controller!.text, 'run the tests');
      expect(field.controller!.selection, const TextSelection.collapsed(offset: 13));
      expect(field.focusNode!.hasFocus, isTrue);
      expect(transport.sent, isEmpty);
      expect(chip('continue'), findsNothing, reason: 'there is a draft now');
      await teardown(tester);
    });

    testWidgets('the row waits for an empty composer', (tester) async {
      await pumpPane(tester);
      await tester.showKeyboard(composer());
      await tester.enterText(composer(), 'ls');
      await tester.pump();
      expect(chip('continue'), findsNothing);

      await tester.enterText(composer(), '');
      await tester.pump();
      expect(chip('continue'), findsOneWidget);
      await teardown(tester);
    });

    testWidgets('left out in landscape with the keyboard up', (tester) async {
      tester.view.physicalSize = const Size(740, 360);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 200);
      addTearDown(tester.view.reset);
      await pumpPane(tester);

      await tester.showKeyboard(composer());
      await tester.pump();
      expect(chip('continue'), findsNothing);
      await teardown(tester);
    });
  });

  group('quick keys', () {
    testWidgets('press the keys they are labelled with', (tester) async {
      // Wide enough for the whole row: the keys past the first six scroll.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.tap(find.text('esc'));
      await tester.tap(find.bySemanticsLabel('Up'));
      await tester.tap(find.byIcon(LucideIcons.cornerDownLeft));
      await tester.tap(find.bySemanticsLabel('Space'));
      await tester.tap(find.text('ctrl+c'));
      await tester.pump();

      expect(
        transport.sent,
        ['keys:esc', 'keys:up', 'keys:enter', 'keys:space', 'keys:ctrl+c'],
      );
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('Ctrl armed, the next typed letter is that chord, once', (tester) async {
      await pumpPane(tester);

      await tester.tap(find.text('ctrl'));
      await tester.pump();
      await tester.enterText(composer(), 'r');
      await tester.pump();

      expect(transport.sent, ['keys:ctrl+r']);
      expect(tester.widget<TextField>(composer()).controller!.text, isEmpty,
          reason: 'the letter is a key, not text');

      await tester.enterText(composer(), 'x');
      await tester.pump();
      expect(transport.sent, ['keys:ctrl+r'], reason: 'the latch is spent');
      expect(tester.widget<TextField>(composer()).controller!.text, 'x');
      await teardown(tester);
    });

    testWidgets('Ctrl and Alt armed together prefix a tapped key', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.tap(find.text('ctrl'));
      await tester.tap(find.text('alt'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Left'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Left'));
      await tester.pump();

      expect(transport.sent, ['keys:ctrl+alt+left', 'keys:left']);
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('a key that is already a combo ignores the armed modifier but keeps it',
        (tester) async {
      await pumpPane(tester);

      await tester.tap(find.text('ctrl'));
      await tester.pump();
      // The key row scrolls: at 800dp this key is past the edge.
      await tester.ensureVisible(find.text('shift+tab'));
      await tester.pump();
      await tester.tap(find.text('shift+tab'));
      await tester.pump();
      await tester.enterText(composer(), 'o');
      await tester.pump();

      expect(transport.sent, ['keys:shift+tab', 'keys:ctrl+o']);
      await teardown(tester);
    });

    testWidgets('the new line key breaks the line in the composer and sends nothing',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.enterText(composer(), 'first');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('New line'));
      await tester.pump();

      expect(tester.widget<TextField>(composer()).controller!.text, 'first\n');
      expect(transport.sent, isEmpty);
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('a held arrow repeats and its release is not one more press',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      final hold = await tester.startGesture(tester.getCenter(find.bySemanticsLabel('Up')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(transport.sent, isEmpty, reason: 'not before the delay');
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final repeated = transport.sent.length;
      expect(repeated, greaterThanOrEqualTo(3));

      await hold.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(transport.sent.length, repeated);
      expect(transport.sent, everyElement('keys:up'));
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('a quick tap on an arrow presses it once', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await tester.tap(find.bySemanticsLabel('Up'));
      await tester.pump(const Duration(seconds: 1));

      expect(transport.sent, ['keys:up']);
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

  group('the live edge', () {
    // What the terminal is dimmed with while it is not live (or closed).
    final dim = find.byWidgetPredicate(
      (w) =>
          w is ColoredBox &&
          w.color == TerminalPalette.dark.background.withValues(alpha: 0.6),
    );
    final staleLabel = find.textContaining('stale · ');

    Future<void> failReads(WidgetTester tester) async {
      transport.readFailure = const HerdrTransportException('read failed');
      transport.emit({
        'event': 'pane_updated',
        'data': {'pane': {'pane_id': _pane}},
      });
      await _settle(tester);
    }

    testWidgets('a live pane is not dimmed and says nothing', (tester) async {
      await pumpPane(tester);

      expect(dim, findsNothing);
      expect(staleLabel, findsNothing);
      await teardown(tester);
    });

    testWidgets('a failed read dims the terminal and counts the time since '
        'the last good one, until a read works again', (tester) async {
      await pumpPane(tester);

      await failReads(tester);
      expect(dim, findsOneWidget);
      expect(staleLabel, findsOneWidget);
      expect(find.text('stale · 0s'), findsOneWidget);
      expect(terminalRow('rows as the terminal has them'), findsOneWidget,
          reason: 'the last text stays, dimmed');

      transport.readFailure = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);

      expect(dim, findsNothing);
      expect(staleLabel, findsNothing);
      await teardown(tester);
    });

    testWidgets('a link that is down dims it too', (tester) async {
      await pumpPane(tester);
      await goOffline(tester);

      expect(dim, findsOneWidget);
      expect(staleLabel, findsOneWidget);
      await teardown(tester);
    });

    testWidgets('a pane that was closed is dimmed once and is not "stale"',
        (tester) async {
      await pumpPane(tester);
      (transport.snapshot['panes']! as List).clear();
      await tester.runAsync(machine.refresh);
      await _settle(tester);

      expect(dim, findsOneWidget, reason: 'one layer, not two');
      expect(staleLabel, findsNothing);
      await teardown(tester);
    });
  });

  group('the jump pill', () {
    Future<void> scrollAway(WidgetTester tester) async {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
    }

    testWidgets('says "Needs you" when the agent asks while the reader is '
        'reading back, and a tap goes to the question', (tester) async {
      transport.readText = [for (var i = 0; i < 120; i++) 'line $i'].join('\n');
      await pumpPane(tester);
      await scrollAway(tester);
      expect(terminalRow('line 119'), findsNothing);
      expect(find.text('Needs you'), findsNothing);

      ((transport.snapshot['panes']! as List).single as Map<String, dynamic>)['agent_status'] =
          'blocked';
      await tester.runAsync(machine.refresh);
      await _settle(tester);

      expect(find.text('Needs you'), findsOneWidget);
      await tester.tap(find.text('Needs you'));
      await _settle(tester);
      expect(terminalRow('line 119'), findsOneWidget);
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
      previews.dispose();
      screens.dispose();
      fleet.dispose();
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
      expect(inBar('title $_pane'), findsOneWidget,
          reason: 'still says which task this was');
      expect(find.text('title $_pane'), findsOneWidget,
          reason: 'the bar is the only place that names it now');
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
    testWidgets('the prompt, space, new line and slash keys are on screen at 412dp', (tester) async {
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
      expect(rectOf(key(LucideIcons.space)).right, lessThan(412));
      expect(rectOf(key(LucideIcons.pilcrow)).right, lessThan(412));
      expect(rectOf(find.text('/')).right, lessThan(412));
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

  group('links, files and scrollback', () {
    const docs = 'https://example.com/docs/intro';

    /// Taps the cell of [needle]'s row where [column] of the row is.
    Future<void> tapText(WidgetTester tester, String needle, {int column = 8}) async {
      final row = find.byWidgetPredicate(
        (w) => w is TerminalLineView && w.line.span.toPlainText().contains(needle),
      );
      final metrics = CellMetrics.measure(
        settings.fontSize,
        tester.view.devicePixelRatio,
      );
      final rect = tester.getRect(row.first);
      await tester.tapAt(Offset(rect.left + (column + 0.5) * metrics.advance, rect.center.dy));
      await _settle(tester);
    }

    FakeFs filesystem() {
      final fs = FakeFs()
        ..addDir('/work/w1/lib')
        ..addFile('/work/w1/lib/main.dart', 'void main() {}\n' * 30)
        ..addFile('/home/dev/notes.md', '# notes');
      transport.fs = fs;
      return fs;
    }

    group('a web link', () {
      testWidgets('shows the whole address, then open or copy', (tester) async {
        transport.readText = 'see $docs for more';
        await pumpPane(tester);

        await tapText(tester, 'for more');

        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, docs);
        expect(find.text('example.com'), findsOneWidget, reason: 'headed by the host');
        expect(find.text('Open in browser'), findsOneWidget);
        expect(find.text('Copy link'), findsOneWidget);
        await teardown(tester);
      });

      testWidgets('copies the address', (tester) async {
        transport.readText = 'see $docs for more';
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
        await pumpPane(tester);
        await tapText(tester, 'for more');

        await tester.tap(find.text('Copy link'));
        await _settle(tester);

        expect(copied, docs);
        expect(find.text('Open in browser'), findsNothing, reason: 'the sheet closed');
        expect(find.text('Link copied'), findsOneWidget);
        await teardown(tester);
      });

      for (final local in [
        'http://localhost:3000/app',
        'http://127.0.0.1:8080',
        'https://0.0.0.0:9000/x',
        'http://[::1]:5173/',
        'http://devbox.local:4000/ui',
      ]) {
        testWidgets('on the machine itself ($local) can only be copied',
            (tester) async {
          transport.readText = 'listening on $local now';
          await pumpPane(tester);

          await tapText(tester, 'listening on', column: 16);

          expect(find.textContaining('on the machine, not your phone'), findsOneWidget);
          expect(find.text('Open in browser'), findsNothing);
          expect(find.text('Copy link'), findsOneWidget);
          await teardown(tester);
        });
      }

      testWidgets('plain http is shown, with a warning, before it can be opened',
          (tester) async {
        transport.readText = 'see http://example.org/a for more';
        await pumpPane(tester);
        await tapText(tester, 'for more');

        expect(find.textContaining('not encrypted'), findsOneWidget);
        expect(find.text('Open in browser'), findsOneWidget);
        await teardown(tester);
      });

      testWidgets('a very long address wraps in the sheet and the sheet scrolls',
          (tester) async {
        final long = 'https://example.com/${'segment/' * 40}file.html?x=${'1234567890' * 8}';
        transport.readText = 'go $long';
        await pumpPane(tester);
        await tapText(tester, 'go ');

        expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, long);
        expect(tester.takeException(), isNull);
        await teardown(tester);
      });
    });

    group('a file path', () {
      testWidgets('opens the file, found from the pane\'s folder', (tester) async {
        final fs = filesystem();
        transport.readText = 'edited lib/main.dart:12:3 just now';
        await pumpPane(tester);

        await tapText(tester, 'edited', column: 10);
        await tester.pumpAndSettle();

        expect(fs.calls, contains('stat /work/w1/lib/main.dart'));
        expect(find.byType(FileViewerScreen), findsOneWidget);
        expect(find.byType(PaneScreen, skipOffstage: false), findsOneWidget);
        await teardown(tester);
      });

      testWidgets('opens an absolute path and a ~ path', (tester) async {
        final fs = filesystem();
        transport.readText = 'wrote ~/notes.md and /work/w1/lib/main.dart';
        await pumpPane(tester);

        await tapText(tester, 'wrote', column: 10);
        await tester.pumpAndSettle();
        expect(fs.calls, contains('stat /home/dev/notes.md'));
        expect(find.byType(FileViewerScreen), findsOneWidget);
        await teardown(tester);
      });

      // A folder is not underlined (`src/`, `/work/w1/lib` are plain text), but
      // a name that looks like a file can still turn out to be one.
      testWidgets('a path that turns out to be a folder opens the browser', (tester) async {
        final fs = filesystem()..addDir('/work/w1/build.d');
        transport.readText = 'created /work/w1/build.d today';
        await pumpPane(tester);

        await tapText(tester, 'created', column: 12);
        await tester.pumpAndSettle();

        expect(fs.calls, contains('stat /work/w1/build.d'));
        expect(find.byType(FileBrowserScreen), findsOneWidget);
        await teardown(tester);
      });

      testWidgets('a path that is not there says so on the screen that opened', (tester) async {
        filesystem();
        transport.readText = 'see src/gone.dart:1 please';
        await pumpPane(tester);

        await tapText(tester, 'see src', column: 8);
        await tester.pumpAndSettle();

        expect(find.byType(FileViewerScreen), findsNothing);
        expect(find.text('Not found'), findsOneWidget);
        expect(find.textContaining('gone.dart'), findsWidgets);
        await teardown(tester);
      });

      testWidgets('on a machine without files, it says so', (tester) async {
        transport.readText = 'see lib/main.dart please';
        await pumpPane(tester);

        await tapText(tester, 'see lib', column: 8);
        await tester.pumpAndSettle();

        expect(find.textContaining('not available'), findsOneWidget);
        expect(find.byType(FileViewerScreen), findsNothing);
        await teardown(tester);
      });
    });

    group('the Files button', () {
      testWidgets('is there when the machine has files, and opens its browser at the '
          'pane\'s folder', (tester) async {
        final fs = filesystem();
        await pumpPane(tester);

        expect(find.byTooltip('Browse files'), findsOneWidget);
        await tester.tap(find.byTooltip('Browse files'));
        await tester.pumpAndSettle();

        expect(find.byType(FileBrowserScreen), findsOneWidget);
        expect(fs.calls, contains('list /work/w1'));
        await teardown(tester);
      });

      testWidgets('is not there when the machine cannot do files', (tester) async {
        await pumpPane(tester);

        expect(find.byTooltip('Browse files'), findsNothing);
        await teardown(tester);
      });

      testWidgets('goes with the top bar in landscape with the keyboard up',
          (tester) async {
        filesystem();
        tester.view.physicalSize = const Size(740, 360);
        tester.view.devicePixelRatio = 1;
        tester.view.viewInsets = const FakeViewPadding(bottom: 200);
        addTearDown(tester.view.reset);
        await pumpPane(tester);

        expect(find.byTooltip('Browse files'), findsNothing);

        tester.view.viewInsets = FakeViewPadding.zero;
        await tester.pump();
        expect(find.byTooltip('Browse files'), findsOneWidget);
        await teardown(tester);
      });

      testWidgets('is a 44dp target', (tester) async {
        filesystem();
        await pumpPane(tester);

        final size = tester.getSize(find.byTooltip('Browse files').first);
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
        await teardown(tester);
      });
    });

    group('scrollback', () {
      testWidgets('reads 300 rows until the user nears the top, then 1000',
          (tester) async {
        final rows = [for (var i = 0; i < 2000; i++) 'row $i'];
        transport.readFor = (params) {
          final n = (params['lines']! as int).clamp(0, 1000);
          return (rows.sublist(rows.length - n).join('\r\n'), true);
        };
        await pumpPane(tester);
        expect(transport.lines.toSet(), {300});

        final position = tester
            .state<ScrollableState>(find
                .descendant(
                    of: find.byType(CustomScrollView), matching: find.byType(Scrollable))
                .first)
            .position;
        position.jumpTo(position.maxScrollExtent - 3000);
        await _settle(tester);
        expect(transport.lines.toSet(), {300}, reason: 'far from the top yet');

        position.jumpTo(position.maxScrollExtent);
        await _settle(tester);
        await tester.pump(const Duration(seconds: 2));

        expect(transport.lines, contains(1000));
        position.jumpTo(position.maxScrollExtent);
        await _settle(tester);
        expect(terminalRow('row 1000'), findsOneWidget, reason: 'the oldest row herdr serves');
        expect(find.textContaining('Earlier output is not available'), findsOneWidget);
        await teardown(tester);
      });
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
        rebuilt.where({'PaneTopBar', '_Banner', 'QuickKeys', '_Composer', '_TerminalPanel', '_PaneView', 'AnswerDock', '_Dock'}.contains),
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
      expect(rebuilt, contains('${ValueListenableBuilder<PaneTitle?>}'),
          reason: 'the title block follows the pane');
      expect(rebuilt.where({'QuickKeys', '_Composer', '_Banner'}.contains), isEmpty);
      await teardown(tester);
    });
  });
}
