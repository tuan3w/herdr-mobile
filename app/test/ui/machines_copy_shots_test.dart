// Renders the machine screens that changed with the design review to PNGs: the
// Machines list with a changed host key (its way out is Remove, not Retry) beside
// another failure, the same machine's own screen, the empty states without a
// decorative icon (`No workspaces`, `No agents running`) beside one with its
// icon, and the Files host tab of a machine that cannot browse. Light and dark at
// 412x892, and 320x640 at 1.6 text scale. Off by default; it writes files:
//
//   COPY_SHOTS=1 flutter test test/ui/machines_copy_shots_test.dart
//
// Output: $COPY_SHOTS_DIR (default /dev/shm/copy_shots)/<case>-<light|dark>-<w>x<h>[-x1.6].png
@TestOn('vm')
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart' show hostKeyChangedMessage;
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

HerdrTransport _noTransport(
  MachineProfile profile,
  MachineSecrets secrets,
  void Function(String) onPin,
  void Function(String) onNotice,
) => throw StateError('shots never open a connection');

MachineProfile _m(String id, String label) =>
    MachineProfile(id: id, label: label, host: 'h.example', username: 'dev', auth: SshAuth.password);

void main() {
  if (Platform.environment['COPY_SHOTS'] == null) {
    test('copy shots are off (set COPY_SHOTS=1)', () {}, skip: 'set COPY_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['COPY_SHOTS_DIR'] ?? '/dev/shm/copy_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<void> flush(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      for (var j = 0; j < 30; j++) {
        await Future<void>.value();
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Brightness b,
    Size size,
    double scale,
    Widget Function(UiHarness h) home, {
    required Future<UiHarness> Function() harness,
    Future<void> Function(WidgetTester tester, UiHarness h)? after,
  }) async {
    const dpr = 2.625;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = const FakeViewPadding(top: 24 * dpr, bottom: 20 * dpr);
    tester.view.viewPadding = tester.view.padding;
    addTearDown(tester.view.reset);
    final h = await harness();
    final key = GlobalKey();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<TransportFactory>.value(value: _noTransport),
          ChangeNotifierProvider.value(value: h.machines),
          ChangeNotifierProvider.value(value: h.fleet),
          ChangeNotifierProvider.value(value: h.terminalSettings),
          ChangeNotifierProvider.value(value: h.appSettings),
          ChangeNotifierProvider.value(value: h.agentScreens),
          Provider<PanePreviews>.value(value: h.previews),
          ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
          Provider<Notifier>.value(value: const NullNotifier()),
          attentionSetProvider(),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: b == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: key, child: child!),
          ),
          home: home(h),
        ),
      ),
    );
    await flush(tester);
    if (after != null) await after(tester, h);
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 1.5);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final tag = '${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-x$scale'}';
      await File('$out/$name-${b.name}-$tag.png').writeAsBytes(data!.buffer.asUint8List());
    });
    expect(tester.takeException(), isNull, reason: '$name ${b.name} $size');
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  }

  Future<UiHarness> twoFailures() async {
    final h = await UiHarness.create([
      (profile: _m('key', 'staging'), snapshot: snapshotWith(const [])),
      (profile: _m('pw', 'laptop'), snapshot: snapshotWith(const [])),
    ]);
    h.transports['key']!.failure = const HerdrTransportException(hostKeyChangedMessage, fatal: true);
    h.fleet.connection('key')!.reconnect();
    h.transports['pw']!.failure = const HerdrTransportException('Permission denied (publickey).', fatal: true);
    h.fleet.connection('pw')!.reconnect();
    return h;
  }

  Future<UiHarness> noWorkspaces() async =>
      UiHarness.create([(profile: _m('a', 'box'), snapshot: snapshotWith(const [], workspaces: const []))]);

  final cases = <String, (Future<UiHarness> Function(), Widget Function(UiHarness))>{
    'machines-host-key': (twoFailures, (h) => const MachinesScreen()),
    'machine-host-key': (twoFailures, (h) => MachineScreen(machine: h.fleet.connection('key')!)),
    'machine-no-workspaces': (noWorkspaces, (h) => MachineScreen(machine: h.fleet.connection('a')!)),
    'agents-empty': (noWorkspaces, (h) => const HomeShell()),
    'empty-states': (
      noWorkspaces,
      (h) => Scaffold(
        body: Column(
          children: const [
            Expanded(
              child: EmptyState(
                icon: LucideIcons.searchX,
                title: 'Nothing named “x”',
                message: 'Nothing in the folder.',
              ),
            ),
            Expanded(
              child: EmptyState(title: 'No agents running', message: 'Start one in herdr and it shows here.'),
            ),
          ],
        ),
      ),
    ),
  };

  for (final MapEntry(key: name, value: (harness, home)) in cases.entries) {
    for (final (size, scale) in [(const Size(412, 892), 1.0), (const Size(320, 640), 1.6)]) {
      for (final b in Brightness.values) {
        testWidgets('$name ${b.name} ${size.width.toInt()}x${size.height.toInt()} x$scale', (tester) async {
          await shoot(tester, name, b, size, scale, home, harness: harness);
        });
      }
    }
  }
}
