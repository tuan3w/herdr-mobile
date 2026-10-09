// The reply sheet's keyboard Send on an empty field is a bare Enter. While the
// sheet asks a question that would choose whatever the agent has highlighted,
// past the chips' hold and guard; the pane screen refuses exactly this.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/ui/core/tap_guard.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine() => (
      profile: const MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
      snapshot: snapshotWith(
        [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked')],
        title: (_) => 'task 1',
      ),
    );

const _prompt = PromptInfo(
  question: 'Do you want to proceed?',
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter']),
    QuickReply(label: '2. No', keys: ['2', 'enter']),
  ],
);

Future<BoardHarness> _sheet(WidgetTester tester, {PromptInfo? prompt}) async {
  final h = await BoardHarness.create([_machine()]);
  h.previews.set('a/w1:p1', const ['…context…'], prompt: prompt);
  await pumpBoard(tester, h, width: 360, height: 2400);
  await tester.tap(find.byTooltip('Reply to task 1'));
  await tester.pump();
  return h;
}

List<Object?> _sentKeys(BoardHarness h) => [
      for (final (m, p) in h.transports['a']!.calls)
        if (m == 'pane.send_keys') p['keys'],
    ];

Future<void> _imeSend(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField)));
  await tester.pump();
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Send on an empty field while a question is shown sends nothing, and says why', (tester) async {
    final h = await _sheet(tester, prompt: _prompt);
    await tester.pump(tapGuard * 2);

    await _imeSend(tester);

    expect(_sentKeys(h), isEmpty, reason: 'a bare Enter would choose the highlighted answer');
    expect(find.text('Pick an answer above'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets('Send on a whitespace-only field is the same bare Enter, and refused the same', (tester) async {
    final h = await _sheet(tester, prompt: _prompt);
    await tester.pump(tapGuard * 2);

    await tester.enterText(find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField)), '  ');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(_sentKeys(h), isEmpty);
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets('with nothing asked, Send on an empty field still presses Enter, once the sheet has settled',
      (tester) async {
    final h = await _sheet(tester);

    // Just opened: the guard that holds the Enter key button holds this too.
    await _imeSend(tester);
    expect(_sentKeys(h), isEmpty, reason: 'a tap meant for what was there before must not land');

    await tester.pump(tapGuard * 2);
    await _imeSend(tester);
    expect(_sentKeys(h), [
      ['enter'],
    ]);
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets('typed text is still sent while a question is shown', (tester) async {
    final h = await _sheet(tester, prompt: _prompt);
    await tester.pump(tapGuard * 2);

    await tester.enterText(find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField)), 'use main');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect([for (final (m, _) in h.transports['a']!.calls) m], contains('pane.send_input'));
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });
}
