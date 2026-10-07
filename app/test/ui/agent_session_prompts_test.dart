import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/ui/core/hold_confirm.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart' show toastKey;
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_dock.dart';
import 'package:herdr_mobile/ui/features/agent_session/permission_subject.dart';
import 'package:herdr_mobile/ui/features/agent_session/question_form.dart';
import 'package:herdr_mobile/ui/features/agent_session/visible_text.dart';

import '../support/fake_agent_session.dart';
import 'hold_support.dart';

Future<void> pumpScreen(
  WidgetTester tester,
  FakeAgentSession session, {
  Size size = const Size(412, 892),
  double textScale = 1,
  bool settle = true,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AgentSessionScreen(key: ObjectKey(session), session: session),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  // A permission panel ignores taps for a moment after it appears.
  if (settle) await tester.pump(tapGuard);
}

FakeAgentSession withPermission(
  PermissionRequest request, {
  Object id = 7,
  bool keepPending = false,
}) => FakeAgentSession(state: stateWith(turnActive: true, pending: [PendingPermission(id, request)]))
  ..keepPendingOnAnswer = keepPending;

PermissionOutcome? answered(FakeAgentSession s, int i) => s.permissionAnswers[i].$2;

String? selectedId(PermissionOutcome? o) => o is PermissionSelected ? o.optionId : null;

ElicitationRequest form(Map<String, Object?> properties, {List<String> required = const [], String message = 'A question'}) =>
    ElicitationRequest.parse({
      'mode': 'form',
      'message': message,
      'requestedSchema': {'type': 'object', 'required': required, 'properties': properties},
    });

FakeAgentSession withQuestion(ElicitationRequest request, {bool keepPending = false}) =>
    FakeAgentSession(state: stateWith(turnActive: true, pending: [PendingQuestion(9, request)]))
      ..keepPendingOnAnswer = keepPending;

Map<String, Object?> acceptedContent(FakeAgentSession s) {
  final response = s.questionAnswers.single.$2;
  expect(response, isA<ElicitationAccept>());
  return (response as ElicitationAccept).content;
}

void main() {
  group('permission request', () {
    testWidgets('always shows what it will run, in full, with the risk named', (tester) async {
      final request = permissionRequest(
        title: 'Bash',
        rawInput: {'command': 'git push --force origin main'},
      );
      await pumpScreen(tester, withPermission(request));
      expect(find.text('git push --force origin main'), findsOneWidget);
      expect(find.textContaining('Look closely: force-pushes'), findsOneWidget);
      expect(find.text('Bash'), findsOneWidget);
    });

    testWidgets('a harmless command has no risk line and its allow takes one tap, sent once', (tester) async {
      final session = withPermission(
        permissionRequest(rawInput: {'command': 'ls -la'}),
        keepPending: true,
      );
      await pumpScreen(tester, session);
      expect(find.textContaining('Look closely'), findsNothing);

      await tester.tap(find.text('Allow once'));
      await tester.pump();
      // The session has not caught up (the request is still pending): a second
      // tap must not answer again.
      await tester.tap(find.text('Allow once'));
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(session.permissionAnswers, hasLength(1));
      expect(session.permissionAnswers.single.$1, 7);
      expect(selectedId(answered(session, 0)), 'allow-once');
    });

    testWidgets('a standing grant is held, not tapped: a tap says why and sends nothing', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'ls'}));
      await pumpScreen(tester, session);
      await quickTap(tester, find.text('Always allow'));
      expect(session.permissionAnswers, isEmpty);
      expect(find.text('Hold to send · standing permission'), findsOneWidget);

      await holdFor(tester, find.text('Hold to send · standing permission'));
      expect(selectedId(answered(session, 0)), 'allow-always');
    });

    testWidgets('an option that grants more in its words is gated whatever its kind', (tester) async {
      final session = withPermission(
        permissionRequest(
          rawInput: {'command': 'ls'},
          options: const [
            PermissionOption(
              optionId: 'yes-forever',
              name: 'Yes, and don’t ask again for ls',
              kind: PermissionOptionKind.allowOnce,
            ),
          ],
        ),
      );
      await pumpScreen(tester, session);
      await quickTap(tester, find.textContaining('don’t ask again'));
      expect(session.permissionAnswers, isEmpty);
      await holdFor(tester, find.textContaining('Hold to send'));
      expect(selectedId(answered(session, 0)), 'yes-forever');
    });

    testWidgets('a risky command gates the allow, never the refusal', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'rm -rf /srv/data'}));
      await pumpScreen(tester, session);
      await quickTap(tester, find.text('Allow once'));
      expect(session.permissionAnswers, isEmpty);
      expect(find.textContaining('Hold to send'), findsOneWidget);

      // Refusing is one tap, whatever else is primed or shown.
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(session.permissionAnswers, hasLength(1));
      expect(selectedId(answered(session, 0)), 'reject');
    });

    testWidgets('a full hold sends once, however long the finger stays; the fill is the progress', (tester) async {
      final session = withPermission(
        permissionRequest(rawInput: {'command': 'rm -rf /srv/data'}),
        keepPending: true,
      );
      await pumpScreen(tester, session);
      final g = await pressAndHold(tester, find.text('Allow once'), const Duration(milliseconds: 300));
      expect(find.textContaining('Hold to send · '), findsOneWidget);
      expect(fillOf(tester), inExclusiveRange(0, 1));
      expect(session.permissionAnswers, isEmpty);

      await advance(tester, const Duration(milliseconds: 600));
      expect(session.permissionAnswers, hasLength(1));
      await advance(tester, const Duration(seconds: 2));
      await g.up();
      await tester.pump();
      expect(session.permissionAnswers, hasLength(1), reason: 'once');
      expect(selectedId(answered(session, 0)), 'allow-once');
    });

    testWidgets('letting go early sends nothing and the fill goes back; the hint says how', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'rm -rf /srv/data'}));
      await pumpScreen(tester, session);
      final g = await pressAndHold(tester, find.text('Allow once'), const Duration(milliseconds: 425));
      expect(fillOf(tester), greaterThan(0.2));
      await g.up();
      await advance(tester, const Duration(milliseconds: 300));
      expect(fillOf(tester), 0);
      expect(session.permissionAnswers, isEmpty);
      expect(find.textContaining('Hold to send'), findsOneWidget);

      await advance(tester, holdHintWindow);
      expect(find.text('Allow once'), findsOneWidget, reason: 'the chip is itself again');
    });

    testWidgets('assistive activation is the two-step flow, and the primed option has a window', (tester) async {
      final semantics = tester.ensureSemantics();
      final session = withPermission(permissionRequest(rawInput: {'command': 'rm -rf /srv/data'}));
      await pumpScreen(tester, session);
      final gated = find.semantics.byLabel(RegExp('^Allow once, needs holding or a second activation: '));
      tester.semantics.tap(gated);
      await tester.pump();
      expect(session.permissionAnswers, isEmpty);
      expect(find.textContaining('Hold or tap again · '), findsOneWidget);

      await tester.pump(confirmWindow + const Duration(milliseconds: 100));
      expect(find.textContaining('Hold or tap again'), findsNothing);
      tester.semantics.tap(gated);
      await tester.pump();
      expect(session.permissionAnswers, isEmpty, reason: 'a stale confirmation must not count');
      expect(find.textContaining('Hold or tap again · '), findsOneWidget);

      tester.semantics.tap(find.semantics.byLabel(RegExp('^Confirm: Allow once, ')));
      await tester.pump();
      expect(selectedId(answered(session, 0)), 'allow-once');
      semantics.dispose();
    });

    testWidgets('a hold started while the panel ignores taps does nothing, even after it wakes', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'rm -rf /srv/data'}));
      await pumpScreen(tester, session, settle: false);
      final g = await pressAndHold(tester, find.text('Allow once'), const Duration(milliseconds: 1000));
      await g.up();
      await tester.pump();
      expect(session.permissionAnswers, isEmpty);
    });

    testWidgets('a new request in the middle of a hold drops it, and the finger on the new one sends nothing', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'rm -rf /srv/data'}));
      await pumpScreen(tester, session);
      final g = await pressAndHold(tester, find.text('Allow once'), const Duration(milliseconds: 450));
      expect(fillOf(tester), greaterThan(0));

      session.push(
        stateWith(
          turnActive: true,
          pending: [PendingPermission(8, permissionRequest(rawInput: {'command': 'rm -rf /srv/other'}))],
        ),
      );
      await advance(tester, const Duration(milliseconds: 1500));
      await g.up();
      await advance(tester, const Duration(milliseconds: 300));
      expect(session.permissionAnswers, isEmpty);
      expect(find.text('rm -rf /srv/other'), findsOneWidget);
    });

    testWidgets('cancel answers cancelled, once', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'ls'}), keepPending: true);
      await pumpScreen(tester, session);
      await tester.tap(find.text('Cancel request'));
      await tester.pump();
      await tester.tap(find.text('Cancel request'));
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(session.permissionAnswers, hasLength(1));
      expect(answered(session, 0), isA<PermissionCancelled>());
    });

    testWidgets('waiting requests are counted and shown one at a time', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          pending: [
            PendingPermission(1, permissionRequest(title: 'First', rawInput: {'command': 'echo first'})),
            PendingPermission(2, permissionRequest(title: 'Second', rawInput: {'command': 'echo second'})),
            PendingQuestion(3, form({'a': {'type': 'string'}})),
          ],
        ),
      );
      await pumpScreen(tester, session);
      expect(find.text('echo first'), findsOneWidget);
      expect(find.text('echo second'), findsNothing);
      expect(find.text('2 more waiting'), findsOneWidget);

      await tester.tap(find.text('Allow once'));
      await tester.pump();
      await tester.pump(tapGuard);
      expect(session.permissionAnswers.single.$1, 1);
      expect(find.text('echo second'), findsOneWidget);
      expect(find.text('echo first'), findsNothing);
      expect(find.text('1 more waiting'), findsOneWidget);

      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(session.permissionAnswers.last.$1, 2);
      // Only the question is left.
      expect(find.text('A question'), findsOneWidget);
      expect(find.text('Allow once'), findsNothing);
    });

    testWidgets('without a command it shows the input, and judges the file it names', (tester) async {
      await pumpScreen(
        tester,
        withPermission(permissionRequest(title: 'Edit file', kind: ToolKind.edit, rawInput: {'file_path': '/etc/hosts'})),
      );
      expect(find.textContaining('file_path: /etc/hosts'), findsOneWidget);
      expect(find.textContaining('Look closely: changes system files'), findsOneWidget);
    });

    testWidgets('with nothing but a title, the title is the subject and is not said twice', (tester) async {
      await pumpScreen(tester, withPermission(permissionRequest(title: 'Delete the build folder')));
      expect(find.text('Delete the build folder'), findsOneWidget);
      expect(find.text('Run'), findsOneWidget, reason: 'the header names the kind instead');
    });

    testWidgets('a request that offers only a refusal can be refused, and cancelled', (tester) async {
      final onlyReject = permissionRequest(
        rawInput: {'command': 'ls'},
        options: const [PermissionOption(optionId: 'no', name: 'Decline', kind: PermissionOptionKind.rejectOnce)],
      );
      final refused = withPermission(onlyReject);
      await pumpScreen(tester, refused);
      await tester.tap(find.text('Decline'));
      await tester.pump();
      expect(selectedId(answered(refused, 0)), 'no');

      final cancelled = withPermission(onlyReject);
      await pumpScreen(tester, cancelled);
      await tester.tap(find.text('Cancel request'));
      await tester.pump();
      expect(answered(cancelled, 0), isA<PermissionCancelled>());
    });

    testWidgets('a 4000-character command stays readable and the answers stay on screen at 320 dp', (tester) async {
      final command = 'echo ${'Hà Nội Đà Nẵng ' * 250}';
      final session = withPermission(permissionRequest(rawInput: {'command': command}));
      await pumpScreen(tester, session, size: const Size(320, 640));
      expect(find.text(command), findsOneWidget);
      expect(find.textContaining('More below'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // The command scrolls inside its box; the answers are not pushed away.
      expect(tester.getRect(find.text('Reject')).bottom, lessThanOrEqualTo(640));
      expect(tester.getRect(find.text('Cancel request')).bottom, lessThanOrEqualTo(640));
    });

    testWidgets('at twice the text size the request lays out and scrolls without overflow', (tester) async {
      final command = 'echo ${'Hà Nội Đà Nẵng ' * 250}';
      final session = withPermission(permissionRequest(rawInput: {'command': command}));
      await pumpScreen(tester, session, size: const Size(320, 640), textScale: 2);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Cancel request'), 100, scrollable: find.byType(Scrollable).last);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a box that overflows shows a scrollbar and what is below; no cue when it fits', (tester) async {
      final long = List.generate(40, (i) => 'step $i').join('\n');
      await pumpScreen(tester, withPermission(permissionRequest(rawInput: {'command': long})));
      expect(find.textContaining('More below · 40 lines'), findsOneWidget);
      expect(tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility, isTrue);

      await pumpScreen(tester, withPermission(permissionRequest(rawInput: {'command': 'ls'})));
      expect(find.textContaining('More below'), findsNothing);
      expect(find.text('Read all'), findsNothing);
      expect(tester.widget<Scrollbar>(find.byType(Scrollbar)).thumbVisibility, isFalse);
    });

    testWidgets('eight newlines cannot hide the tail: it is on screen and judged', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'ls\n\n\n\n\n\n\n\n\nrm -rf ~'}));
      await pumpScreen(tester, session);
      expect(find.textContaining('rm -rf ~'), findsOneWidget);
      expect(find.textContaining('\u21b5 8 blank lines'), findsOneWidget);
      expect(find.textContaining('Look closely: deletes files'), findsOneWidget);
    });

    testWidgets('holding an allow on a command longer than its box shows the end and sends nothing; the next hold sends', (tester) async {
      final long = '${List.generate(40, (i) => 'echo step $i').join('\n')}\nls';
      final session = withPermission(permissionRequest(rawInput: {'command': long}));
      await pumpScreen(tester, session);
      expect(find.textContaining('More below'), findsOneWidget);

      await holdFor(tester, find.text('Allow once'));
      expect(session.permissionAnswers, isEmpty, reason: 'the first hold only reads');
      expect(find.text('Hold or tap again · long command, read it all'), findsOneWidget);
      expect(find.textContaining('More below'), findsNothing, reason: 'the first hold scrolled to the end');
      expect(fillOf(tester), 0);

      await holdFor(tester, find.text('Hold or tap again · long command, read it all'));
      expect(selectedId(answered(session, 0)), 'allow-once');
    });

    testWidgets('a tap on an unread command does not scroll it or send; assistive activation shows the end', (tester) async {
      final semantics = tester.ensureSemantics();
      final long = '${List.generate(40, (i) => 'echo step $i').join('\n')}\nls';
      final session = withPermission(permissionRequest(rawInput: {'command': long}));
      await pumpScreen(tester, session);

      await quickTap(tester, find.text('Allow once'));
      expect(find.textContaining('More below'), findsOneWidget);
      expect(session.permissionAnswers, isEmpty);
      await tester.pump(holdHintWindow);

      tester.semantics.tap(find.semantics.byLabel(RegExp('^Allow once, needs holding')));
      await tester.pump();
      expect(find.textContaining('More below'), findsNothing);
      expect(find.text('Hold or tap again · long command, read it all'), findsOneWidget);
      expect(session.permissionAnswers, isEmpty);
      semantics.dispose();
    });

    testWidgets('a refusal never waits for the command to be read', (tester) async {
      final long = List.generate(40, (i) => 'echo step $i').join('\n');
      final session = withPermission(permissionRequest(rawInput: {'command': long}));
      await pumpScreen(tester, session);
      await tester.tap(find.text('Reject'));
      await tester.pump();
      expect(selectedId(answered(session, 0)), 'reject');
    });

    testWidgets('"Read all" shows everything it will run and counts as reading it', (tester) async {
      final long = List.generate(40, (i) => 'echo step $i').join('\n');
      final session = withPermission(permissionRequest(rawInput: {'command': long}));
      await pumpScreen(tester, session);
      await tester.tap(find.text('Read all'));
      await tester.pumpAndSettle();
      expect(find.text('Everything it will run'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(selectedId(answered(session, 0)), 'allow-once', reason: 'no second tap once it was opened');
    });

    testWidgets('hidden characters in the command, title and options are shown as escapes', (tester) async {
      final session = withPermission(
        permissionRequest(
          title: 'Run\u202E nasty',
          rawInput: {'command': 'echo \u202Egnirts'},
          options: const [
            PermissionOption(optionId: 'a', name: 'Allow\u200B once', kind: PermissionOptionKind.allowOnce),
          ],
        ),
      );
      await pumpScreen(tester, session);
      expect(find.text('echo \u2039U+202E\u203agnirts'), findsOneWidget);
      expect(find.text('Run\u2039U+202E\u203a nasty'), findsOneWidget);
      expect(find.text('Allow\u2039U+200B\u203a once'), findsOneWidget);
      expect(find.textContaining('\u202E'), findsNothing);
    });

    testWidgets('a write shows the files it touches and is gated by where it lands', (tester) async {
      final session = withPermission(
        permissionRequest(
          title: 'Edit file',
          kind: ToolKind.edit,
          locations: [
            {'path': '/home/dev/.ssh/authorized_keys'},
          ],
        ),
      );
      await pumpScreen(tester, session);
      expect(find.text('/home/dev/.ssh/authorized_keys'), findsOneWidget);
      expect(find.textContaining('Look closely: changes ssh keys'), findsOneWidget);
      await quickTap(tester, find.text('Allow once'));
      expect(session.permissionAnswers, isEmpty);
      expect(find.text('Hold to send · changes ssh keys'), findsOneWidget);
    });

    testWidgets('taps are ignored while the panel has just appeared, and the answers are dimmed', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'ls'}));
      await pumpScreen(tester, session, settle: false);
      Color? colorOf(String label) => tester.widget<Text>(find.text(label)).style!.color;
      expect(colorOf('Allow once'), Ds.paper.textMuted);

      await tester.tap(find.text('Allow once'));
      await tester.tap(find.text('Cancel request'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(session.permissionAnswers, isEmpty);

      await tester.pump(const Duration(milliseconds: 60));
      expect(colorOf('Allow once'), Ds.paper.text);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(session.permissionAnswers, hasLength(1));
    });

    testWidgets('the next request ignores the tap that answered the last one', (tester) async {
      final session = FakeAgentSession(
        state: stateWith(
          turnActive: true,
          pending: [
            PendingPermission(1, permissionRequest(rawInput: {'command': 'echo first'})),
            PendingPermission(2, permissionRequest(rawInput: {'command': 'echo second'})),
          ],
        ),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(find.text('echo second'), findsOneWidget);

      // A second tap on the same spot lands on the new request: ignored.
      await tester.tap(find.text('Allow once'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(session.permissionAnswers.map((a) => a.$1), [1]);

      await tester.pump(tapGuard);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      expect(session.permissionAnswers.map((a) => a.$1), [1, 2]);
    });

    testWidgets('a request answered on the computer leaves the dock with one toast naming who answered', (tester) async {
      final session = withPermission(permissionRequest(rawInput: {'command': 'npm test'}));
      await pumpScreen(tester, session);
      expect(find.byType(PermissionPanel), findsOneWidget);

      session.answerElsewhere(7, by: 'Terminal on mac-mini', answer: 'Allow once');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(PermissionPanel), findsNothing);
      expect(find.byKey(toastKey), findsOneWidget);
      expect(find.textContaining('Terminal on mac-mini'), findsOneWidget);
      expect(session.permissionAnswers, isEmpty, reason: 'nothing was answered from this phone');

      // Gone after its time, and not told again by the next update.
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));
      session.push(session.state.withTurnStarted());
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(toastKey), findsNothing);
    });
  });

  group('permission rules', () {
    const allowOnce = PermissionOption(optionId: 'a', name: 'Allow', kind: PermissionOptionKind.allowOnce);
    const rejectOnce = PermissionOption(optionId: 'r', name: 'Reject', kind: PermissionOptionKind.rejectOnce);

    test('standing kinds are gated, and so are words that grant more', () {
      expect(
        optionGate(const PermissionOption(optionId: 'x', name: 'Allow', kind: PermissionOptionKind.allowAlways), null),
        'standing permission',
      );
      expect(
        optionGate(const PermissionOption(optionId: 'x', name: 'Block', kind: PermissionOptionKind.rejectAlways), null),
        isNotNull,
      );
      expect(
        optionGate(const PermissionOption(optionId: 'x', name: 'Always allow', kind: PermissionOptionKind.allowOnce), null),
        'standing permission',
      );
      expect(
        optionGate(const PermissionOption(optionId: 'x', name: 'Allow for this session', kind: PermissionOptionKind.other), null),
        'standing permission',
      );
    });

    test('a risk gates what allows, not what refuses', () {
      expect(optionGate(allowOnce, 'force-pushes'), 'force-pushes');
      expect(optionGate(rejectOnce, 'force-pushes'), isNull);
      expect(optionGate(allowOnce, null), isNull);
      expect(
        optionGate(const PermissionOption(optionId: 'x', name: 'Whatever', kind: PermissionOptionKind.other), 'risky'),
        'risky',
        reason: 'an unknown kind is never assumed to be a refusal',
      );
      expect(
        optionGate(const PermissionOption(optionId: 'x', name: 'Delete all branches', kind: PermissionOptionKind.allowOnce), null),
        isNotNull,
      );
    });

    test('the subject is the command, else the input, else the title', () {
      expect(permissionSubject(permissionRequest(rawInput: {'command': 'ls -la'})), 'ls -la');
      expect(permissionSubject(permissionRequest(title: 'T', rawInput: {'file_path': '/a'})), contains('/a'));
      expect(permissionSubject(permissionRequest(title: 'Only a title')), 'Only a title');
      expect(permissionSubject(permissionRequest(title: 'T', rawInput: {})), 'T');
      expect(permissionSubject(permissionRequest(title: 'T', rawInput: {'command': '   '})), contains('command'));
    });

    test('the subject names every field the call carries, not only a string command', () {
      final list = describePermission(permissionRequest(rawInput: {'command': ['rm', '-rf', '/srv/data']}));
      expect(list.subject, contains('rm'));
      expect(list.risk, 'deletes files', reason: 'a command given as a list is judged as one line');

      expect(describePermission(permissionRequest(rawInput: {'cmd': 'rm -rf /srv/data'})).risk, 'deletes files');
      expect(describePermission(permissionRequest(rawInput: {'script': 'git push --force'})).risk, 'force-pushes');
      expect(
        describePermission(permissionRequest(rawInput: {'executable': 'rm', 'args': ['-rf', '/']})).risk,
        'deletes files',
      );
      expect(describePermission(permissionRequest(title: 'Delete the build folder')).risk, 'deletes or overwrites');

      // A file body is not a command: a README that quotes one is not flagged.
      expect(
        describePermission(permissionRequest(
          title: 'Write notes',
          kind: ToolKind.edit,
          rawInput: {'file_path': 'notes.md', 'content': 'run rm -rf build/ to clean up'},
        )).risk,
        isNull,
      );
    });

    test('a write is judged by where it lands: input, locations and diffs', () {
      expect(
        describePermission(permissionRequest(
          kind: ToolKind.edit,
          rawInput: {'file_path': '/home/dev/.ssh/authorized_keys', 'content': 'ssh-ed25519 AAAA'},
        )).risk,
        'changes ssh keys',
      );
      final located = describePermission(permissionRequest(
        title: 'Edit file',
        kind: ToolKind.edit,
        locations: [
          {'path': '/home/dev/.bashrc', 'line': 3},
        ],
      ));
      expect(located.risk, 'changes shell start-up');
      expect(located.paths, ['/home/dev/.bashrc:3']);
      final diffed = describePermission(permissionRequest(
        title: 'Edit file',
        kind: ToolKind.edit,
        content: [
          {'type': 'diff', 'path': 'repo/.git/hooks/pre-commit', 'newText': 'exit 0'},
        ],
      ));
      expect(diffed.risk, 'changes git hooks');
      expect(diffed.paths, ['repo/.git/hooks/pre-commit']);
      expect(describePermission(permissionRequest(title: 'Write /etc/hosts', kind: ToolKind.edit)).risk, 'changes system files');
    });

    test('blank lines cannot push the dangerous tail out of sight', () {
      final info = describePermission(permissionRequest(rawInput: {'command': 'ls\n\n\n\n\n\n\n\n\nrm -rf ~'}));
      expect(info.subject, 'ls\n\u21b5 8 blank lines\nrm -rf ~');
      expect(info.risk, 'deletes files');
      // Two blank lines are left as they are.
      expect(describePermission(permissionRequest(rawInput: {'command': 'a\n\n\nb'})).subject, 'a\n\n\nb');
    });

    test('a huge input is cut with its size named, and is still judged whole', () {
      final command = '${'echo hi; ' * 3000}rm -rf /srv/data';
      final info = describePermission(permissionRequest(rawInput: {'command': command}));
      expect(info.hidden, command.length - subjectCharLimit);
      expect(info.subject.endsWith('\n\u2026 ${info.hidden} more characters'), isTrue);
      expect(info.subject.length, lessThan(subjectCharLimit + 40));
      expect(info.risk, 'deletes files', reason: 'the risk rules read past what is drawn');

      expect(describePermission(permissionRequest(rawInput: {'command': 'ls'})).hidden, 0);

      // A compact rendering of a big input is cut the same way, short fields first.
      final big = describePermission(permissionRequest(rawInput: {'body': 'x' * 50000, 'path': 'a.txt'}));
      expect(big.subject.startsWith('path: a.txt\nbody: '), isTrue);
      expect(big.hidden, greaterThan(0));
      expect(big.subject, contains('more characters'));
    });

    test('hidden characters show as escapes, and the risk reads what the person reads', () {
      expect(visibleText('rm\u202E -rf'), 'rm\u2039U+202E\u203a -rf');
      expect(visibleText('a\u200Bb\u2066c\u2069'), 'a\u2039U+200B\u203ab\u2039U+2066\u203ac\u2039U+2069\u203a');
      expect(visibleText('x\u001B[31my\u0007'), 'x\u2039U+001B\u203a[31my\u2039U+0007\u203a');
      expect(visibleText('\u{E0041}'), '\u2039U+E0041\u203a');
      expect(visibleText('tab\there\nnew'), 'tab\there\nnew', reason: 'tabs and newlines are text');
      expect(visibleText('Hà Nội – Đà Nẵng ✓ 日本'), 'Hà Nội – Đà Nẵng ✓ 日本');
      // A zero-width character inside a word breaks the word for the gate too.
      expect(describePermission(permissionRequest(rawInput: {'command': 'r\u200Bm -rf /'})).risk, isNull);
      expect(describePermission(permissionRequest(rawInput: {'command': 'rm -rf /'})).risk, 'deletes files');
      expect(describePermission(permissionRequest(title: 'Run\u202E nasty')).title, 'Run\u2039U+202E\u203a nasty');
    });
  });

  group('question form', () {
    Finder accept() => find.text('Accept');

    testWidgets('a required text field blocks Accept until filled', (tester) async {
      final session = withQuestion(form({'name': {'type': 'string', 'title': 'Your name'}}, required: ['name']));
      await pumpScreen(tester, session);
      expect(find.text('A question'), findsOneWidget);
      await tester.tap(accept());
      await tester.pump();
      expect(session.questionAnswers, isEmpty);
      expect(find.text('Required'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Hà Nội');
      await tester.pump();
      expect(find.text('Required'), findsNothing);
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), {'name': 'Hà Nội'});
      expect(session.questionAnswers.single.$1, 9);
    });

    testWidgets('an optional field left empty is not sent', (tester) async {
      final session = withQuestion(form({'note': {'type': 'string'}}));
      await pumpScreen(tester, session);
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), isEmpty);
    });

    testWidgets('a number field validates type, range and whole numbers', (tester) async {
      final session = withQuestion(
        form({'n': {'type': 'integer', 'title': 'Replicas', 'minimum': 1, 'maximum': 9}}, required: ['n']),
      );
      await pumpScreen(tester, session);
      expect(tester.widget<TextField>(find.byType(TextField).first).keyboardType.index, TextInputType.number.index);

      Future<void> tryValue(String text) async {
        await tester.enterText(find.byType(TextField).first, text);
        await tester.tap(accept());
        await tester.pump();
      }

      await tryValue('abc');
      expect(find.text('Must be a number'), findsOneWidget);
      await tryValue('99');
      expect(find.text('At most 9'), findsOneWidget);
      await tryValue('0');
      expect(find.text('At least 1'), findsOneWidget);
      await tryValue('2.5');
      expect(find.text('Must be a whole number'), findsOneWidget);
      expect(session.questionAnswers, isEmpty);

      await tryValue('3');
      final content = acceptedContent(session);
      expect(content['n'], 3);
      expect(content['n'], isA<int>());
    });

    testWidgets('a decimal number keeps its fraction', (tester) async {
      final session = withQuestion(form({'ratio': {'type': 'number'}}));
      await pumpScreen(tester, session);
      await tester.enterText(find.byType(TextField).first, '2.5');
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), {'ratio': 2.5});
    });

    testWidgets('a switch sends its value, off when untouched', (tester) async {
      final session = withQuestion(form({'ok': {'type': 'boolean', 'title': 'Deploy now'}, 'dry': {'type': 'boolean', 'title': 'Dry run'}}));
      await pumpScreen(tester, session);
      await tester.tap(find.text('Deploy now'));
      await tester.pump();
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), {'ok': true, 'dry': false});
    });

    testWidgets('answers typed into a question survive a permission that takes the dock', (tester) async {
      final session = withQuestion(
        form({
          'note': {'type': 'string', 'title': 'Note'},
          'ok': {'type': 'boolean', 'title': 'Deploy now'},
          'env': {
            'type': 'string',
            'title': 'Environment',
            'oneOf': [
              {'const': 'staging', 'title': 'Staging'},
              {'const': 'production', 'title': 'Production'},
            ],
          },
        }),
      );
      await pumpScreen(tester, session);
      await tester.enterText(find.byType(TextField).first, 'ship it after lunch');
      await tester.tap(find.text('Deploy now'));
      await tester.tap(find.text('Staging'));
      await tester.pump();

      // A permission arrives: it takes the dock, the question waits behind it.
      session.update((s) => s.withPending(PendingPermission(7, permissionRequest(rawInput: {'command': 'ls'}))));
      await tester.pump();
      expect(find.text('A question'), findsNothing);
      expect(find.text('1 more waiting'), findsOneWidget);
      await tester.pump(tapGuard);
      await tester.tap(find.text('Allow once'));
      await tester.pump();
      await tester.pump(tapGuard);

      // The question is back with what was typed and chosen.
      expect(find.text('A question'), findsOneWidget);
      expect(find.text('ship it after lunch'), findsOneWidget);
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), {'note': 'ship it after lunch', 'ok': true, 'env': 'staging'});
    });

    testWidgets('a single choice is a radio list; required until picked, optional ones can be cleared', (tester) async {
      final session = withQuestion(
        form({
          'env': {
            'type': 'string',
            'title': 'Environment',
            'oneOf': [
              {'const': 'staging', 'title': 'Staging'},
              {'const': 'production', 'title': 'Production'},
            ],
          },
        }, required: ['env']),
      );
      await pumpScreen(tester, session);
      await tester.tap(accept());
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      expect(session.questionAnswers, isEmpty);

      await tester.tap(find.text('Production'));
      await tester.pump();
      await tester.tap(find.text('Staging'));
      await tester.pump();
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), {'env': 'staging'}, reason: 'one choice at a time, by value not title');
    });

    testWidgets('an optional single choice can be unselected', (tester) async {
      final session = withQuestion(
        form({
          'env': {
            'type': 'string',
            'enum': ['a', 'b'],
          },
        }),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('a'));
      await tester.pump();
      await tester.tap(find.text('a'));
      await tester.pump();
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), isEmpty);
    });

    testWidgets('several choices honour their minimum and keep the options\' order', (tester) async {
      final session = withQuestion(
        form({
          'tags': {
            'type': 'array',
            'title': 'Notify',
            'minItems': 2,
            'items': {
              'anyOf': [
                {'const': 'ops', 'title': 'Ops'},
                {'const': 'qa', 'title': 'QA'},
                {'const': 'dev', 'title': 'Dev'},
              ],
            },
          },
        }, required: ['tags']),
      );
      await pumpScreen(tester, session);
      await tester.tap(find.text('Dev'));
      await tester.pump();
      await tester.tap(accept());
      await tester.pump();
      expect(find.text('Choose at least 2'), findsWidgets);
      expect(session.questionAnswers, isEmpty);

      await tester.tap(find.text('Ops'));
      await tester.pump();
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), {'tags': ['ops', 'dev']});
    });

    testWidgets('defaults fill the form', (tester) async {
      final session = withQuestion(
        form({
          'who': {'type': 'string', 'default': 'Lan'},
          'count': {'type': 'integer', 'default': 5},
        }),
      );
      await pumpScreen(tester, session);
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), {'who': 'Lan', 'count': 5});
    });

    testWidgets('Decline answers decline, and a double tap answers once', (tester) async {
      final session = withQuestion(form({'a': {'type': 'string'}}), keepPending: true);
      await pumpScreen(tester, session);
      await tester.tap(find.text('Decline'));
      await tester.pump();
      await tester.tap(find.text('Decline'));
      await tester.tap(accept());
      await tester.pump();
      expect(session.questionAnswers, hasLength(1));
      expect(session.questionAnswers.single.$2, isA<ElicitationDecline>());
    });

    testWidgets('Accept twice answers once', (tester) async {
      final session = withQuestion(form({'a': {'type': 'string'}}), keepPending: true);
      await pumpScreen(tester, session);
      await tester.tap(accept());
      await tester.pump();
      await tester.tap(accept());
      await tester.pump();
      expect(session.questionAnswers, hasLength(1));
    });

    testWidgets('a form with no fields can be accepted', (tester) async {
      final session = withQuestion(form(const {}, message: 'Proceed?'));
      await pumpScreen(tester, session);
      expect(find.text('Proceed?'), findsOneWidget);
      await tester.tap(accept());
      await tester.pump();
      expect(acceptedContent(session), isEmpty);
    });

    testWidgets('ignores Accept and Decline until the guard has passed, like a permission request', (tester) async {
      final session = withQuestion(form(const {}, message: 'Proceed?'));
      await pumpScreen(tester, session, settle: false);
      await tester.tap(accept(), warnIfMissed: false);
      await tester.tap(find.text('Decline'), warnIfMissed: false);
      await tester.pump();
      expect(session.questionAnswers, isEmpty, reason: 'a tap meant for what was there before');

      await tester.pump(tapGuard);
      await tester.tap(accept());
      await tester.pump();
      expect(session.questionAnswers, hasLength(1));
    });

    testWidgets('a field marked secret is warned about and not hidden', (tester) async {
      final session = withQuestion(
        form({
          'token': {
            'type': 'string',
            'title': 'Deploy token',
            '_meta': {
              'codex': {'isSecret': true},
            },
          },
          'name': {'type': 'string', 'title': 'Name'},
        }),
      );
      await pumpScreen(tester, session);
      expect(find.textContaining('marked Deploy token as secret'), findsOneWidget);
      expect(find.text('Marked secret by the agent'), findsOneWidget);
      for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
        expect(field.obscureText, isFalse);
      }
    });

    test('secret fields are read from the codex meta, a bare flag or a password format', () {
      final request = form({
        'a': {'type': 'string', '_meta': {'codex': {'isSecret': true}}},
        'b': {'type': 'string', '_meta': {'isSecret': true}},
        'c': {'type': 'string', 'format': 'password'},
        'd': {'type': 'string', '_meta': {'codex': {'isSecret': false}}},
        'e': {'type': 'string'},
      });
      expect(secretFields(request), {'a', 'b', 'c'});
    });

    testWidgets('a URL request is never offered: its message and a decline only', (tester) async {
      final request = ElicitationRequest.parse({
        'mode': 'url',
        'message': 'Sign in to continue',
        'url': 'https://example.com/login',
        'elicitationId': 'e1',
      });
      final session = withQuestion(request);
      await pumpScreen(tester, session);
      expect(find.text('Sign in to continue'), findsOneWidget);
      expect(find.text('Accept'), findsNothing);
      expect(find.textContaining('can only decline'), findsOneWidget);
      await tester.tap(find.text('Decline'));
      await tester.pump();
      expect(session.questionAnswers.single.$2, isA<ElicitationDecline>());
    });

    testWidgets('a field of a type this app can\'t show is named, and blocks Accept when required', (tester) async {
      final session = withQuestion(
        form({
          'blob': {'type': 'object', 'title': 'Config'},
        }, required: ['blob']),
      );
      await pumpScreen(tester, session);
      expect(find.textContaining('can’t show a field of type'), findsOneWidget);
      await tester.tap(accept());
      await tester.pump();
      expect(session.questionAnswers, isEmpty);
    });

    testWidgets('a long form scrolls inside its panel with Accept in reach at 320 dp and 2x text', (tester) async {
      final session = withQuestion(
        form({
          for (var i = 0; i < 8; i++)
            'f$i': {'type': 'string', 'title': 'Trường số $i', 'description': 'Mô tả dài ${'chữ ' * 12}'},
          'choice': {
            'type': 'string',
            'title': 'Chọn',
            'enum': ['một', 'hai', 'ba'],
          },
        }, message: 'Một câu hỏi rất dài ${'từ ' * 40}'),
      );
      await pumpScreen(tester, session, size: const Size(320, 640), textScale: 2);
      expect(tester.takeException(), isNull);
      expect(tester.getRect(accept()).bottom, lessThanOrEqualTo(640));
      expect(tester.getRect(find.text('Decline')).bottom, lessThanOrEqualTo(640));
    });
  });
}
