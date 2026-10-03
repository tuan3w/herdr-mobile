// Worst-case data through the real screens. Overflow, clipping and layout
// exceptions fail these tests automatically (flutter_test treats them as errors).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/shot.dart' show loadAppFonts;
import 'ui_harness.dart';

MachineProfile _machine(String id, String label, {String host = 'h.example'}) =>
    MachineProfile(
      id: id,
      label: label,
      host: host,
      username: 'bartholomew.fitzgerald',
    );

/// Realistic worst cases, spread across rows rather than stacked in one:
/// long unbreakable names, one-letter names, CJK, RTL, emoji, empty strings.
const _titles = <String>[
  'Refactor the webhook retry handling and keep idempotency keys stable across all three payment providers 🚀',
  'إصلاح اختبارات الدفع المتقطعة في خدمة الفواتير',
  '重构支付网关的重试逻辑,并保持三个支付提供商的幂等性',
  'a',
  '',
  '⠋', // nothing but a spinner frame: cleans to an empty title
  'https://github.com/example-organisation/very-long-repository-name/pull/12345/files#diff-0123456789abcdef',
];

const _cwds = <String>[
  '/home/dev/code/a-very-long-directory-name-that-keeps-going-and-going-forever-and-ever',
  '/',
  '/home/dev/日本語のプロジェクト',
  '/srv/x',
];

const _workspaces = <({String id, String label})>[
  (id: 'w1', label: 'payments-api-gateway-v2-migration-branch-feature-flags-rollout'),
  (id: 'w2', label: ''),
  (id: 'w3', label: 'ж'),
];

List<Pane> _panes(int count) => [
      for (var i = 0; i < count; i++)
        (
          id: 'w${i % 3 + 1}:p${i + 1}',
          ws: 'w${i % 3 + 1}',
          agent: i % 5 == 4 ? 'a-rather-long-agent-name-from-a-plugin' : 'claude',
          status: const ['blocked', 'working', 'done', 'idle', 'unknown'][i % 5],
        ),
    ];

Future<UiHarness> _worstCase({int agents = 14}) => UiHarness.create([
      (
        profile: _machine('a',
            'build-server-eu-west-2-production-primary-gpu-cluster-0042',
            host: 'ip-10-0-143-201.eu-west-2.compute.internal'),
        snapshot: snapshotWith(
          _panes(agents),
          workspaces: _workspaces,
          title: (id) => _titles[id.hashCode.abs() % _titles.length],
          cwd: (id) => _cwds[id.hashCode.abs() % _cwds.length],
        ),
      ),
      (
        profile: _machine('b', 'x'), // one-letter machine name
        snapshot: snapshotWith(_panes(2)),
      ),
      (
        profile: _machine('c', '🚀 日本語のマシン'),
        snapshot: snapshotWith(const []), // online but empty
      ),
    ]);

void main() {
  setUpAll(loadAppFonts);

  for (final (width, scale) in [(360.0, 1.0), (320.0, 1.0), (320.0, 2.0)]) {
    group('${width.toInt()}dp at ${scale}x text', () {
      testWidgets('agents board survives worst-case data', (tester) async {
        final h = await _worstCase();
        await pumpUi(tester, h, width: width, textScale: scale);

        expect(find.byType(ListRow), findsWidgets);
        // Walk the whole list so every row is built and laid out.
        final list = find.byType(CustomScrollView).first;
        for (var i = 0; i < 12; i++) {
          await tester.drag(list, const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await teardownUi(tester, h);
      });

      testWidgets('machines list and machine detail survive worst-case data',
          (tester) async {
        final h = await _worstCase();
        await pumpUi(tester, h, width: width, textScale: scale);

        await tester.tap(find.byIcon(LucideIcons.server));
        await settle(tester);
        expect(find.textContaining('build-server-eu-west-2'), findsOneWidget);
        expect(find.text('x'), findsWidgets);

        await tester.tap(find.textContaining('build-server-eu-west-2'));
        await settle(tester);
        expect(find.textContaining('payments-api-gateway'), findsWidgets);
        for (var i = 0; i < 6; i++) {
          await tester.drag(find.byType(CustomScrollView).last, const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await teardownUi(tester, h);
      });
    });
  }

  testWidgets('120 agents build lazily, not all at once', (tester) async {
    final h = await _worstCase(agents: 120);
    await pumpUi(tester, h);

    // A phone shows a handful. Building all 120 up front is the stutter
    // break-ui warns about for unpaginated lists.
    expect(find.byType(ListRow).evaluate().length, lessThan(30));
    await teardownUi(tester, h);
  });

  group('states', () {
    testWidgets('no machines: an inviting empty state, not a blank screen',
        (tester) async {
      final h = await UiHarness.create(const []);
      await pumpUi(tester, h);

      expect(find.text('Add your first machine'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('a machine with no agents says so', (tester) async {
      final h = await UiHarness.create([
        (profile: _machine('a', 'solo'), snapshot: snapshotWith(const [])),
      ]);
      await pumpUi(tester, h);

      expect(find.text('No agents running'), findsOneWidget);
      await teardownUi(tester, h);
    });

    testWidgets('losing the network says so instead of showing stale data as live',
        (tester) async {
      final h = await UiHarness.create([
        (
          profile: _machine('a', 'solo'),
          snapshot: snapshotWith(_panes(3), title: (_) => 'Fix the tests'),
        ),
      ]);
      await pumpUi(tester, h);
      expect(find.textContaining('No network'), findsNothing);
      expect(
          tester.widgetList<ListRow>(find.byType(ListRow)).any((r) => r.dim), isFalse);

      h.network.goOffline();
      await settle(tester);

      expect(find.textContaining('No network'), findsWidgets);
      expect(
          tester.widgetList<ListRow>(find.byType(ListRow)).every((r) => r.dim), isTrue,
          reason: 'rows keep their data but are marked stale');
      await teardownUi(tester, h);
    });
  });

  testWidgets('every agent row tells screen readers its status', (tester) async {
    final h = await UiHarness.create([
      (
        profile: _machine('a', 'solo'),
        snapshot: snapshotWith(const [
          (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
        ], title: (_) => 'Needs a decision'),
      ),
    ]);
    final semantics = tester.ensureSemantics();
    await pumpUi(tester, h);

    expect(tester.getSemantics(find.byType(ListRow).first).label, contains('Needs you'));
    semantics.dispose();
    await teardownUi(tester, h);
  });
}
