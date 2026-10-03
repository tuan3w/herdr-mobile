// Renders the raw store screenshots (412x892 dp at 3x) into $HERDR_RAW_DIR
// (default /tmp/herdr_raw). Run with `tool/screenshots/run.sh`, which then
// composes the framed images. Not part of `flutter test`: the folder is
// `screenshot_test`, not `test`.
//
// All names below are invented demo data (see demo_fleet.dart).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/repositories/new_session_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/ui/core/chrome.dart' show FloatingTabBar;
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/features/create/new_session_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_viewer_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/pane/pane_navigation.dart';
import 'package:herdr_mobile/ui/features/pane/tab_strip.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';

import '../test/support/create_harness.dart' show MemoryNewSessionStore;
import '../test/support/shot.dart';
import '../test/ui/ui_harness.dart' show UiTransport, snapshotWith;
import 'dashboard_png.dart';
import 'demo_fleet.dart';
import 'demo_terminal.dart';

final _raw = Directory(Platform.environment['HERDR_RAW_DIR'] ?? '/tmp/herdr_raw');

/// Pumps [total] of fake time in 100 ms steps (reads, throttles and
/// animations all run on timers).
Future<void> _pumpFor(WidgetTester tester, Duration total) async {
  for (var left = total; left > Duration.zero; left -= const Duration(milliseconds: 100)) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Lets queued microtasks and animations run (the form's view model answers
/// through futures that a bare `pump` does not wait for).
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens a pane the way a tap on the board does: through the app's own
/// `openPaneTab`.
Future<void> _openPane(WidgetTester tester, DemoFleet h, String machineId, String paneId) async {
  await h.online(tester);
  final context = tester.element(find.byType(HomeShell));
  unawaited(openPaneTab(context, h.fleet.connection(machineId)!, paneId));
  await _pumpFor(tester, const Duration(milliseconds: 1600));
}

/// Opens [seed] as tabs, then [first] from the board, which leaves the tabs in
/// this order: [first], then [seed] reversed. After that the agent on
/// [finishes] ends its task in the background, which marks its tab.
Future<void> _openTabs(
  WidgetTester tester,
  DemoFleet h, {
  required List<(String, String)> seed,
  required (String, String) first,
  required String finishes,
}) async {
  await h.online(tester);
  for (final (machine, pane) in seed) {
    h.openTabs.open(machine, pane);
  }
  await _openPane(tester, h, first.$1, first.$2);
  await h.setStatus(tester, finishes, 'done', text: ompProfileFinishedSession());
  await _pumpFor(tester, const Duration(milliseconds: 800));
}

/// The stat the browser would hand the viewer for [path].
RemoteStat _stat(DemoFleet h, String path) {
  final node = h.transports['a']!.fs!.nodes[path]!;
  return RemoteStat(path: path, kind: RemoteEntryKind.file, size: node.bytes.length, modified: node.modified);
}

void main() {
  setUpAll(() async {
    await loadAppFonts();
    _raw.createSync(recursive: true);
  });

  for (final b in Brightness.values) {
    final tone = b.name;

    Future<void> shot(
      WidgetTester tester,
      String name,
      Widget home, {
      required DemoFleet fleet,
      Future<void> Function(WidgetTester)? pump,
      NewSessionSettings? newSession,
      TransportFactory? factory,
    }) async {
      await shoot(
        tester,
        home,
        '${_raw.path}/${name}_$tone.png',
        brightness: b,
        wrap: demoProviders(fleet, factory: factory, newSession: newSession),
        imageScale: 3,
        pump: pump,
      );
    }

    testWidgets('board $tone', (tester) async {
      final h = await DemoFleet.create(timed: true);
      await shot(tester, 'board', const HomeShell(), fleet: h, pump: (t) async {
        await h.ageStatuses(t);
        // Previews are read one after the other, a few at a time.
        await _pumpFor(t, const Duration(seconds: 4));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('machines $tone', (tester) async {
      final h = await DemoFleet.create();
      await shot(tester, 'machines', const HomeShell(), fleet: h, pump: (t) async {
        await t.tap(find.byKey(FloatingTabBar.tabKey('Machines')));
        await t.pump(const Duration(milliseconds: 600));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('pane $tone', (tester) async {
      final h = await DemoFleet.create();
      await shot(tester, 'pane', const HomeShell(), fleet: h, pump: (t) => _openPane(t, h, 'a', 'a1:p1'));
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('reply $tone', (tester) async {
      final h = await DemoFleet.create();
      await shot(tester, 'reply', const HomeShell(), fleet: h, pump: (t) async {
        await _openPane(t, h, 'a', 'a1:p1');
        await t.enterText(find.byType(TextField), '1');
        await t.pump(const Duration(milliseconds: 300));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('tailscale $tone', (tester) async {
      final h = await DemoFleet.create();
      final pending = Completer<Map<String, dynamic>>();
      addTearDown(() {
        if (!pending.isCompleted) pending.completeError(const HerdrTransportException('done'));
      });
      HerdrTransport factory(MachineProfile profile, MachineSecrets s, void Function(String) onPin,
          void Function(String) onNotice) {
        scheduleMicrotask(() => onNotice(
              '# Tailscale SSH requires an additional check.\n'
              '# To authenticate, visit: https://login.tailscale.com/a/l3a91f0c2d7b5e',
            ));
        return _HangingTransport(pending);
      }

      await shot(tester, 'tailscale', const MachineFormScreen(), fleet: h, factory: factory, pump: (t) async {
        final fields = find.byType(TextFormField);
        await t.enterText(fields.at(0), 'studio-mac');
        await t.enterText(fields.at(1), 'studio-mac.tail1a2b.ts.net');
        await t.enterText(fields.at(3), 'maya');
        await t.tap(find.text('Tailscale').first);
        await t.pump(const Duration(milliseconds: 400));
        await t.tap(find.text('Test connection'));
        await t.pump(const Duration(milliseconds: 600));
        await t.pump(const Duration(milliseconds: 600));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('links $tone', (tester) async {
      final h = await DemoFleet.create();
      await shot(tester, 'links', const HomeShell(), fleet: h, pump: (t) => _openPane(t, h, 'a', 'a2:p1'));
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('files $tone', (tester) async {
      final h = await DemoFleet.create();
      await h.online(tester);
      await shot(
        tester,
        'files',
        FileViewerScreen(
          machine: h.fleet.connection('a')!,
          stat: _stat(h, '$projectDir/services/ledger/repository.go'),
          line: 13,
        ),
        fleet: h,
      );
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('browser $tone', (tester) async {
      final h = await DemoFleet.create();
      await h.online(tester);
      await shot(tester, 'browser', FileBrowserScreen(machine: h.fleet.connection('a')!, path: projectDir), fleet: h);
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('image $tone', (tester) async {
      final h = await DemoFleet.create(chart: await dashboardPng(tester, dark: b == Brightness.dark));
      await h.online(tester);
      await shot(
        tester,
        'image',
        FileViewerScreen(machine: h.fleet.connection('a')!, stat: _stat(h, chartPath)),
        fleet: h,
        pump: (t) async {
          for (var i = 0; i < 80 && find.byType(RawImage).evaluate().isEmpty; i++) {
            await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
            await t.pump();
          }
          await t.pump(const Duration(milliseconds: 600));
        },
      );
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('new-session $tone', (tester) async {
      final h = await DemoFleet.create();
      await h.online(tester);
      final settings = NewSessionSettings(MemoryNewSessionStore());
      Finder field(String label) => find.descendant(
            of: find.byWidgetPredicate((w) => w is LabeledField && w.label == label),
            matching: find.byType(TextFormField),
          );
      await shot(tester, 'new-session', const NewSessionScreen(machineId: 'a'), fleet: h, newSession: settings, pump: (t) async {
        await t.enterText(field('Folder'), projectDir);
        await t.pump(const Duration(milliseconds: 300));
        final claude = find.widgetWithText(AppChip, 'claude');
        await t.ensureVisible(claude);
        await _flush(t);
        await t.tap(claude);
        await _flush(t);
        await t.enterText(
          field('First message (optional)'),
          'Migrate ledger amounts to BIGINT and add a currency column. Keep the tests green.',
        );
        await t.pump(const Duration(milliseconds: 300));
        // Scroll the title away so the folder, agent, command and first
        // message are on screen together.
        await t.drag(find.byType(CustomScrollView), const Offset(0, -205));
        await _flush(t);
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('tabs $tone', (tester) async {
      final h = await DemoFleet.create(timed: true);
      await shot(tester, 'tabs', const HomeShell(), fleet: h, pump: (t) async {
        await h.ageStatuses(t);
        await _openTabs(
          t,
          h,
          seed: const [('a', 'a1:p1'), ('a', 'a2:p1'), ('c', 'c1:p1')],
          first: ('a', 'a1:p2'),
          finishes: 'c1:p1',
        );
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });

    testWidgets('tray $tone', (tester) async {
      final h = await DemoFleet.create(timed: true);
      await shot(tester, 'tray', const HomeShell(), fleet: h, pump: (t) async {
        await h.ageStatuses(t);
        await _openTabs(
          t,
          h,
          seed: const [('b', 'b1:p2'), ('a', 'a1:p1'), ('a', 'a2:p1'), ('c', 'c1:p1')],
          first: ('a', 'a1:p2'),
          finishes: 'c1:p1',
        );
        await t.tap(find.byType(TabCountButton));
        await _pumpFor(t, const Duration(seconds: 4));
      });
      await tester.pumpWidget(const SizedBox());
      h.dispose();
    });
  }
}

/// A host that never answers: the form stays on "waiting for sign-in".
class _HangingTransport extends UiTransport {
  _HangingTransport(this._never) : super(snapshotWith(const []));

  final Completer<Map<String, dynamic>> _never;

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) =>
      _never.future;
}
