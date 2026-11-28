import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_overview.dart';
import 'package:herdr_mobile/ui/features/agent_session/tool_rows.dart' show DiffPanel;

import '../support/fake_agent_session.dart';
import '../support/turn_fixtures.dart';

// The overview lists a few changed files and then says how many more there
// are: `N more`, once. Each tap on it shows the next sixteen.

void main() {
  Future<void> open(WidgetTester tester, int files) async {
    final session = FakeAgentSession(
      state: stateWith(
        items: [
          userAt('u', 'Rename everything', 0),
          for (var i = 0; i < files; i++) editAt('e$i', '/home/dev/app/lib/f$i.dart', 10 + i),
        ],
      ),
    );
    tester.view.physicalSize = const Size(412, 2400) * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                GestureDetector(onTap: () => showSessionOverview(context, session), child: const Text('open')),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('the rest of the changed files are counted once: `N more`, never `N more more`', (tester) async {
    await open(tester, 40);
    expect(find.text('32 more'), findsOneWidget, reason: '40 files, 8 shown');
    expect(find.textContaining('more more'), findsNothing);

    await tester.tap(find.text('32 more'));
    await tester.pump();
    expect(find.text('16 more'), findsOneWidget, reason: 'sixteen more shown, 16 still behind it');
    expect(find.textContaining('more more'), findsNothing);

    await tester.tap(find.text('16 more'));
    await tester.pump();
    expect(find.textContaining(RegExp(r'\d+ more')), findsNothing, reason: 'everything is shown');
  });

  testWidgets('one file over the limit says `1 more`', (tester) async {
    await open(tester, 9);
    expect(find.text('1 more'), findsOneWidget);
  });

  testWidgets('a tap on a changed file opens its diff, and another closes it', (tester) async {
    await open(tester, 3);
    expect(find.byType(DiffPanel), findsNothing);
    await tester.tap(find.textContaining('f1.dart', findRichText: true).first);
    await tester.pump();
    expect(find.byType(DiffPanel), findsOneWidget);
    await tester.tap(find.textContaining('f1.dart', findRichText: true).first);
    await tester.pump();
    expect(find.byType(DiffPanel), findsNothing);
  });
}
