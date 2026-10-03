// The pane screen as a tab host: open/switch/close, what each tab keeps while it
// is hidden, who reads, the attention mark, the tray and swiping.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/open_tabs.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/ui/core/terminal_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_host_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_navigation.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/features/pane/tab_strip.dart';
import 'package:herdr_mobile/ui/features/pane/tab_swipe.dart';
import 'package:herdr_mobile/ui/features/pane/tabs_tray.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

const _machine = 'm1';

String _id(int i) => 'w1:p$i';

Pane _pane(int i, String status, {String agent = 'claude'}) =>
    (id: _id(i), ws: 'w1', agent: agent, status: status);

Map<String, dynamic> _snapshot(List<Pane> panes) =>
    snapshotWith(panes, title: (id) => 'task ${id.split('p').last}');

/// Where back leads: a screen with one button per pane.
class _Home extends StatelessWidget {
  const _Home({required this.h, required this.count});

  final UiHarness h;
  final int count;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        for (var i = 1; i <= count; i++)
          GestureDetector(
            onTap: () =>
                openPaneTab(context, h.fleet.connection(_machine)!, _id(i)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text('open ${_id(i)}'),
            ),
          ),
      ],
    ),
  );
}

Future<UiHarness> _harness({
  int panes = 3,
  String status = 'idle',
  String? text,
}) async {
  final h = await UiHarness.create([
    (
      profile: MachineProfile(
        id: _machine,
        label: 'box',
        host: 'h',
        username: 'u',
      ),
      snapshot: _snapshot([for (var i = 1; i <= panes; i++) _pane(i, status)]),
    ),
  ]);
  h.transports[_machine]!.paneText =
      text ??
      [for (var i = 0; i < 200; i++) 'line $i of the output'].join('\n');
  return h;
}

Future<void> _pump(
  WidgetTester tester,
  UiHarness h, {
  Widget? home,
  int panes = 3,
  double width = 412,
  double height = 892,
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
        ChangeNotifierProvider.value(value: h.terminalSettings),
        ChangeNotifierProvider.value(value: h.openTabs),
        Provider<PanePreviews>.value(value: h.previews),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: home ?? _Home(h: h, count: panes),
      ),
    ),
  );
  await settle(tester);
}

/// Opens [i]th pane from the home screen.
Future<void> _openFromHome(WidgetTester tester, int i) async {
  await tester.tap(find.text('open ${_id(i)}'));
  await settle(tester);
}

/// A chip in the strip, by the task it shows.
Finder _chip(int i) =>
    find.descendant(of: find.byType(TabStrip), matching: find.text('task $i'));

Future<void> _show(WidgetTester tester, int i) async {
  await tester.tap(_chip(i));
  await settle(tester);
}

String? _active(UiHarness h) => h.openTabs.active?.paneId;

/// Rows a preview asks `pane.read` for.
const _previewLines = 24;

/// `pane.read`s of one pane by the live tail (300 rows) and by previews.
int _reads(UiHarness h, int i, {int lines = 300}) => h
    .transports[_machine]!
    .calls
    .where(
      (c) =>
          c.$1 == 'pane.read' &&
          c.$2['pane_id'] == _id(i) &&
          c.$2['lines'] == lines,
    )
    .length;

Finder _terminalScrollable() => find.descendant(
  of: find.byType(TerminalView),
  matching: find.byWidgetPredicate(
    (w) => w is Scrollable && w.axisDirection == AxisDirection.up,
  ),
);

double _scrollOffset(WidgetTester tester) =>
    tester.state<ScrollableState>(_terminalScrollable().first).position.pixels;

Future<void> _tearDown(WidgetTester tester, UiHarness h) async {
  await tester.pumpWidget(const SizedBox());
  h.dispose();
}

/// Moves a finger across the terminal panel, as [timedDragFrom] does.
Future<void> _swipe(
  WidgetTester tester, {
  required Offset from,
  required Offset by,
  Duration over = const Duration(milliseconds: 200),
}) async {
  await tester.timedDragFrom(from, by, over);
  await settle(tester);
}

void main() {
  setUpAll(loadAppFonts);

  group('opening', () {
    testWidgets(
      'a pane opens in one host, and back from any tab leaves it once',
      (tester) async {
        final h = await _harness();
        await _pump(tester, h);

        await _openFromHome(tester, 1);
        expect(find.byType(PaneHostScreen), findsOneWidget);
        expect(_active(h), _id(1));

        // Open two more from inside the host (a new session, say).
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(3));
        await settle(tester);
        expect(
          find.byType(PaneHostScreen),
          findsOneWidget,
          reason: 'one host, not three',
        );
        expect(_active(h), _id(3));
        expect(h.openTabs.length, 3);

        await tester.tap(find.byTooltip('Back'));
        await settle(tester);

        expect(find.byType(PaneHostScreen), findsNothing);
        expect(
          find.text('open ${_id(1)}'),
          findsOneWidget,
          reason: 'back at the start',
        );
        await _tearDown(tester, h);
      },
    );

    testWidgets(
      'tabs survive leaving the host; entering again lists them by recency',
      (tester) async {
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(3));
        await settle(tester);
        await _show(tester, 2);
        await tester.tap(find.byTooltip('Back'));
        await settle(tester);
        expect(h.openTabs.length, 3, reason: 'leaving does not close tabs');

        await _openFromHome(tester, 3);

        expect(
          [for (final t in h.openTabs.tabs) t.paneId],
          [_id(3), _id(2), _id(1)],
          reason: 'the one just opened, then the one used before it',
        );
        expect(_active(h), _id(3));
        await _tearDown(tester, h);
      },
    );

    testWidgets('switching tabs never re-sorts the strip', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(3));
      await settle(tester);
      double x(int i) => tester.getTopLeft(_chip(i)).dx;

      final before = [x(1), x(2), x(3)];
      expect(before[0], lessThan(before[1]));
      expect(before[1], lessThan(before[2]));

      await _show(tester, 1);
      await _show(tester, 3);
      await _show(tester, 2);

      expect(
        [for (final t in h.openTabs.tabs) t.paneId],
        [_id(1), _id(2), _id(3)],
      );
      expect([x(1), x(2), x(3)].first, lessThan(x(2)));
      expect(x(2), lessThan(x(3)));
      await _tearDown(tester, h);
    });
  });

  group('closing', () {
    testWidgets(
      'x closes the selected tab, not the agent, and hands over to its neighbour',
      (tester) async {
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await settle(tester);
        await _show(tester, 1);

        await tester.tap(find.bySemanticsLabel('Close tab'));
        await settle(tester);

        expect(h.openTabs.length, 1);
        expect(_active(h), _id(2));
        expect(
          h.transports[_machine]!.calls.map((c) => c.$1),
          isNot(contains('pane.close')),
        );
        expect(find.byType(PaneHostScreen), findsOneWidget);
        await _tearDown(tester, h);
      },
    );

    testWidgets('closing the last tab leaves the host', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);

      await tester.tap(find.bySemanticsLabel('Close tab'));
      await settle(tester);

      expect(find.byType(PaneHostScreen), findsNothing);
      expect(h.openTabs.isEmpty, isTrue);
      await _tearDown(tester, h);
    });

    testWidgets(
      'only the selected tab carries an x; the sheet closes the others',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(3));
        await settle(tester);

        expect(find.bySemanticsLabel('Close tab'), findsOneWidget);

        await tester.longPress(_chip(1));
        await settle(tester);
        expect(find.text('Close other tabs'), findsOneWidget);
        expect(find.text('Close tabs to the right'), findsOneWidget);
        expect(find.text('Copy title'), findsOneWidget);

        await tester.tap(find.text('Close tabs to the right'));
        await settle(tester);

        expect([for (final t in h.openTabs.tabs) t.paneId], [_id(1)]);
        semantics.dispose();
        await _tearDown(tester, h);
      },
    );

    testWidgets('close others keeps the pressed tab', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(3));
      await settle(tester);

      await tester.longPress(_chip(2));
      await settle(tester);
      await tester.tap(find.text('Close other tabs'));
      await settle(tester);

      expect([for (final t in h.openTabs.tabs) t.paneId], [_id(2)]);
      expect(_active(h), _id(2));
      await _tearDown(tester, h);
    });
  });

  group('the strip', () {
    testWidgets(
      'scrolls sideways under a finger, keeps the selected tab in view, and a far tab opens',
      (tester) async {
        final h = await _harness(panes: 12);
        for (var i = 1; i <= 12; i++) {
          h.openTabs.open(_machine, _id(i));
        }
        await _pump(tester, h, home: const PaneHostScreen());
        final strip = tester.getRect(find.byType(TabStrip));
        expect(
          strip.contains(tester.getCenter(_chip(12))),
          isTrue,
          reason: 'the selected (last) tab is on screen when the host opens',
        );
        expect(
          find.byType(TabsTray),
          findsNothing,
          reason: 'sideways is not a pull-down',
        );
        expect(
          tester.getCenter(_chip(1)).dx,
          lessThan(0),
          reason: 'the first tab is off to the left',
        );

        await tester.drag(find.byType(TabStrip), const Offset(900, 0));
        await settle(tester);
        expect(find.byType(TabsTray), findsNothing);
        expect(
          tester.getCenter(_chip(1)).dx,
          greaterThan(0),
          reason: 'scrolled back to the first',
        );

        await tester.tap(_chip(1));
        await settle(tester);

        expect(_active(h), _id(1));
        expect(
          tester
              .getRect(find.byType(TabStrip))
              .contains(tester.getCenter(_chip(1))),
          isTrue,
        );
        await _tearDown(tester, h);
      },
    );

    testWidgets('selecting a tab from the tray scrolls the strip to it', (
      tester,
    ) async {
      final h = await _harness(panes: 12);
      for (var i = 1; i <= 12; i++) {
        h.openTabs.open(_machine, _id(i));
      }
      await _pump(tester, h, home: const PaneHostScreen());

      h.openTabs.activate(const TabRef(_machine, 'w1:p2').key);
      await settle(tester);

      expect(
        tester
            .getRect(find.byType(TabStrip))
            .contains(tester.getCenter(_chip(2))),
        isTrue,
      );
      await _tearDown(tester, h);
    });
  });

  group('what a tab keeps while hidden', () {
    testWidgets('scroll position, history and the draft survive a switch', (
      tester,
    ) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await settle(tester);
      await _show(tester, 1);

      // Scroll back up in tab 1 and write half a message.
      await tester.drag(find.byType(TerminalView), const Offset(0, 400));
      await settle(tester);
      final offset = _scrollOffset(tester);
      await tester.enterText(find.byType(TextField), 'half a mess');
      await tester.pump();

      await _show(tester, 2);
      expect(
        find.text('half a mess'),
        findsNothing,
        reason: 'tab 2 has its own composer',
      );
      await _show(tester, 1);

      expect(
        _scrollOffset(tester),
        offset,
        reason: 'scrolled where it was left',
      );
      expect(find.text('half a mess'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets(
      'a hidden tab does not read; it reads again as soon as it is shown',
      (tester) async {
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await settle(tester);
        final hiddenBefore = _reads(h, 1);
        expect(
          hiddenBefore,
          greaterThan(0),
          reason: 'it was read while visible',
        );

        // Busy output on both panes, a long time passing (the fallback poll is 4 s).
        for (var i = 0; i < 5; i++) {
          for (final n in [1, 2]) {
            h.transports[_machine]!.emit({
              'event': 'pane_updated',
              'data': {
                'pane': {
                  'pane_id': _id(n),
                  'workspace_id': 'w1',
                  'tab_id': 'w1:t1',
                },
              },
            });
          }
          await tester.pump(const Duration(seconds: 3));
        }
        expect(_reads(h, 1), hiddenBefore, reason: 'tab 1 is hidden');
        expect(
          _reads(h, 2),
          greaterThan(2),
          reason: 'tab 2 is visible and busy',
        );

        await _show(tester, 1);

        expect(_reads(h, 1), hiddenBefore + 1, reason: 'one refresh on show');
        await _tearDown(tester, h);
      },
    );

    testWidgets(
      'only the tabs shown recently stay alive; the oldest rebuilds from a read',
      (tester) async {
        final h = await _harness(panes: 4);
        h.openTabs
          ..open(_machine, _id(1))
          ..open(_machine, _id(2))
          ..open(_machine, _id(3))
          ..open(_machine, _id(4));
        await _pump(tester, h, home: const PaneHostScreen(maxLive: 2));
        // Opened 4 first, visit 3, 2, then 1: 4 is the least recently shown.
        h.openTabs.activate(
          h.openTabs.tabs.firstWhere((t) => t.paneId == _id(3)).key,
        );
        await settle(tester);
        h.openTabs.activate(
          h.openTabs.tabs.firstWhere((t) => t.paneId == _id(2)).key,
        );
        await settle(tester);

        expect(find.byType(PaneScreen, skipOffstage: false), findsNWidgets(2));
        final before = _reads(h, 3);

        // Tab 3 was shown more recently than 4 (dropped); showing 4 drops 3 or 2.
        h.openTabs.activate(
          h.openTabs.tabs.firstWhere((t) => t.paneId == _id(4)).key,
        );
        await settle(tester);
        expect(find.byType(PaneScreen, skipOffstage: false), findsNWidgets(2));
        expect(
          _reads(h, 4),
          greaterThan(0),
          reason: 'rebuilt from a fresh read',
        );

        // 2 was the least recently shown of 2 and 3: gone; 3 is still alive.
        h.openTabs.activate(
          h.openTabs.tabs.firstWhere((t) => t.paneId == _id(3)).key,
        );
        await settle(tester);
        expect(find.byType(PaneScreen, skipOffstage: false), findsNWidgets(2));
        expect(
          _reads(h, 3),
          before + 1,
          reason: 'alive: one refresh on show, no rebuild read',
        );
        await _tearDown(tester, h);
      },
    );

    testWidgets('the wrap setting follows the visible tab', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await settle(tester);
      await _show(tester, 1);

      await tester.tap(find.byTooltip('Wrap lines to screen'));
      await settle(tester);
      await _show(tester, 2);

      final reads = [
        for (final c in h.transports[_machine]!.calls)
          if (c.$1 == 'pane.read' &&
              c.$2['pane_id'] == _id(2) &&
              c.$2['lines'] == 300)
            c.$2['source'],
      ];
      expect(
        reads.last,
        'recent_unwrapped',
        reason: 'the other tab reads like the first now',
      );
      await _tearDown(tester, h);
    });
  });

  group('attention', () {
    Future<void> change(
      WidgetTester tester,
      UiHarness h,
      int i,
      String status,
    ) async {
      h.transports[_machine]!.snapshot = _snapshot([
        for (var n = 1; n <= 3; n++) _pane(n, n == i ? status : 'working'),
      ]);
      h.transports[_machine]!.emit({'event': 'pane.agent_status_changed'});
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('a background tab that needs you is marked until it is shown', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final h = await _harness(status: 'working');
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await settle(tester);
      expect(
        find.bySemanticsLabel(RegExp('Changed while hidden')),
        findsNothing,
      );

      await change(tester, h, 1, 'blocked');

      expect(
        find.bySemanticsLabel(RegExp('Changed while hidden')),
        findsOneWidget,
      );
      expect(h.openTabs.hasAttention(h.openTabs.tabs.first.key), isTrue);
      expect(
        find.bySemanticsLabel('All tabs, 2 open, some changed'),
        findsOneWidget,
      );

      await _show(tester, 1);

      expect(
        find.bySemanticsLabel(RegExp('Changed while hidden')),
        findsNothing,
      );
      expect(find.bySemanticsLabel('All tabs, 2 open'), findsOneWidget);
      semantics.dispose();
      await _tearDown(tester, h);
    });

    testWidgets('the tab on screen is never marked', (tester) async {
      final h = await _harness(status: 'working');
      await _pump(tester, h);
      await _openFromHome(tester, 1);

      await change(tester, h, 1, 'done');

      expect(h.openTabs.attentionCount, 0);
      await _tearDown(tester, h);
    });
  });

  group('tray', () {
    testWidgets(
      'opens from the count button, lists every tab, and a tap switches',
      (tester) async {
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(3));
        await settle(tester);
        expect(find.byType(TabsTray), findsNothing);

        await tester.tap(find.byType(TabCountButton));
        await settle(tester);

        expect(find.byType(TabsTray), findsOneWidget);
        for (var i = 1; i <= 3; i++) {
          expect(
            find.descendant(
              of: find.byType(TabsTray),
              matching: find.text('task $i'),
            ),
            findsOneWidget,
          );
        }
        expect(find.text('Open another agent'), findsOneWidget);
        // Each card shows the last rows of its pane.
        expect(
          find.descendant(
            of: find.byType(TabsTray),
            matching: find.text('line 199 of the output'),
          ),
          findsNWidgets(3),
        );

        await tester.tap(
          find.descendant(
            of: find.byType(TabsTray),
            matching: find.text('task 1'),
          ),
        );
        await settle(tester);

        expect(find.byType(TabsTray), findsNothing);
        expect(_active(h), _id(1));
        await _tearDown(tester, h);
      },
    );

    testWidgets(
      'pulling the strip down opens it; back closes it before leaving',
      (tester) async {
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);

        await tester.drag(find.byType(TabStrip), const Offset(0, 80));
        await settle(tester);
        expect(find.byType(TabsTray), findsOneWidget);

        await tester.tap(find.byTooltip('Back'));
        await settle(tester);
        expect(
          find.byType(TabsTray),
          findsNothing,
          reason: 'the first back closes the tray',
        );
        expect(find.byType(PaneHostScreen), findsOneWidget);

        await tester.tap(find.byTooltip('Back'));
        await settle(tester);
        expect(find.byType(PaneHostScreen), findsNothing);
        await _tearDown(tester, h);
      },
    );

    testWidgets(
      'x on a card closes that tab; the last card leaves for the board',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await settle(tester);
        await tester.tap(find.byType(TabCountButton));
        await settle(tester);

        await tester.tap(find.bySemanticsLabel('Close tab task 1'));
        await settle(tester);

        expect([for (final t in h.openTabs.tabs) t.paneId], [_id(2)]);
        expect(
          find.byType(TabsTray),
          findsOneWidget,
          reason: 'the tray stays open',
        );

        await tester.tap(find.text('Open another agent'));
        await settle(tester);

        expect(find.byType(PaneHostScreen), findsNothing);
        expect(h.openTabs.length, 1, reason: 'tabs wait for the next visit');
        semantics.dispose();
        await _tearDown(tester, h);
      },
    );

    testWidgets('previews are only read while the tray is open', (
      tester,
    ) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await settle(tester);
      expect(_reads(h, 1, lines: _previewLines) + _reads(h, 2, lines: _previewLines), 0);

      await tester.tap(find.byType(TabCountButton));
      await settle(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(_reads(h, 1, lines: _previewLines), greaterThan(0));
      expect(_reads(h, 2, lines: _previewLines), greaterThan(0));

      await tester.tapAt(const Offset(200, 800)); // the scrim
      await settle(tester);
      expect(find.byType(TabsTray), findsNothing);
      final reads = _reads(h, 1, lines: _previewLines) + _reads(h, 2, lines: _previewLines);

      await tester.pump(const Duration(seconds: 60));

      expect(
        _reads(h, 1, lines: _previewLines) + _reads(h, 2, lines: _previewLines),
        reads,
        reason: 'closing the tray released every watcher',
      );
      await _tearDown(tester, h);
    });

    testWidgets('a tray with one tab', (tester) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);

      await tester.tap(find.byType(TabCountButton));
      await settle(tester);

      expect(find.byType(TabsTray), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _tearDown(tester, h);
    });
  });

  group('swipe on the terminal', () {
    Future<UiHarness> twoTabs(WidgetTester tester, {bool wrap = true}) async {
      final h = await _harness();
      await h.terminalSettings.setWrap(wrap);
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await settle(tester);
      await _show(tester, 1);
      return h;
    }

    const panelFrom = Offset(300, 400);

    testWidgets('a swipe left shows the next tab, right the previous', (
      tester,
    ) async {
      final h = await twoTabs(tester);

      await _swipe(tester, from: panelFrom, by: const Offset(-160, 0));
      expect(_active(h), _id(2));

      await _swipe(tester, from: panelFrom, by: const Offset(160, 4));
      expect(_active(h), _id(1));
      await _tearDown(tester, h);
    });

    testWidgets(
      'with wrap off the terminal scrolls sideways instead: no tab switch',
      (tester) async {
        final h = await twoTabs(tester, wrap: false);

        await _swipe(tester, from: panelFrom, by: const Offset(-160, 0));

        expect(_active(h), _id(1));
        await _tearDown(tester, h);
      },
    );

    testWidgets('a vertical scroll, even a slanted one, never switches', (
      tester,
    ) async {
      final h = await twoTabs(tester);

      await _swipe(tester, from: panelFrom, by: const Offset(0, -240));
      await _swipe(tester, from: panelFrom, by: const Offset(-70, -200));
      await _swipe(tester, from: panelFrom, by: const Offset(-40, 300));

      expect(_active(h), _id(1));
      await _tearDown(tester, h);
    });

    testWidgets('a drag after holding still (a selection) never switches', (
      tester,
    ) async {
      final h = await twoTabs(tester);

      final g = await tester.startGesture(panelFrom);
      await tester.pump(const Duration(milliseconds: 600));
      for (var i = 1; i <= 8; i++) {
        await g.moveBy(
          const Offset(-20, 0),
          timeStamp: Duration(milliseconds: 600 + i * 16),
        );
      }
      await g.up();
      await settle(tester);

      expect(_active(h), _id(1));
      await _tearDown(tester, h);
    });

    testWidgets('a slow crawl never switches', (tester) async {
      final h = await twoTabs(tester);

      await _swipe(
        tester,
        from: panelFrom,
        by: const Offset(-120, 0),
        over: const Duration(milliseconds: 1500),
      );

      expect(_active(h), _id(1));
      await _tearDown(tester, h);
    });

    testWidgets('a tap and a short nudge never switch', (tester) async {
      final h = await twoTabs(tester);

      await tester.tapAt(panelFrom);
      await _swipe(tester, from: panelFrom, by: const Offset(-30, 0));

      expect(_active(h), _id(1));
      await _tearDown(tester, h);
    });

    testWidgets('a pinch (two fingers) never switches', (tester) async {
      final h = await twoTabs(tester);

      final a = await tester.startGesture(const Offset(200, 400));
      final b = await tester.startGesture(const Offset(320, 400));
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(-25, 0));
        await b.moveBy(const Offset(-25, 0));
        await tester.pump(const Duration(milliseconds: 20));
      }
      await a.up();
      await b.up();
      await settle(tester);

      expect(_active(h), _id(1));
      await _tearDown(tester, h);
    });

    testWidgets(
      'a swipe that starts at the screen edge is left to the system back gesture',
      (tester) async {
        final h = await twoTabs(tester);

        await _swipe(
          tester,
          from: const Offset(20, 400),
          by: const Offset(160, 0),
        );
        await _swipe(
          tester,
          from: const Offset(392, 400),
          by: const Offset(-160, 0),
        );

        expect(_active(h), _id(1));
        await _tearDown(tester, h);
      },
    );

    testWidgets('a swipe over the composer does not switch', (tester) async {
      final h = await twoTabs(tester);
      final composer = tester.getCenter(find.byType(TextField));

      await _swipe(tester, from: composer, by: const Offset(-160, 0));

      expect(_active(h), _id(1));
      await _tearDown(tester, h);
    });

    testWidgets('the strip, not the terminal, switches with wrap off', (
      tester,
    ) async {
      final h = await twoTabs(tester, wrap: false);

      await _show(tester, 2);

      expect(_active(h), _id(2));
      await _tearDown(tester, h);
    });
  });

  group('the detector alone', () {
    Future<List<int>> run(
      WidgetTester tester,
      Future<void> Function(WidgetTester) gesture, {
      bool enabled = true,
    }) async {
      final swipes = <int>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: TabSwipeDetector(
                enabled: enabled,
                onSwipe: swipes.add,
                child: const ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        ),
      );
      await gesture(tester);
      return swipes;
    }

    final centre = const Offset(400, 300);

    testWidgets('fires once per swipe, as soon as it is clear', (tester) async {
      final swipes = await run(tester, (t) async {
        final g = await t.startGesture(centre);
        await g.moveBy(const Offset(-40, 0));
        await g.moveBy(const Offset(-40, 2));
        await g.moveBy(const Offset(-40, 2));
        await g.moveBy(const Offset(-40, 2));
        await g.up();
      });

      expect(swipes, [1]);
    });

    testWidgets('disabled does nothing', (tester) async {
      final swipes = await run(
        tester,
        (t) => t.timedDragFrom(
          centre,
          const Offset(-150, 0),
          const Duration(milliseconds: 150),
        ),
        enabled: false,
      );

      expect(swipes, isEmpty);
    });

    testWidgets('going vertical first spoils the touch', (tester) async {
      final swipes = await run(tester, (t) async {
        final g = await t.startGesture(centre);
        await g.moveBy(const Offset(0, -40));
        await g.moveBy(const Offset(-200, 0));
        await g.up();
      });

      expect(swipes, isEmpty);
    });

    testWidgets(
      'a second finger spoils the touch, even after the first lifts',
      (tester) async {
        final swipes = await run(tester, (t) async {
          final a = await t.startGesture(centre);
          final b = await t.startGesture(centre + const Offset(30, 0));
          await a.moveBy(const Offset(-200, 0));
          await a.up();
          await b.moveBy(const Offset(-200, 0));
          await b.up();
        });

        expect(swipes, isEmpty);
      },
    );

    testWidgets('does not take the touch from what is under it', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 300,
              height: 300,
              child: TabSwipeDetector(
                enabled: true,
                onSwipe: (_) {},
                child: GestureDetector(
                  onTap: () => taps++,
                  child: const ColoredBox(color: Color(0xFF000000)),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tapAt(centre);

      expect(taps, 1);
    });
  });

  group('a tab whose pane or machine is gone', () {
    testWidgets('a closed pane keeps its tab, says so, and closes', (
      tester,
    ) async {
      final h = await _harness();
      await _pump(tester, h);
      await _openFromHome(tester, 1);
      final context = tester.element(find.byType(PaneHostScreen));
      await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
      await settle(tester);

      h.transports[_machine]!.snapshot = _snapshot([_pane(1, 'idle')]);
      h.transports[_machine]!.emit({'event': 'pane.closed'});
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));

      expect(
        find.textContaining('This pane was closed', findRichText: true),
        findsOneWidget,
      );
      expect(_chip(2), findsOneWidget, reason: 'the tab keeps its name');
      expect(
        find.descendant(
          of: find.byType(TabStrip),
          matching: find.byIcon(LucideIcons.squareX),
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byTooltip('Wrap lines to screen'),
        warnIfMissed: false,
      );
      await tester.tap(find.byType(TabCountButton));
      await settle(tester);
      expect(
        find.text('closed'),
        findsOneWidget,
        reason: 'its card says it is closed',
      );
      await _tearDown(tester, h);
    });

    testWidgets(
      'a removed machine shows a placeholder and the tab can be closed',
      (tester) async {
        final h = await _harness();
        await _pump(tester, h);
        await _openFromHome(tester, 1);
        final context = tester.element(find.byType(PaneHostScreen));
        await openPaneTab(context, h.fleet.connection(_machine)!, _id(2));
        await settle(tester);

        await tester.runAsync(() => h.machines.remove(_machine));
        await settle(tester);
        await tester.runAsync(h.fleet.settled);
        await settle(tester);

        expect(find.text('This machine is no longer saved'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.tap(find.widgetWithText(GestureDetector, 'Close tab'));
        await settle(tester);
        expect(h.openTabs.length, 1);
        await _tearDown(tester, h);
      },
    );
  });

  group('worst case', () {
    testWidgets(
      'twelve tabs, long and Vietnamese titles, no overflow, strip scrolls to the active one',
      (tester) async {
        final h = await UiHarness.create([
          (
            profile: MachineProfile(
              id: _machine,
              label: 'box',
              host: 'h',
              username: 'u',
            ),
            snapshot: snapshotWith(
              [
                for (var i = 1; i <= 12; i++)
                  _pane(i, i.isEven ? 'working' : 'blocked'),
              ],
              title: (id) => id.endsWith('p3')
                  ? 'Sửa lỗi đăng nhập và cập nhật tài liệu hướng dẫn cho người dùng mới'
                  : 'a very long task title number ${id.split('p').last} that goes on and on',
            ),
          ),
        ]);
        for (var i = 1; i <= 12; i++) {
          h.openTabs.open(_machine, _id(i));
        }
        await _pump(tester, h, home: const PaneHostScreen());

        expect(tester.takeException(), isNull);
        expect(find.byType(TabStrip), findsOneWidget);
        expect(h.openTabs.length, 12);
        // The last tab is the selected one and is on screen.
        final box = tester.getRect(find.byType(TabStrip));
        expect(
          box.contains(
            tester.getCenter(find.bySemanticsLabel('Close tab').first),
          ),
          isTrue,
          reason: 'its x is visible',
        );
        await _tearDown(tester, h);
      },
    );
  });

  group('from the machine screen', () {
    testWidgets(
      'a pane row opens it as a tab; opening a second adds a tab, not a screen',
      (tester) async {
        final h = await _harness();
        await _pump(
          tester,
          h,
          home: MachineScreen(machine: h.fleet.connection(_machine)!),
        );

        await tester.tap(find.text('task 1'));
        await settle(tester);
        expect(find.byType(PaneHostScreen), findsOneWidget);
        expect(_active(h), _id(1));

        await tester.tap(find.byTooltip('Back'));
        await settle(tester);
        await tester.tap(find.text('task 2'));
        await settle(tester);

        expect(find.byType(PaneHostScreen), findsOneWidget);
        expect(h.openTabs.length, 2);
        expect(_active(h), _id(2));
        await tester.tap(find.byTooltip('Back'));
        await settle(tester);
        expect(
          find.byType(MachineScreen),
          findsOneWidget,
          reason: 'one back to where it came from',
        );
        await _tearDown(tester, h);
      },
    );
  });

  group('preview watchers', () {
    testWidgets(
      'the tray watches every open tab and releases them when it closes',
      (tester) async {
        final h = await BoardHarness.create([
          (
            profile: MachineProfile(
              id: _machine,
              label: 'box',
              host: 'h',
              username: 'u',
            ),
            snapshot: _snapshot([
              for (var i = 1; i <= 3; i++) _pane(i, 'idle'),
            ]),
          ),
        ]);
        for (var i = 1; i <= 3; i++) {
          h.openTabs.open(_machine, _id(i));
        }
        tester.view
          ..physicalSize = const Size(412, 892) * 2
          ..devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MultiProvider(
            providers: h.providers,
            child: MaterialApp(
              theme: AppTheme.dark(),
              home: const PaneHostScreen(),
            ),
          ),
        );
        await settle(tester);
        expect(
          h.previews.openCount,
          0,
          reason: 'nothing watches while the tray is shut',
        );

        await tester.tap(find.byType(TabCountButton));
        await settle(tester);
        expect(h.previews.openCount, 3);

        await tester.tap(
          find.bySemanticsLabel(RegExp('Close tab task 3')),
          warnIfMissed: false,
        );
        h.openTabs.close(const TabRef(_machine, 'w1:p3').key);
        await settle(tester);
        expect(
          h.previews.openCount,
          2,
          reason: 'a closed tab is no longer watched',
        );

        await tester.tapAt(const Offset(200, 780));
        await settle(tester);
        expect(find.byType(TabsTray), findsNothing);
        expect(
          h.previews.openCount,
          0,
          reason: 'closing the tray releases every watcher',
        );

        await tester.pumpWidget(const SizedBox());
        expect(h.previews.openCount, 0);
        h.dispose();
      },
    );

    testWidgets('leaving the screen with the tray open releases them too', (
      tester,
    ) async {
      final h = await BoardHarness.create([
        (
          profile: MachineProfile(
            id: _machine,
            label: 'box',
            host: 'h',
            username: 'u',
          ),
          snapshot: _snapshot([_pane(1, 'idle'), _pane(2, 'idle')]),
        ),
      ]);
      h.openTabs
        ..open(_machine, _id(1))
        ..open(_machine, _id(2));
      await tester.pumpWidget(
        MultiProvider(
          providers: h.providers,
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const PaneHostScreen(),
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(TabCountButton));
      await settle(tester);
      expect(h.previews.openCount, 2);

      await tester.pumpWidget(const SizedBox());

      expect(h.previews.openCount, 0);
      h.dispose();
    });
  });
}
