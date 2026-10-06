// A transcript that is a saved copy: it paints at once, says so quietly in the
// link strip, and asks nothing of the person until the keeper's live attach
// has confirmed it. Plus the finger-down hold on a board row.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show AgentStatus;
import 'package:herdr_mobile/ui/core/glyphs.dart';
import 'package:herdr_mobile/ui/core/status_panel.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_dock.dart';
import 'package:herdr_mobile/ui/features/agent_session/saved_copy.dart';
import 'package:herdr_mobile/ui/features/agents/preconnect_tap.dart';
import 'package:provider/provider.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';

import '../support/fake_agent_session.dart';

Future<void> _pump(WidgetTester tester, FakeAgentSession session) async {
  tester.view.physicalSize = const Size(824, 1784);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: AppTheme.light(), home: AgentSessionScreen(key: ObjectKey(session), session: session)),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

Finder _strip(String text) =>
    find.descendant(of: find.byType(StatusStrip), matching: find.textContaining(text, findRichText: true));

void main() {
  group('the session screen over a saved copy', () {
    FakeAgentSession copy({List<PendingRequest> pending = const [], bool unseenDone = false}) => FakeAgentSession(
      state: stateWith(
        items: [userMsg('u1', 'Fix the build'), agentMsg('a1', 'The retry loop never backs off.')],
        pending: pending,
      ),
      link: AgentLink.connecting,
      unseenDone: unseenDone,
    )..cachedAsOfValue = DateTime.now().subtract(const Duration(minutes: 3));

    testWidgets('the transcript is on screen at once, under a quiet Updating… strip, not a blank Connecting…', (tester) async {
      final session = copy();
      await _pump(tester, session);
      expect(find.textContaining('Fix the build', findRichText: true), findsOneWidget);
      expect(find.textContaining('The retry loop never backs off.', findRichText: true), findsOneWidget);
      expect(_strip('Updating…'), findsOneWidget);
      expect(_strip('Showing the copy saved'), findsOneWidget);
      expect(_strip('Connecting…'), findsNothing);
    });

    testWidgets('when the keeper has confirmed it the strip goes and the rows stay', (tester) async {
      final session = copy();
      await _pump(tester, session);
      session
        ..setLink(AgentLink.live)
        ..setSavedCopy(null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(StatusStrip), findsNothing);
      expect(find.textContaining('Fix the build', findRichText: true), findsOneWidget);
    });

    testWidgets('a session that was never saved still says Connecting…', (tester) async {
      final session = FakeAgentSession(link: AgentLink.connecting);
      await _pump(tester, session);
      expect(_strip('Connecting…'), findsOneWidget);
      expect(_strip('Updating…'), findsNothing);
    });

    testWidgets('a request that waited when the copy was saved is not offered, and comes back with the attach', (tester) async {
      final request = PendingPermission(7, permissionRequest(rawInput: {'command': 'rm -rf build'}));
      final session = copy(pending: [request]);
      await _pump(tester, session);
      expect(find.byType(PermissionPanel), findsNothing, reason: 'nothing to answer in a saved copy');
      expect(find.textContaining('rm -rf build', findRichText: true), findsNothing);
      expect(session.permissionAnswers, isEmpty);

      session
        ..setLink(AgentLink.live)
        ..setSavedCopy(null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PermissionPanel), findsOneWidget, reason: 'confirmed by the keeper: now it is live');
    });

    testWidgets('a connect that fails or drops still names the copy and when it was saved', (tester) async {
      for (final link in [AgentLink.failed, AgentLink.reconnecting, AgentLink.ended]) {
        final session = copy();
        await _pump(tester, session);
        session.setLink(link, error: 'Could not reach the session on devbox.');
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          _strip(savedCopyNotice(session.cachedAsOf!, DateTime.now())),
          findsOneWidget,
          reason: '$link over a saved copy must not read as the live session',
        );
      }
    });

    testWidgets('a request the board says waits is named in the dock while it cannot be shown', (tester) async {
      final request = PendingPermission(7, permissionRequest(rawInput: {'command': 'rm -rf build'}));
      final session = copy(pending: [request]);
      await _pump(tester, session);
      session.setLink(AgentLink.reconnecting, error: 'The link dropped.');
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PermissionPanel), findsNothing);
      final waiting = find.descendant(of: find.byType(StatusStrip), matching: find.byType(StatusGlyph));
      expect(waiting, findsOneWidget, reason: 'the dock is not silently empty');
      expect(tester.widget<StatusGlyph>(waiting).status, AgentStatus.blocked);

      session
        ..setLink(AgentLink.live)
        ..setSavedCopy(null);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(PermissionPanel), findsOneWidget);
      expect(waiting, findsNothing, reason: 'the request itself is shown now');
    });

    testWidgets('a finished session opened from its saved copy stays to review until the live replay shows it', (tester) async {
      final session = copy(unseenDone: true);
      await _pump(tester, session);
      session.setLink(AgentLink.failed, error: 'Could not reach the session on devbox.');
      await tester.pump(const Duration(milliseconds: 100));
      expect(session.unseenDone, isTrue, reason: 'the copy may not hold the turn that finished');

      session
        ..setLink(AgentLink.live)
        ..setSavedCopy(null);
      await tester.pump(const Duration(milliseconds: 600));
      expect(session.unseenDone, isFalse, reason: 'the live replay shows it: reviewed');

      await tester.tap(find.text('Undo'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(session.unseenDone, isTrue, reason: 'the same Undo as every board review');
    });
  });

  group('savedCopyLabel', () {
    final now = DateTime(2026, 3, 1, 15, 30);
    test('today, yesterday, earlier', () {
      expect(savedCopyLabel(DateTime(2026, 3, 1, 14, 2), now), 'at 14:02');
      expect(savedCopyLabel(DateTime(2026, 3, 1, 9, 5), now), 'at 09:05');
      expect(savedCopyLabel(DateTime(2026, 2, 28, 23, 59), now), 'yesterday at 23:59');
      expect(savedCopyLabel(DateTime(2026, 2, 3, 8, 0), now), 'on 3 Feb at 08:00');
    });
  });

  group('PreconnectTap', () {
    late FakeAgentSessions sessions;
    late List<Preconnect?> taken;

    Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
      sessions = FakeAgentSessions([]);
      taken = [];
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableProvider<AgentSessions>.value(
            value: sessions,
            child: Scaffold(
              body: Center(
                child: PreconnectTap(
                  sessionKey: 'm/k1',
                  enabled: enabled,
                  builder: (context, take) => GestureDetector(
                    onTap: () => taken.add(take()),
                    onLongPress: () {},
                    child: const SizedBox(width: 200, height: 80, child: ColoredBox(color: Colors.blue)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a finger going down takes one hold; lifting without opening lets it go after a moment', (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last));
      expect(sessions.preconnected, ['m/k1']);
      expect(sessions.openPreconnects, 1);

      // Held down a moment: still one hold.
      await tester.pump(const Duration(milliseconds: 150));
      expect(sessions.preconnected, hasLength(1));
      expect(sessions.openPreconnects, 1);

      await gesture.up();
      // It was a tap: the opener takes the hold and the row lets go of it.
      expect(taken, hasLength(1));
      expect(taken.single, isNotNull);
      await tester.pump(const Duration(seconds: 2));
      expect(sessions.openPreconnects, 1, reason: 'the hold belongs to the opened screen now, not to the row');
      taken.single!.cancel();
      expect(sessions.openPreconnects, 0);
    });

    testWidgets('a finger that lifts without a tap (a long press) lets the hold go by itself', (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last));
      await tester.pump(const Duration(seconds: 1)); // long enough for a long press
      await gesture.up();
      expect(taken, isEmpty, reason: 'no tap, nothing opened');
      expect(sessions.openPreconnects, 1, reason: 'a moment of grace, in case the tap is late');
      await tester.pump(const Duration(seconds: 1));
      expect(sessions.openPreconnects, 0);
      expect(sessions.preconnected, hasLength(1), reason: 'one acquire, one release');
    });

    testWidgets('a finger that slides away (a scroll, a swipe) cancels it at once', (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last));
      expect(sessions.openPreconnects, 1);
      await gesture.moveBy(const Offset(0, 8));
      expect(sessions.openPreconnects, 1, reason: 'within the touch slop');
      await gesture.moveBy(const Offset(0, 40));
      expect(sessions.openPreconnects, 0);
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(sessions.preconnected, hasLength(1), reason: 'one acquire, one release');
      expect(taken, isEmpty);
    });

    testWidgets('a cancelled pointer cancels it', (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last));
      expect(sessions.openPreconnects, 1);
      await gesture.cancel();
      expect(sessions.openPreconnects, 0);
    });

    testWidgets('hovering a mouse over the row starts nothing; pressing it does', (tester) async {
      await pump(tester);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byType(SizedBox).last));
      await tester.pump();
      expect(sessions.preconnected, isEmpty);
      await mouse.down(tester.getCenter(find.byType(SizedBox).last));
      expect(sessions.preconnected, ['m/k1']);
      await mouse.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('a second finger does not take a second hold', (tester) async {
      await pump(tester);
      final a = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last), pointer: 1);
      final b = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last) + const Offset(5, 5), pointer: 2);
      expect(sessions.preconnected, hasLength(1));
      await b.up();
      await a.up();
      await tester.pump(const Duration(seconds: 1));
      for (final hold in taken) {
        hold?.cancel();
      }
      expect(sessions.preconnected, hasLength(1));
      expect(sessions.openPreconnects, 0);
    });

    testWidgets('disabled (a selection is under way): no hold', (tester) async {
      await pump(tester, enabled: false);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last));
      expect(sessions.preconnected, isEmpty);
      await gesture.up();
    });

    testWidgets('removed from the tree with a hold in hand: it is let go', (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.byType(SizedBox).last));
      expect(sessions.openPreconnects, 1);
      await tester.pumpWidget(const SizedBox());
      expect(sessions.openPreconnects, 0);
      await gesture.up();
    });
  });
}
