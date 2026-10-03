import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../support/fake_network.dart';
import '../support/fake_transport.dart';
import '../support/memory_stores.dart';

typedef Pane = ({String id, String ws, String? agent, String status});

/// A fake machine that also answers `pane.read`, with [paneText] for every pane.
class UiTransport extends FakeTransport {
  UiTransport(super.snapshot);

  String paneText = '';

  @override
  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (method != 'pane.read') return super.request(method, params);
    calls.add((method, params));
    return Future.value({
      'type': 'pane_read',
      'read': {'text': paneText, 'truncated': false},
    });
  }
}

/// A fleet of fake machines wired like the app wires real ones.
class UiHarness {
  UiHarness._(this.machines, this.fleet, this.network, this.transports);

  final MachineRepository machines;
  final FleetRepository fleet;
  final FakeNetwork network;
  final Map<String, UiTransport> transports;

  static Future<UiHarness> create(
    List<({MachineProfile profile, Map<String, dynamic> snapshot})> spec,
  ) async {
    final machines = MachineRepository(
        profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await machines.load();
    final network = FakeNetwork();
    final transports = {
      for (final s in spec) s.profile.id: UiTransport(s.snapshot),
    };
    final fleet = FleetRepository(
      machines: machines,
      network: network,
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transports[profile.id]!),
        backoff: (_) => const Duration(hours: 1),
      ),
    );
    for (final s in spec) {
      await machines.save(s.profile, secrets: const MachineSecrets(password: 'x'));
    }
    await fleet.settled();
    return UiHarness._(machines, fleet, network, transports);
  }

  void dispose() => fleet.dispose();
}

/// Pumps the real app shell at a phone size.
Future<void> pumpUi(
  WidgetTester tester,
  UiHarness h, {
  double width = 360,
  double height = 740,
  double textScale = 1,
  Brightness brightness = Brightness.dark,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.machines),
        ChangeNotifierProvider.value(value: h.fleet),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const HomeShell(),
      ),
    ),
  );
  await settle(tester);
}

/// Lets connections come online and animations finish.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}


/// Tears the tree down so no timers outlive the test.
Future<void> teardownUi(WidgetTester tester, UiHarness h) async {
  await tester.pumpWidget(const SizedBox());
  h.dispose();
}

/// A `session.snapshot` with [panes], customised through the given hooks.
Map<String, dynamic> snapshotWith(
  List<Pane> panes, {
  List<({String id, String label})>? workspaces,
  String Function(String paneId)? title,
  String Function(String paneId)? cwd,
}) {
  final json = snapshotJson(
    panes: panes,
    workspaces: workspaces ?? const [(id: 'w1', label: 'main')],
  );
  for (final p in json['panes'] as List) {
    final m = p as Map<String, dynamic>;
    final id = m['pane_id'] as String;
    if (title != null) m['terminal_title_stripped'] = title(id);
    if (cwd != null) m['cwd'] = cwd(id);
  }
  return json;
}
