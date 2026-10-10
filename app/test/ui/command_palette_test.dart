import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/slash_catalog.dart';
import 'package:herdr_mobile/data/repositories/slash_usage.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/features/pane/slash_palette.dart';
import 'package:herdr_mobile/ui/features/pane/slash_view_model.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_network.dart';
import '../support/fake_transport.dart';
import '../support/files_support.dart';
import '../support/memory_stores.dart';
import '../support/memory_terminal_settings_store.dart';

class _Store implements SlashUsageStore {
  SlashUsageMemory memory = const SlashUsageMemory();

  @override
  Future<SlashUsageMemory> read() async => memory;

  @override
  Future<void> write(SlashUsageMemory value) async => memory = value;
}

const _pane = 'w1:p1';

class _PaneTransport extends FakeTransport {
  _PaneTransport()
      : super(snapshotJson(
          panes: [(id: _pane, ws: 'w1', agent: 'omp', status: 'idle')],
        ));

  /// Fails every `pane.send_input` with this while set.
  Object? sendFailure;

  List<String> get sent => [
        for (final (method, params) in calls)
          if (method == 'pane.send_input') params['text']! as String,
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
    return Future.value({
      'type': 'pane_read',
      'read': {'text': 'ready', 'truncated': false},
    });
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('SlashPalette', () {
    late SlashUsage usage;
    late TextEditingController input;
    final picked = <String>[];

    Future<SlashViewModel> pumpPalette(WidgetTester tester, {SlashUsage? withUsage}) async {
      final model = SlashViewModel(
        agent: () => 'claude',
        cwd: () => null,
        catalog: SlashCatalog(machineWithFiles(null).files),
        usage: withUsage,
      );
      await tester.runAsync(() async {
        model.ensureLoaded();
        await pumpEventQueue();
      });
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SlashPalette(
                input: input,
                model: model,
                onPick: (c) => picked.add(c.name),
              ),
            ),
          ),
        ),
      );
      return model;
    }

    setUp(() {
      usage = SlashUsage(_Store());
      input = TextEditingController(text: '/');
      picked.clear();
    });

    tearDown(() => input.dispose());

    Finder row(String name) => find.text('/$name');
    Finder pins() => find.byIcon(LucideIcons.pin);

    testWidgets('a long press pins the row, shows the pin, and moves it to the top', (tester) async {
      final model = await pumpPalette(tester, withUsage: usage);
      expect(pins(), findsNothing);
      final before = tester.getTopLeft(row('resume')).dy;

      await tester.longPress(row('resume'));
      await tester.pump();

      expect(usage.isPinned('claude', 'resume'), isTrue);
      expect(pins(), findsOneWidget);
      expect(picked, isEmpty, reason: 'a long press is not a pick');
      expect(model.match('/').first.name, 'resume');
      expect(tester.getTopLeft(row('resume')).dy, lessThan(before));
      expect(
        tester.getTopLeft(pins()).dy,
        inInclusiveRange(tester.getTopLeft(row('resume')).dy - 20, tester.getBottomLeft(row('resume')).dy + 20),
        reason: 'the pin is on the pinned row',
      );
    });

    testWidgets('a second long press unpins it', (tester) async {
      await usage.togglePin('claude', 'resume');
      await pumpPalette(tester, withUsage: usage);
      expect(pins(), findsOneWidget);

      await tester.longPress(row('resume'));
      await tester.pump();

      expect(usage.isPinned('claude', 'resume'), isFalse);
      expect(pins(), findsNothing);
    });

    testWidgets('the pin is announced', (tester) async {
      final semantics = tester.ensureSemantics();
      await usage.togglePin('claude', 'resume');
      await pumpPalette(tester, withUsage: usage);

      expect(find.bySemanticsLabel(RegExp('Pinned')), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('a tap still picks, pinned or not', (tester) async {
      await usage.togglePin('claude', 'resume');
      await pumpPalette(tester, withUsage: usage);

      await tester.tap(row('resume'));
      await tester.tap(row('compact'));

      expect(picked, ['resume', 'compact']);
    });

    testWidgets('recents lead the list after a command was sent', (tester) async {
      await usage.record('claude', 'memory');
      await pumpPalette(tester, withUsage: usage);

      final memory = tester.getTopLeft(row('memory')).dy;
      expect(memory, lessThan(tester.getTopLeft(row('clear')).dy));
      expect(pins(), findsNothing, reason: 'recent is not pinned');
    });

    testWidgets('without a usage a long press does nothing and no pin shows', (tester) async {
      await pumpPalette(tester);

      await tester.longPress(row('resume'));
      await tester.pump();

      expect(pins(), findsNothing);
      expect(picked, isEmpty);
    });
  });

  group('in a pane', () {
    late _PaneTransport transport;
    late MachineConnection machine;
    late FleetRepository fleet;
    late AgentScreens screens;
    late PanePreviews previews;
    late SlashUsage usage;

    setUp(() {
      transport = _PaneTransport();
      machine = MachineConnection(
        profile: MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
        api: HerdrApi(transport),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
      );
      usage = SlashUsage(_Store());
    });

    Future<void> pumpPane(WidgetTester tester) async {
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
            ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
            ChangeNotifierProvider.value(value: fleet),
            ChangeNotifierProvider.value(value: screens),
            ChangeNotifierProvider.value(value: usage),
            Provider<PanePreviews>.value(value: previews),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: PaneScreen(agent: PaneAgent(machine.profile.id, _pane)),
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

    Finder composer() => find.byType(TextField);

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(composer(), text);
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await _settle(tester);
    }

    testWidgets('a command sent to an agent without a table is remembered and offered on a slash',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);
      await tester.enterText(composer(), '/');
      await tester.pump();
      await tester.pump();
      expect(find.text('/review'), findsNothing, reason: 'omp has no table and nothing was sent');

      await send(tester, '/review the diff');

      expect(transport.sent, ['/review the diff']);
      expect(usage.count('omp', 'review'), 1);
      await tester.enterText(composer(), '/');
      await tester.pump();
      await tester.pump();
      expect(find.text('/review'), findsOneWidget);

      await tester.longPress(find.text('/review'));
      await tester.pump();
      expect(usage.isPinned('omp', 'review'), isTrue);
      expect(find.byIcon(LucideIcons.pin), findsOneWidget);
      semantics.dispose();
      await teardown(tester);
    });

    testWidgets('a path, plain text and a failed send are not remembered', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPane(tester);

      await send(tester, '/etc/hosts looks odd');
      await send(tester, 'review it');
      expect(transport.sent, ['/etc/hosts looks odd', 'review it']);
      expect(usage.used('omp'), isEmpty);

      transport.sendFailure = const HerdrTransportException('link down');
      await send(tester, '/deploy now');
      expect(usage.used('omp'), isEmpty, reason: 'the agent never got it');
      expect(tester.widget<TextField>(composer()).controller!.text, '/deploy now',
          reason: 'a failed send keeps what was typed');
      semantics.dispose();
      await teardown(tester);
    });
  });
}
