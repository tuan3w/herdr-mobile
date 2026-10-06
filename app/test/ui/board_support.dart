import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import '../support/fake_network.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_stores.dart';
import '../support/memory_terminal_settings_store.dart';
import 'ui_harness.dart';

/// Previews the test controls: one notifier per pane, with a log of who
/// watched and released what. Stands in for [PanePreviews] where a test needs
/// exact text, a prompt, or to count watchers.
class FakePreviews implements PanePreviews {
  final Map<String, ValueNotifier<PanePreview?>> _data = {};

  /// `machine/pane` of every watch ever opened, in order.
  final List<String> opened = [];

  /// Open handles per `machine/pane`.
  final Map<String, int> open = {};

  int get openCount => open.values.fold(0, (a, b) => a + b);

  ValueNotifier<PanePreview?> _of(String key) => _data.putIfAbsent(key, () => ValueNotifier(null));

  /// Sets what `machine/pane` previews. [prompt] marks it a question.
  void set(String key, List<String> lines, {PromptInfo? prompt, DateTime? at}) {
    _of(key).value = PanePreview(
      lines: [for (final l in lines) PreviewLine(l)],
      prompt: prompt,
      updatedAt: at ?? DateTime(2026, 1, 1),
    );
  }

  @override
  PreviewHandle watch(String machineId, String paneId) {
    final key = '$machineId/$paneId';
    opened.add(key);
    open[key] = (open[key] ?? 0) + 1;
    return _FakeHandle(_of(key), () => open[key] = open[key]! - 1);
  }

  /// What the next fresh read of `machine/pane` ([recheck]) finds, when it is
  /// not what the pane shows: the desktop answered and the agent asked
  /// something else (null: it asks nothing). The read then shows it.
  final Map<String, PromptInfo?> asksNow = {};

  /// `machine/pane` of every [recheck], in order.
  final List<String> rechecked = [];

  /// Like the real one, shows what it read: the question asked now replaces
  /// the one on screen.
  @override
  Future<PromptInfo?> recheck(MachineConnection machine, String paneId) async {
    final key = '${machine.profile.id}/$paneId';
    rechecked.add(key);
    final shown = _of(key).value;
    if (!asksNow.containsKey(key)) return shown?.prompt;
    final now = asksNow.remove(key);
    set(key, [for (final l in shown?.lines ?? const <PreviewLine>[]) l.text], prompt: now);
    return now;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeHandle implements PreviewHandle {
  _FakeHandle(this.preview, this._release);

  @override
  final ValueListenable<PanePreview?> preview;
  final VoidCallback _release;
  bool _done = false;

  @override
  void release() {
    if (_done) return;
    _done = true;
    _release();
  }
}

/// A fleet like [UiHarness]'s but with a clock the test can shift (so a pane
/// can have "been working for 12 minutes") and previews the test controls.
class BoardHarness {
  BoardHarness._(this.machines, this.fleet, this.network, this.transports, this._shift, this.agentScreens);

  final _Shift _shift;

  final previews = FakePreviews();
  final AgentScreens agentScreens;
  final terminalSettings = TerminalSettings(MemoryTerminalSettingsStore());
  final appSettings = AppSettings(MemoryAppSettingsStore());
  final MachineRepository machines;
  final FleetRepository fleet;
  final FakeNetwork network;
  final Map<String, UiTransport> transports;

  /// Added to "now" when a connection stamps the moment it saw a status
  /// change. Set to minus twelve minutes, push a change, and the pane has been
  /// in its new status for twelve minutes.
  Duration get observedAgo => _shift.ago;
  set observedAgo(Duration d) => _shift.ago = d;

  /// With [observedAgo] set, the connections' clocks start that far behind, so
  /// what they first see (the event stream going live) is dated that long ago.
  static Future<BoardHarness> create(
    List<({MachineProfile profile, Map<String, dynamic> snapshot})> spec, {
    Duration observedAgo = Duration.zero,
  }) async {
    final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await machines.load();
    final network = FakeNetwork();
    final transports = {for (final s in spec) s.profile.id: UiTransport(s.snapshot)};
    final shift = _Shift()..ago = observedAgo;
    final agentScreens = AgentScreens();
    final fleet = FleetRepository(
      screens: agentScreens,
      machines: machines,
      network: network,
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(transports[profile.id]!),
        backoff: (_) => const Duration(hours: 1),
        clock: () => DateTime.now().subtract(shift.ago),
      ),
    );
    for (final s in spec) {
      await machines.save(s.profile, secrets: const MachineSecrets(password: 'x'));
    }
    await fleet.settled();
    final harness = BoardHarness._(machines, fleet, network, transports, shift, agentScreens);
    // Cards whatever the agent count (`auto` turns compact from 5); the board
    // tests look at cards. attention_test.dart tests `auto`.
    await harness.appSettings.setDensity(BoardDensity.cards);
    return harness;
  }

  List<SingleChildWidget> get providers => [
        ChangeNotifierProvider.value(value: machines),
        ChangeNotifierProvider.value(value: fleet),
        ChangeNotifierProvider.value(value: terminalSettings),
        ChangeNotifierProvider.value(value: appSettings),
        ChangeNotifierProvider.value(value: agentScreens),
        ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
        Provider<Notifier>.value(value: const NullNotifier()),
        Provider<PanePreviews>.value(value: previews),
        Provider<TransportFactory>.value(
          value: (profile, secrets, onPin, onNotice) => UiTransport(snapshotWith(const [])),
        ),
        // A test that adds sessions after these adds it again after them.
        attentionSetProvider(),
      ];

  /// Moves panes to new statuses as if observed [ago] ago.
  Future<void> changeStatuses(
    WidgetTester tester,
    String machineId,
    List<Pane> panes, {
    Duration ago = Duration.zero,
    String Function(String paneId)? title,
  }) async {
    observedAgo = ago;
    transports[machineId]!.snapshot = snapshotWith(panes, title: title);
    transports[machineId]!.emit(const {'event': 'pane.agent_status_changed'});
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    observedAgo = Duration.zero;
  }

  void dispose() {
    agentScreens.dispose();
    fleet.dispose();
  }
}

/// Pumps the real shell with [h]'s providers at a phone size.
Future<void> pumpBoard(
  WidgetTester tester,
  BoardHarness h, {
  double width = 360,
  double height = 740,
  double textScale = 1,
  Brightness brightness = Brightness.dark,
  bool reduceMotion = false,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: h.providers,
      child: MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: const HomeShell(),
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> teardownBoard(WidgetTester tester, BoardHarness h) async {
  await tester.pumpWidget(const SizedBox());
  h.dispose();
}

class _Shift {
  Duration ago = Duration.zero;
}
