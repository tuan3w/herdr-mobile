import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;

// The permission dock on the smallest phone with the biggest text: the
// answers are what the person came for, so they stay pinned and in reach
// while the evidence (the command, the diff) scrolls above them.

String _line(int i) => 'final line$i = $i;';

FakeAgentSession _session() => FakeAgentSession(
  state: stateWith(
    turnActive: true,
    pending: [
      PendingPermission(
        7,
        permissionRequest(
          title: 'Edit lib/feature/parse.dart',
          kind: ToolKind.edit,
          rawInput: {'file_path': 'lib/feature/parse.dart', 'command': 'echo ${'Hà Nội Đà Nẵng ' * 250}'},
          content: [
            {
              'type': 'diff',
              'path': 'lib/feature/parse.dart',
              'oldText': '${[for (var i = 0; i < 30; i++) _line(i)].join('\n')}\nString parse(String s) => lower(s);\n',
              'newText':
                  '${[for (var i = 0; i < 30; i++) _line(i)].join('\n')}\nString parse(String s) => fold(normalize(s));\n',
            },
          ],
        ),
      ),
    ],
  ),
);

Future<void> _pump(WidgetTester tester, FakeAgentSession session, {required Size size, required double scale}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  // The status bar and the gesture bar take room a phone does not give back.
  tester.view.padding = const FakeViewPadding(top: 24 * 2, bottom: 20 * 2);
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: AgentSessionScreen(key: ObjectKey(session), session: session),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(Dwell.tapGuard);
}

void main() {
  // Real glyph metrics: the room the evidence gets depends on how tall the text is.
  setUpAll(loadAppFonts);

  testWidgets('at 320x640 and 1.6x text every answer is on screen and tappable, and the evidence scrolls', (
    tester,
  ) async {
    final session = _session();
    await _pump(tester, session, size: const Size(320, 640), scale: 1.6);
    expect(tester.takeException(), isNull);

    for (final label in const ['Allow once', 'Always allow', 'Reject', 'Cancel request']) {
      expect(find.text(label).hitTestable(), findsOneWidget, reason: '$label is under the finger without scrolling');
    }

    // The evidence is the part that scrolls: its header sits in a scroll view
    // that has more to show, and the answers are not inside it.
    final evidence = find.ancestor(of: find.text('Edit lib/feature/parse.dart'), matching: find.byType(Scrollable));
    expect(evidence, findsWidgets);
    final scrollable = tester.state<ScrollableState>(evidence.first);
    expect(scrollable.position.maxScrollExtent, greaterThan(0), reason: 'the diff does not fit above the answers');
    expect(
      find.descendant(of: evidence.first, matching: find.text('Reject')),
      findsNothing,
      reason: 'answers are outside the scroll',
    );
    // The command is kept in view on open, so the header has scrolled up out of
    // sight; a drag in the gutter beside the wash (not on a box with a scroll of
    // its own) brings it back.
    final before = scrollable.position.pixels;
    final room = tester.getRect(evidence.first);
    await tester.dragFrom(Offset(room.left + 8, room.center.dy), const Offset(0, 80));
    await tester.pump();
    expect(scrollable.position.pixels, lessThan(before));

    await tester.tap(find.text('Reject'));
    await tester.pump();
    expect(session.permissionAnswers.single.$1, 7);
  });

  testWidgets('the command being approved is in front of the person even when the evidence has to scroll', (
    tester,
  ) async {
    // The dock states that the command is always visible: with the answers
    // pinned, what scrolls out of the room is the question and what the agent
    // said, not the command.
    final session = FakeAgentSession(
      state: stateWith(
        items: [agentMsg('a1', 'I will move the call below normalize and add a regression test for Hà Nội.')],
        turnActive: true,
        pending: [
          PendingPermission(7, permissionRequest(rawInput: {'command': 'git status --short'})),
        ],
      ),
    );
    await _pump(tester, session, size: const Size(320, 640), scale: 1.6);
    final command = find.text('git status --short');
    expect(command, findsOneWidget);
    // The header is only in the evidence's own scroll view (the command box has one inside it).
    final room = tester.getRect(find.ancestor(of: find.text('Run command'), matching: find.byType(Scrollable)).first);
    final text = tester.getRect(command);
    expect(text.top, greaterThanOrEqualTo(room.top), reason: 'not scrolled out above');
    expect(text.bottom, lessThanOrEqualTo(room.bottom), reason: 'not hidden behind the answers');
  });

  testWidgets('a plan being approved starts in view, not behind its question', (tester) async {
    final session = FakeAgentSession(
      state: stateWith(
        // What the agent said above the plan takes room the plan needs.
        items: [agentMsg('a1', 'I have a plan for the parser and I would like your approval before I start.')],
        turnActive: true,
        pending: [
          PendingPermission(
            7,
            permissionRequest(
              title: 'Approve Plan',
              rawInput: {'plan': '# Fix the parser\n\nMove the call below normalize.\n${'\nA step\n' * 60}'},
            ),
          ),
        ],
      ),
    );
    await _pump(tester, session, size: const Size(320, 640), scale: 1.6);
    final title = find.textContaining('Fix the parser', findRichText: true);
    expect(title, findsOneWidget);
    final room = tester.getRect(find.ancestor(of: find.text('Approve Plan'), matching: find.byType(Scrollable)).first);
    final rect = tester.getRect(title);
    expect(rect.top, greaterThanOrEqualTo(room.top), reason: 'the plan starts at the top of the evidence');
    expect(rect.top, lessThan(room.bottom), reason: 'and its first line is on screen');
  });
}
