// The composer's field and the round buttons inside it: whatever the text
// size, the buttons are centred on the field's one line, sit the same distance
// from the edge on both sides and from the top and bottom, and the field's
// corner is concentric with them. (At a larger font the field grows; the
// buttons used to stay glued to its bottom edge and look low.)
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';

Finder get _field => find.ancestor(
  of: find.byType(TextField),
  matching: find.byWidgetPredicate(
    (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).borderRadius != null,
  ),
);

void main() {
  for (final scale in [1.0, 1.1, 1.3, 1.6]) {
    testWidgets('buttons are centred in the field and its corner is concentric, text x$scale', (tester) async {
      tester.view
        ..physicalSize = const Size(412, 892) * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final session = FakeAgentSession(state: stateWith(items: [userMsg('u1', 'go')]));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) =>
              MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: AgentSessionScreen(key: ObjectKey(session), session: session),
        ),
      );
      await tester.pump(tapGuard);

      final field = tester.getRect(_field.first);
      final decoration = (tester.widget<Container>(_field.first).decoration! as BoxDecoration);
      final radius = (decoration.borderRadius! as BorderRadius).topLeft.x;
      final send = tester.getRect(find.byKey(const ValueKey('send')));
      // The attach button is the first button in the field, 44 dp square.
      final attach = tester.getRect(find.bySemanticsLabel('Attach'));

      // Centred on the field.
      expect(send.center.dy, closeTo(field.center.dy, 0.6), reason: 'send is centred');
      expect(attach.center.dy, closeTo(field.center.dy, 0.6), reason: 'attach is centred');
      // The same distance from the outer edge on both sides, and from the
      // top: the disc is 36 dp inside its 44 dp target.
      const disc = 36.0;
      final left = attach.center.dx - disc / 2 - field.left;
      final right = field.right - (send.center.dx + disc / 2);
      final top = send.center.dy - disc / 2 - field.top;
      expect(left, closeTo(right, 0.6), reason: 'the same gap on both sides');
      expect(top, closeTo(left, 0.6), reason: 'the same gap above as at the sides');
      // A stadium: the corner is the disc's radius plus that gap.
      expect(radius, closeTo(disc / 2 + left, 0.6), reason: 'concentric corner');
    });
  }
}
