import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/create/machine_field.dart' show shortPath;

Future<void> _pump(WidgetTester tester, Widget child, {double width = 200}) async {
  tester.view
    ..physicalSize = Size(width, 400) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: AppTheme.light(), home: Scaffold(body: child)));
}

void main() {
  group('AppChip', () {
    const long = 'a-very-long-chip-label-that-cannot-possibly-fit-in-two-hundred-dp';

    testWidgets('given less room than its label wants, it ends in an ellipsis instead of overflowing', (tester) async {
      await _pump(tester, const Wrap(children: [AppChip(label: long)]));

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(AppChip)).width, lessThanOrEqualTo(200));
    });

    testWidgets('in a scrolling row it keeps its natural width (no Flexible under unbounded room)', (tester) async {
      await _pump(
        tester,
        const SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [AppChip(label: long, count: 3)]),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(AppChip)).width, greaterThan(200));
    });
  });

  group('short folder labels', () {
    test('keep the last two segments and never grow past the cap', () {
      expect(shortPath('/work/app'), 'work/app');
      expect(shortPath('/home/dev/work/payments-api'), '…/work/payments-api');
      expect(shortPath('/a-very-long-directory-name-that-keeps-going/and-going-and-going-and-going').length, lessThanOrEqualTo(26));
      expect(shortPath('/'), '');
    });
  });

  group('a pane the person renamed', () {
    Map<String, dynamic> json({String? label, String title = 'π > Fix the build'}) => {
          'pane_id': 'w1:p1',
          'workspace_id': 'w1',
          'tab_id': 'w1:t1',
          'terminal_title_stripped': title,
          'agent_status': 'idle',
          'label': ?label,
        };

    test('shows its own name instead of the program title', () {
      final pane = Pane.fromJson(json(label: ' builder '));

      expect(pane.title, 'builder');
      expect(pane.label, 'builder');
    });

    test('a blank or missing name falls back to the cleaned program title', () {
      for (final label in [null, '', '   ']) {
        final pane = Pane.fromJson(json(label: label));
        expect(pane.title, 'Fix the build', reason: '"$label"');
        expect(pane.label, isNull);
      }
    });

    test('survives the snapshot cache round trip, so the offline list shows it too', () {
      final pane = Pane.fromJson(json(label: 'Dự án 日本語'));

      final again = Pane.fromJson(pane.toJson());

      expect(again, pane);
      expect(again.title, 'Dự án 日本語');
    });

    test('renaming changes equality, so the list refreshes', () {
      expect(Pane.fromJson(json(label: 'a')) == Pane.fromJson(json(label: 'b')), isFalse);
    });
  });
}
