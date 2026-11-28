// A board with one agent over fakes, for the tests and shots of opening an
// agent's terminal: a clock the test moves with its frames, a herdr whose
// tail reads can be held back and are counted when they are SENT, and the
// real shell, previews and fleet around them. Only uses what the app had
// before the pane tails, so the same file renders the "before" shots.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import '../ui/ui_harness.dart';
import 'fake_network.dart';
import 'memory_app_settings_store.dart';
import 'memory_stores.dart';
import 'memory_terminal_settings_store.dart';

const openMachine = MachineProfile(id: 'm1', label: 'Box', host: 'h', username: 'u');
const openPane = 'w1:p1';

/// Rows of the pane screen's tail (`paneTailRows`).
const tailRows = 300;

/// The clock the tails and the view model date their text by; a test moves it
/// together with the frames it pumps, so ages are exact.
class OpenClock {
  DateTime now = DateTime.utc(2026, 1, 1, 12);
  DateTime call() => now;
}

/// A herdr whose tail reads (300 rows) can be held back and are counted when
/// they are SENT, not when they are answered.
class GatedHerdr extends UiTransport {
  GatedHerdr(super.snapshot);

  /// While set, a tail read waits for it.
  Completer<void>? gate;

  /// `pane.read` of the tail, per pane, in the order they were sent.
  final tailReads = <String>[];

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    final tail = method == 'pane.read' && params['lines'] == tailRows;
    if (tail) {
      tailReads.add(params['pane_id'] as String);
      final held = gate;
      if (held != null) await held.future;
    }
    return super.request(method, params);
  }
}

class OpenRig {
  OpenRig(this.tester, this.herdr, this.fleet, this.previews, this.clock, this.screens);

  final WidgetTester tester;
  final GatedHerdr herdr;
  final FleetRepository fleet;
  final PanePreviews previews;
  final OpenClock clock;
  final AgentScreens screens;
  final settings = TerminalSettings(MemoryTerminalSettingsStore());

  /// What a shot captures: the whole app.
  final boundary = GlobalKey();

  static Future<OpenRig> start(
    WidgetTester tester, {
    String status = 'working',
    Brightness brightness = Brightness.dark,
    Size size = const Size(412, 892),
    double ratio = 1,
    double textScale = 1,
    String text = '',
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = ratio;
    addTearDown(tester.view.reset);
    final clock = OpenClock();
    final herdr = GatedHerdr(
      snapshotWith([(id: openPane, ws: 'w1', agent: 'claude', status: status)], title: (_) => 'Fix login'),
    );
    final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
    await machines.load();
    final screens = AgentScreens();
    final fleet = FleetRepository(
      screens: screens,
      machines: machines,
      network: FakeNetwork(),
      connect: (profile, secrets) => MachineConnection(
        profile: profile,
        api: HerdrApi(herdr),
        backoff: (_) => const Duration(hours: 1),
        pollInterval: const Duration(hours: 1),
        clock: clock.call,
      ),
    );
    herdr.paneText = text;
    await machines.save(openMachine, secrets: const MachineSecrets(password: 'x'));
    await fleet.settled();
    await Future<void>.value();
    final previews = PanePreviews(changes: fleet, connection: fleet.connection, clock: clock.call);
    final rig = OpenRig(tester, herdr, fleet, previews, clock, screens);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: machines),
          ChangeNotifierProvider.value(value: fleet),
          ChangeNotifierProvider.value(value: rig.settings),
          ChangeNotifierProvider.value(value: AppSettings(MemoryAppSettingsStore())),
          ChangeNotifierProvider.value(value: screens),
          ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
          Provider<Notifier>.value(value: const NullNotifier()),
          Provider<PanePreviews>.value(value: previews),
          Provider<TransportFactory>.value(
            value: (profile, secrets, onPin, onNotice) => UiTransport(snapshotWith(const [])),
          ),
          attentionSetProvider(),
        ],
        child: MaterialApp(
          theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: RepaintBoundary(key: rig.boundary, child: child!),
          ),
          home: const HomeShell(),
        ),
      ),
    );
    await rig.elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
    return rig;
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox());
    previews.dispose();
    fleet.dispose();
    screens.dispose();
  }

  /// Moves the clock and the frames together, [step] at a time.
  Future<void> elapse(Duration total, {Duration step = const Duration(seconds: 1)}) async {
    for (var left = total; left > Duration.zero; left -= step) {
      final d = left < step ? left : step;
      clock.now = clock.now.add(d);
      await tester.pump(d);
    }
  }

  Finder get row => find.text('Fix login');
  Finder get live => find.textContaining('stale');
  Finder get _navigator => find.byType(Navigator);

  /// What the board says about the pane's tail: the tail reads sent so far.
  int get reads => herdr.tailReads.length;

  /// The first frame an opened screen paints: the route is built a frame
  /// before it is shown (offstage), so this is the second pump, at the start
  /// of its transition, with nothing settled.
  Future<void> firstFrame() async {
    await tester.pump();
    await tester.pump();
  }

  /// The pane's screen leaves, back to the board.
  Future<void> back() async {
    tester.state<NavigatorState>(_navigator).pop();
    await elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
  }

  /// A page over the board (it is no longer in front).
  Future<void> coverBoard() async {
    unawaited(
      tester
          .state<NavigatorState>(_navigator)
          .push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('elsewhere')))),
    );
    await elapse(const Duration(milliseconds: 600), step: const Duration(milliseconds: 100));
  }

  /// Writes what is on screen now to [path] as a PNG.
  Future<void> shoot(String path, {double scale = 1.5}) async {
    final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      // The first capture of a boundary returns the frame before (a layer that
      // was not painted yet): the second is what is on screen.
      (await render.toImage(pixelRatio: scale)).dispose();
      final image = await render.toImage(pixelRatio: scale);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(path).writeAsBytes(data!.buffer.asUint8List());
    });
  }
}
