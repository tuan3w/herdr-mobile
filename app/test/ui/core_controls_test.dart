import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

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

      test('$name text reaches 4.5:1 on the switch: pill and capsule', () {
        // The capsule is `surface` on paper and `fillPressed` on ink (Segmented).
        final capsule = ds.isDark ? ds.fillPressed : ds.surface;
        for (final bg in [ds.fill, capsule]) {
          for (final c in [ds.text, ds.textSecondary]) {
            expect(contrast(c, bg), greaterThanOrEqualTo(4.5), reason: '$c on $bg');
          }
        }
        // An unchosen count sits on the pill, the chosen one on the capsule.
        expect(contrast(ds.textMuted, ds.fill), greaterThanOrEqualTo(4.5));
        expect(contrast(ds.textSecondary, capsule), greaterThanOrEqualTo(4.5));
        // The edge of a field is the only thing that says where to type.
        expect(contrast(ds.controlBorder, ds.surface), greaterThanOrEqualTo(3), reason: 'field edge');
      });

      test('$name status text holds on its own wash, pressed too', () {
        for (final base in [ds.bg, ds.surface]) {
          for (final (text, hue) in [(ds.blockedText, ds.blocked), (ds.dangerText, ds.danger)]) {
            for (final wash in [ds.wash(hue), ds.washPressed(hue)]) {
              final tint = Color.alphaBlend(wash, base);
              expect(contrast(text, tint), greaterThanOrEqualTo(4.5), reason: '$text on wash of $hue');
            }
          }
        }
      });

      test('$name a toast reads on the inverse surface', () {
        expect(contrast(ds.onInverse, ds.inverseSurface), greaterThanOrEqualTo(4.5));
        expect(contrast(ds.inverseAccent, ds.inverseSurface), greaterThanOrEqualTo(4.5));
        // A toast's kind mark sits on it as a shape.
        for (final c in [ds.done, ds.danger]) {
          expect(contrast(c, ds.inverseSurface), greaterThanOrEqualTo(3), reason: '$c on the toast');
        }
      });

      test('$name a selected tab, chip or segment reads on the accent wash', () {
        // The tab bar and sheets sit on surface, chips on bg, a segment on fill.
        for (final base in [ds.surface, ds.bg, ds.fill]) {
          for (final wash in [ds.accentWash, ds.accentWashPressed]) {
            final tint = Color.alphaBlend(wash, base);
            expect(contrast(ds.accentText, tint), greaterThanOrEqualTo(4.5), reason: 'accent text on $wash over $base');
          }
        }
      });

      test('$name a count badge reads: its number on its fill', () {
        expect(contrast(ds.onStatus, ds.blockedText), greaterThanOrEqualTo(4.5));
      });

      test('$name text holds on a pressed row', () {
        for (final base in [ds.bg, ds.surface]) {
          final pressed = Color.alphaBlend(ds.pressTint, base);
          for (final c in [ds.text, ds.textSecondary, ds.textMuted]) {
            expect(contrast(c, pressed), greaterThanOrEqualTo(4.5), reason: '$c on pressed $base');
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
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return SingleChildScrollView(
              child: Collapse(
                open: open,
                child: const ListRow(title: 'row one'),
              ),
            );
          },
        ),
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
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return SingleChildScrollView(
              child: Collapse(
                open: open,
                child: const TextField(key: Key('field')),
              ),
            );
          },
        ),
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
        Column(
          children: [
            CircleButton(icon: Icons.add, tooltip: 'Add machine', onPressed: () {}),
            AppButton(label: 'Retry', onPressed: () {}, compact: true),
            AppChip(
              label: 'Needs you',
              count: 3,
              selected: true,
              leading: const StatusGlyph(status: AgentStatus.blocked, size: 14),
              onTap: () {},
            ),
          ],
        ),
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

    testWidgets('a round button with a mark says what the mark means', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(
        tester,
        Center(
          child: CircleButton(
            icon: Icons.settings,
            tooltip: 'Settings',
            mark: true,
            markLabel: 'update available',
            onPressed: () {},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('circle-button-mark')), findsOneWidget);
      expect(find.bySemanticsLabel('Settings, update available'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a text field is named by its label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCore(
        tester,
        const Padding(
          padding: EdgeInsets.all(20),
          child: LabeledField(label: 'Username'),
        ),
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

    group('Segmented as the switch', () {
      Widget switchOf(int value, void Function(int) onChanged, {int kinds = 4}) => Padding(
        padding: const EdgeInsets.all(16),
        child: Segmented<int>(
          value: value,
          onChanged: onChanged,
          options: [for (var i = 0; i < kinds; i++) SegmentOption(i, 'Kind number $i', count: 10 + i)],
        ),
      );

      testWidgets('a tap on another option reports it, a tap on the chosen one does not', (tester) async {
        final got = <int>[];
        await pumpCore(tester, switchOf(0, got.add, kinds: 2));
        await tester.tap(find.text('Kind number 0'));
        await tester.tap(find.text('Kind number 1'));
        expect(got, [1]);
      });

      testWidgets('when the labels do not fit the row scrolls and the chosen option is in view', (tester) async {
        // The test font is wide: four long labels cannot share the width.
        await pumpCore(tester, switchOf(3, (_) {}));
        await tester.pumpAndSettle();
        final box = tester.getRect(find.byType(Segmented<int>));
        final chosen = tester.getRect(find.text('Kind number 3'));
        expect(chosen.left, greaterThanOrEqualTo(box.left));
        expect(chosen.right, lessThanOrEqualTo(box.right));
        // The others are still reachable by scrolling, not cut.
        await tester.ensureVisible(find.text('Kind number 0'));
        expect(tester.getRect(find.text('Kind number 0')).left, greaterThanOrEqualTo(box.left));
      });

      testWidgets('labels that fit share the width equally', (tester) async {
        await pumpCore(
          tester,
          Padding(
            padding: const EdgeInsets.all(16),
            child: Segmented<int>(
              value: 0,
              onChanged: (_) {},
              options: const [SegmentOption(0, 'Ab'), SegmentOption(1, 'Cd')],
            ),
          ),
        );
        final a = tester.getCenter(find.text('Ab')).dx;
        final b = tester.getCenter(find.text('Cd')).dx;
        final box = tester.getRect(find.byType(Segmented<int>));
        expect(b - a, closeTo(box.width / 2, 8));
      });

      /// The capsule under the chosen cell: `surface` on paper, `fillPressed` on ink.
      Finder capsule(Ds ds) => find.descendant(
        of: find.byType(Segmented<int>),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == (ds.isDark ? ds.fillPressed : ds.surface),
        ),
      );

      for (final brightness in Brightness.values) {
        testWidgets('the counts are readable on the pill and on the capsule (${brightness.name})', (tester) async {
          final ds = brightness == Brightness.dark ? Ds.ink : Ds.paper;
          await pumpCore(tester, switchOf(0, (_) {}, kinds: 2), brightness: brightness);
          await tester.pumpAndSettle();
          Color countColor(String s) => tester.widget<Text>(find.text(s)).style!.color!;
          // Kind 0 is chosen (count 10, on the capsule); kind 1 is not (count 11, on the pill).
          expect(contrast(countColor('10'), ds.isDark ? ds.fillPressed : ds.surface), greaterThanOrEqualTo(4.5));
          expect(contrast(countColor('11'), ds.fill), greaterThanOrEqualTo(4.5));
        });
      }

      testWidgets('a semantic label replaces what is spoken for that option', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpCore(
          tester,
          Padding(
            padding: const EdgeInsets.all(16),
            child: Segmented<int>(
              value: 0,
              onChanged: (_) {},
              options: const [
                SegmentOption(0, 'Pages', count: 3),
                SegmentOption(1, 'Servers', count: 2, semanticLabel: 'Servers, 2, running'),
              ],
            ),
          ),
        );
        expect(find.bySemanticsLabel('Servers, 2, running'), findsOneWidget);
        expect(find.bySemanticsLabel('Servers, 2'), findsNothing);
        expect(find.bySemanticsLabel('Pages, 3'), findsOneWidget);
        handle.dispose();
      });

      testWidgets('a rebuild does not pull the row back from where the person dragged it', (tester) async {
        Widget page(int bump) => Padding(
          padding: const EdgeInsets.all(16),
          child: Segmented<int>(
            value: 3,
            onChanged: (_) {},
            options: [for (var i = 0; i < 4; i++) SegmentOption(i, 'Kind number $i', count: 10 + i + bump)],
          ),
        );
        await pumpCore(tester, page(0));
        await tester.pumpAndSettle();
        final scrollable = find.descendant(of: find.byType(Segmented<int>), matching: find.byType(Scrollable));
        double offset() => tester.state<ScrollableState>(scrollable).position.pixels;
        final atChosen = offset();
        expect(atChosen, greaterThan(0));
        await tester.drag(find.byType(Segmented<int>), const Offset(400, 0));
        await tester.pumpAndSettle();
        final dragged = offset();
        expect(dragged, lessThan(atChosen));
        // A new asset arrives: same choice, new counts.
        await pumpCore(tester, page(1));
        await tester.pumpAndSettle();
        expect(offset(), dragged);
      });

      testWidgets('no options draws nothing', (tester) async {
        await pumpCore(tester, Segmented<int>(value: 0, onChanged: (_) {}, options: const []));
        expect(tester.takeException(), isNull);
        expect(tester.getSize(find.byType(Segmented<int>)), Size.zero);
      });

      testWidgets('a value that is none of the options shows no choice', (tester) async {
        final handle = tester.ensureSemantics();
        await pumpCore(
          tester,
          Padding(
            padding: const EdgeInsets.all(16),
            child: Segmented<int>(
              value: 9,
              onChanged: (_) {},
              options: const [SegmentOption(1, 'Key'), SegmentOption(2, 'Password')],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(capsule(Ds.paper), findsNothing);
        expect(tester.getSemantics(find.text('Key')).flagsCollection.isSelected, Tristate.isFalse);
        expect(tester.getSemantics(find.text('Password')).flagsCollection.isSelected, Tristate.isFalse);
        handle.dispose();
      });

      testWidgets('with no width to share it is as wide as its content', (tester) async {
        await pumpCore(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Segmented<int>(
                  value: 0,
                  onChanged: (_) {},
                  options: const [SegmentOption(0, 'Ab'), SegmentOption(1, 'Cd')],
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final box = tester.getRect(find.byType(Segmented<int>));
        expect(box.width, lessThan(200));
        expect(box.width, greaterThan(40));
        // Every label sits inside the pill, none cut.
        for (final s in ['Ab', 'Cd']) {
          final r = tester.getRect(find.text(s));
          expect(r.left, greaterThanOrEqualTo(box.left));
          expect(r.right, lessThanOrEqualTo(box.right));
        }
      });
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
          bottom: Row(
            children: [AppChip(label: 'Working', onTap: () {})],
          ),
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
      bool faded(Finder of) =>
          tester.widgetList<Opacity>(find.ancestor(of: of, matching: find.byType(Opacity))).any((o) => o.opacity < 1);
      expect(faded(find.byType(AppChip)), isFalse);
      expect(faded(find.text('Agents').first), isTrue);
    });
  });

  group('ListRow', () {
    testWidgets('centres a small leading on the title line, not the whole block', (tester) async {
      await pumpCore(
        tester,
        ListView(
          children: const [
            ListRow(
              leading: StatusGlyph(status: AgentStatus.working, size: 18),
              title: 'Title',
              subtitle: 'a second line',
              subtitle2: 'and a third',
            ),
          ],
        ),
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
          child: Column(
            children: [
              LabeledField(label: 'Host', validator: (v) => (v ?? '').isEmpty ? 'Required' : null),
              const LabeledField(key: Key('below'), label: 'Port'),
            ],
          ),
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
            action: AppButton(label: 'Retry', compact: true, kind: AppButtonKind.secondary, onPressed: () => retried++),
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

  group('AnswerChip', () {
    Widget chip({AnswerChipState state = AnswerChipState.rest, bool hold = true}) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnswerChip(
            key: const Key('mode'),
            label: 'Bypass permissions',
            detail: 'Runs every command without asking',
            reason: 'no checks',
            risk: AnswerRisk.gate,
            hold: hold,
            state: state,
            onTap: () {},
            onHeld: () {},
          ),
          const SizedBox(key: Key('below'), height: 10),
        ],
      ),
    );

    testWidgets('a held dangerous mode keeps its warning and its height under the finger', (tester) async {
      // Wide enough that no state's words wrap in the test font: the height
      // checked is the detail's.
      await pumpCore(tester, chip(), width: 800);
      final rest = tester.getRect(find.byKey(const Key('below'))).top;
      final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('mode'))));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Runs every command without asking'), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('below'))).top, rest, reason: 'nothing moves under the thumb');
      await gesture.up();
      await tester.pumpAndSettle();

      await pumpCore(tester, chip(state: AnswerChipState.primed), width: 800);
      expect(find.text('Runs every command without asking'), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('below'))).top, rest);
    });

    testWidgets('a held answer says so at rest; one that sends on a tap does not', (tester) async {
      await pumpCore(tester, chip());
      expect(find.text('Hold'), findsOneWidget, reason: 'a tap would not send it: the chip has to say');
      await pumpCore(tester, chip(hold: false));
      expect(find.text('Hold'), findsNothing);
    });

    testWidgets('a failed held answer says it needs a hold to retry; a tapped one says Retry', (tester) async {
      await pumpCore(tester, chip(state: AnswerChipState.failed));
      expect(find.textContaining('Hold to retry'), findsOneWidget);
      await pumpCore(tester, chip(state: AnswerChipState.failed, hold: false));
      expect(find.textContaining('Hold to retry'), findsNothing);
      expect(find.textContaining('Retry'), findsOneWidget);
    });

    testWidgets('a failed answer is marked as a failure, not with the caution a primed one shows', (tester) async {
      await pumpCore(tester, chip(state: AnswerChipState.primed));
      expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
      await pumpCore(tester, chip(state: AnswerChipState.failed));
      expect(find.byIcon(LucideIcons.circleAlert), findsOneWidget);
      expect(find.byIcon(LucideIcons.triangleAlert), findsNothing);
    });
  });

  group('bottom stack', () {
    testWidgets('a lane keeps its State through enter and exit', (tester) async {
      var inits = 0;
      final visible = ValueNotifier(false);
      addTearDown(visible.dispose);
      await pumpCore(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, v, _) => BottomStackTransition(
            visible: v,
            builder: (_) => _InitCounter(onInit: () => inits++),
          ),
        ),
      );
      visible.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(inits, 1);
      await tester.pumpAndSettle();
      expect(inits, 1, reason: 'the end of the enter must not rebuild the lane from scratch');

      // Out and back before it is gone: still the same lane.
      visible.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      visible.value = true;
      await tester.pumpAndSettle();
      expect(inits, 1);
    });
  });
}

class _InitCounter extends StatefulWidget {
  const _InitCounter({required this.onInit});
  final VoidCallback onInit;
  @override
  State<_InitCounter> createState() => _InitCounterState();
}

class _InitCounterState extends State<_InitCounter> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox(height: 56, width: 200);
}
