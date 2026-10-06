import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/glyphs.dart';
import 'package:herdr_mobile/ui/core/rows.dart';
import 'package:herdr_mobile/ui/core/status_panel.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

Future<void> pumpCore(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  double width = 412,
  double height = 892,
}) async {
  tester.view
    ..physicalSize = Size(width, height) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
      home: Scaffold(body: child),
    ),
  );
}

/// WCAG contrast ratio.
double contrast(Color a, Color b) {
  double lum(Color c) {
    double ch(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
  }

  final la = lum(a), lb = lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('design tokens', () {
    for (final ds in [Ds.paper, Ds.ink]) {
      final name = ds.isDark ? 'ink' : 'paper';
      test('$name text tiers reach 4.5:1 on every surface', () {
        for (final bg in [ds.bg, ds.surface, ds.fill]) {
          for (final c in [ds.text, ds.textSecondary, ds.textMuted, ds.accentText, ds.blockedText, ds.dangerText]) {
            expect(contrast(c, bg), greaterThanOrEqualTo(4.5), reason: '$c on $bg');
          }
        }
      });

      test('$name status text holds on its own tint', () {
        for (final base in [ds.bg, ds.surface]) {
          for (final (text, hue) in [(ds.blockedText, ds.blocked), (ds.dangerText, ds.danger)]) {
            final tint = Color.alphaBlend(hue.withValues(alpha: StatusTint.fillAlpha), base);
            expect(contrast(text, tint), greaterThanOrEqualTo(4.5), reason: '$text on tint of $hue');
          }
        }
      });

      test('$name icons and status shapes reach 3:1, marks reach 3:1 on them', () {
        for (final c in [ds.textTertiary, ds.blocked, ds.working, ds.done]) {
          expect(contrast(c, ds.bg), greaterThanOrEqualTo(3), reason: '$c on bg');
        }
        for (final c in [ds.blocked, ds.working, ds.done]) {
          expect(contrast(ds.onStatus, c), greaterThanOrEqualTo(3), reason: 'mark on $c');
        }
      });
    }
  });

  group('Collapse', () {
    testWidgets('keeps its child mounted while closing, then unmounts it', (tester) async {
      var open = true;
      late StateSetter set;
      await pumpCore(
        tester,
        StatefulBuilder(builder: (context, setState) {
          set = setState;
          return SingleChildScrollView(
            child: Collapse(open: open, child: const ListRow(title: 'row one')),
          );
        }),
      );
      expect(find.text('row one'), findsOneWidget);
      final full = tester.getSize(find.byType(ListRow)).height;

      set(() => open = false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      // Mid-flight: still there, partly collapsed, and inert.
      expect(find.text('row one'), findsOneWidget);
      expect(tester.getSize(find.byType(Collapse)).height, lessThan(full));
      expect(find.byType(ListRow).hitTestable(), findsNothing);

      await tester.pumpAndSettle();
      expect(find.text('row one'), findsNothing);
      expect(tester.getSize(find.byType(Collapse)).height, 0);
    });

    testWidgets('opens from closed and keeps its child alive when fully open', (tester) async {
      var open = false;
      late StateSetter set;
      await pumpCore(
        tester,
        StatefulBuilder(builder: (context, setState) {
          set = setState;
          return SingleChildScrollView(
            child: Collapse(open: open, child: const TextField(key: Key('field'))),
          );
        }),
      );
      expect(find.byKey(const Key('field')), findsNothing);

      set(() => open = true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      expect(find.byKey(const Key('field')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('field')), 'kept');
      await tester.pumpAndSettle();
      // The animation wrappers go away once open; the field must survive that.
      expect(find.text('kept'), findsOneWidget);
    });
  });

  group('semantics', () {
    testWidgets('a row reads as one merged node with each text once', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(
        tester,
        ListView(
          children: [
            ListRow(
              leading: const StatusGlyph(status: AgentStatus.blocked),
              title: 'Fix flaky retry test',
              subtitle: 'claude · solo',
              subtitle2: 'main · w1',
              trailing: const Icon(Icons.chevron_right),
              onTap: () {},
            ),
          ],
        ),
      );
      final node = tester.getSemantics(find.text('Fix flaky retry test'));
      for (final s in ['Fix flaky retry test', 'claude · solo', 'main · w1', AgentStatus.blocked.label]) {
        expect(RegExp(RegExp.escape(s)).allMatches(node.label).length, 1, reason: '"$s" in "${node.label}"');
      }
      expect(node.flagsCollection.isButton, isTrue);
      handle.dispose();
    });

    testWidgets('a row without a tap handler is not announced as a button', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(tester, ListView(children: const [ListRow(title: 'Static')]));
      expect(tester.getSemantics(find.text('Static')).flagsCollection.isButton, isFalse);
      handle.dispose();
    });

    testWidgets('icon-only and labelled controls announce their name once', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(
        tester,
        Column(children: [
          CircleButton(icon: Icons.add, tooltip: 'Add machine', onPressed: () {}),
          AppButton(label: 'Retry', onPressed: () {}, compact: true),
          AppChip(
            label: 'Needs you',
            count: 3,
            selected: true,
            leading: const StatusGlyph(status: AgentStatus.blocked, size: 14),
            onTap: () {},
          ),
        ]),
      );
      expect(find.bySemanticsLabel('Add machine'), findsOneWidget);
      expect(tester.getSemantics(find.text('Retry')).label, 'Retry');

      final chip = tester.getSemantics(find.text('Needs you'));
      expect(RegExp('Needs you').allMatches(chip.label).length, 1, reason: chip.label);
      expect(chip.flagsCollection.isSelected, Tristate.isTrue);
      handle.dispose();
    });

    testWidgets('a plain SectionLabel is a heading, not a disabled button', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(tester, const Column(children: [SectionLabel(label: 'Machine')]));
      final node = tester.getSemantics(find.text('Machine'));
      expect(node.flagsCollection.isHeader, isTrue);
      expect(node.flagsCollection.isButton, isFalse);
      handle.dispose();
    });

    testWidgets('tab bar reports the selected tab and a spoken badge', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(
        tester,
        Align(
          alignment: Alignment.bottomCenter,
          child: FloatingTabBar(
            index: 0,
            onChanged: (_) {},
            tabs: const [
              TabSpec(icon: Icons.list, label: 'Agents', badge: 2),
              TabSpec(icon: Icons.dns, label: 'Machines'),
            ],
          ),
        ),
      );
      final agents = tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Agents')));
      expect(agents.label, 'Agents, 2 need you');
      expect(agents.flagsCollection.isSelected, Tristate.isTrue);
      expect(
        tester.getSemantics(find.byKey(FloatingTabBar.tabKey('Machines'))).flagsCollection.isSelected,
        Tristate.isFalse,
      );
      handle.dispose();
    });

    testWidgets('a text field is named by its label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(
        tester,
        const Padding(padding: EdgeInsets.all(20), child: LabeledField(label: 'Username')),
      );
      final node = tester.getSemantics(find.byType(EditableText));
      expect(node.label, contains('Username'));
      expect(node.flagsCollection.isTextField, isTrue);
      handle.dispose();
    });
  });

  group('touch targets', () {
    for (final (name, build) in <(String, Widget Function(VoidCallback))>[
      ('AppChip', (t) => AppChip(label: 'Working', onTap: t)),
      ('compact AppButton', (t) => AppButton(label: 'Retry', compact: true, onPressed: t)),
      ('CircleButton', (t) => CircleButton(icon: Icons.add, tooltip: 'Add', onPressed: t)),
    ]) {
      testWidgets('$name hits at least 44x44 around its painted shape', (tester) async {
        var taps = 0;
        await pumpCore(tester, Center(child: build(() => taps++)));
        final size = tester.getSize(find.byType(PressBuilder));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
        final c = tester.getCenter(find.byType(PressBuilder));
        await tester.tapAt(c + Offset(0, size.height / 2 - 2));
        expect(taps, 1);
      });
    }

    testWidgets('Segmented options are 44 high and report selection', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(
        tester,
        Padding(
          padding: const EdgeInsets.all(20),
          child: Segmented<int>(
            value: 1,
            onChanged: (_) {},
            options: const [SegmentOption(1, 'Key'), SegmentOption(2, 'Password')],
          ),
        ),
      );
      expect(tester.getSize(find.byType(Segmented<int>)).height, 44);
      expect(tester.getSemantics(find.text('Key')).flagsCollection.isSelected, Tristate.isTrue);
      expect(tester.getSemantics(find.text('Password')).flagsCollection.isSelected, Tristate.isFalse);
      handle.dispose();
    });
  });

  group('SliverLargeTitle', () {
    Widget page(ScrollController c) => CustomScrollView(
          controller: c,
          slivers: [
            SliverLargeTitle(
              title: 'Agents',
              subtitle: const Text('3 agents'),
              bottomHeight: AppChip.height,
              bottom: Row(children: [AppChip(label: 'Working', onTap: () {})]),
            ),
            SliverList.builder(itemCount: 40, itemBuilder: (_, i) => SizedBox(height: 80, child: Text('item $i'))),
          ],
        );

    testWidgets('extent matches the pinned header; chips are not tappable once hidden', (tester) async {
      final c = ScrollController();
      addTearDown(c.dispose);
      await pumpCore(tester, page(c));

      final ctx = tester.element(find.byType(CustomScrollView));
      final extent = SliverLargeTitle.extent(ctx, hasSubtitle: true, bottomHeight: AppChip.height);
      expect(tester.getRect(find.text('item 0')).top, closeTo(extent, 1));
      expect(find.byType(AppChip).hitTestable(), findsOneWidget);

      c.jumpTo(400);
      await tester.pump();
      expect(find.byType(AppChip).hitTestable(), findsNothing);
    });

    testWidgets('chips slide away at full opacity while the title fades', (tester) async {
      final c = ScrollController();
      addTearDown(c.dispose);
      await pumpCore(tester, page(c));
      c.jumpTo(40);
      await tester.pump();
      bool faded(Finder of) => tester
          .widgetList<Opacity>(find.ancestor(of: of, matching: find.byType(Opacity)))
          .any((o) => o.opacity < 1);
      expect(faded(find.byType(AppChip)), isFalse);
      expect(faded(find.text('Agents').first), isTrue);
    });
  });

  group('ListRow', () {
    testWidgets('centres a small leading on the title line, not the whole block', (tester) async {
      await pumpCore(
        tester,
        ListView(children: const [
          ListRow(
            leading: StatusGlyph(status: AgentStatus.working, size: 18),
            title: 'Title',
            subtitle: 'a second line',
            subtitle2: 'and a third',
            divider: false,
          ),
        ]),
      );
      final glyph = tester.getCenter(find.byType(StatusGlyph)).dy;
      final title = tester.getCenter(find.text('Title')).dy;
      expect(glyph, closeTo(title, 1.5));
      // Text starts on the 64 grid line.
      expect(tester.getTopLeft(find.text('Title')).dx, 64);
    });

    testWidgets('wraps to two title lines by default', (tester) async {
      await pumpCore(tester, ListView(children: [ListRow(title: 'word ' * 40)]), width: 360);
      final text = find.text('word ' * 40);
      expect(tester.widget<Text>(text).maxLines, 2);
      expect(tester.getSize(text).height, greaterThan(30));
    });
  });

  group('LabeledField', () {
    testWidgets('an appearing error does not move the field below it', (tester) async {
      final key = GlobalKey<FormState>();
      await pumpCore(
        tester,
        Form(
          key: key,
          child: Column(children: [
            LabeledField(label: 'Host', validator: (v) => (v ?? '').isEmpty ? 'Required' : null),
            const LabeledField(key: Key('below'), label: 'Port'),
          ]),
        ),
      );
      final before = tester.getTopLeft(find.byKey(const Key('below'))).dy;
      key.currentState!.validate();
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(const Key('below'))).dy, before);
    });
  });

  group('StatusStrip', () {
    testWidgets('is a single ~48dp line with an action that stays tappable', (tester) async {
      var retried = 0;
      await pumpCore(
        tester,
        Padding(
          padding: const EdgeInsets.all(20),
          child: StatusStrip(
            color: Ds.paper.blocked,
            title: 'build-server',
            detail: 'Reconnecting…',
            action: AppButton(
              label: 'Retry',
              compact: true,
              kind: AppButtonKind.secondary,
              onPressed: () => retried++,
            ),
          ),
        ),
      );
      expect(tester.getSize(find.byType(StatusStrip)).height, inInclusiveRange(48, 56));
      await tester.tap(find.text('Retry'));
      expect(retried, 1);
    });
  });

  group('sheets', () {
    testWidgets('an open sheet restyles live when the theme flips', (tester) async {
      final mode = ValueNotifier(ThemeMode.light);
      addTearDown(mode.dispose);
      await tester.pumpWidget(
        ValueListenableBuilder(
          valueListenable: mode,
          builder: (context, m, _) => MaterialApp(
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            themeMode: m,
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: AppButton(
                    label: 'open',
                    onPressed: () => showActionSheet(
                      context,
                      actions: [SheetAction(label: 'Edit', icon: Icons.edit, onTap: () {})],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      Color sheetColor() => tester
          .widget<Material>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first)
          .color!;
      expect(sheetColor(), Ds.paper.surface);

      mode.value = ThemeMode.dark;
      await tester.pumpAndSettle();
      expect(sheetColor(), Ds.ink.surface);
    });
  });
}
