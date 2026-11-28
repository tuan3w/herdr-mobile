// The reply sheet while its machine is out of reach. A Send that reaches it
// then (the keyboard's, in the frame before the field is switched off) is a
// refusal the person feels and reads, as the session composer's is: not a
// silent nothing. What was typed stays.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/ui/features/agent_session/composer.dart' show composerReason;
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/features/composer/composer_frame.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine() => (
  profile: const MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
  snapshot: snapshotWith([(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked')], title: (_) => 'task 1'),
);

Finder get _field => find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField));

void main() {
  setUpAll(loadAppFonts);

  Future<(BoardHarness, List<Object?>)> offlineSheet(WidgetTester tester, {String typed = ''}) async {
    final h = await BoardHarness.create([_machine()]);
    h.previews.set('a/w1:p1', const ['…context…']);
    await pumpBoard(tester, h, width: 360, height: 2400);
    await tester.tap(replyTo('task 1'));
    await tester.pump(const Duration(milliseconds: 600));
    if (typed.isNotEmpty) await tester.enterText(_field, typed);
    final felt = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') felt.add(call.arguments);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    h.network.goOffline();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return (h, felt);
  }

  testWidgets('a Send that reaches the sheet while offline is felt and said, and keeps the text', (tester) async {
    final (h, felt) = await offlineSheet(tester, typed: 'use main');

    tester.widget<ComposerField>(find.byType(ComposerField)).onSubmit();
    await tester.pump();

    expect(felt, contains('HapticFeedbackType.heavyImpact'), reason: 'felt as a refusal');
    expect(find.textContaining('Not connected'), findsOneWidget, reason: 'it says why nothing went');
    expect(tester.widget<TextField>(_field).controller!.text, 'use main', reason: 'what was typed stays');
    expect([for (final (m, _) in h.transports['a']!.calls) m], isNot(contains('pane.send_input')));
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets('an empty Send while offline says nothing: there is nothing to explain', (tester) async {
    final (h, felt) = await offlineSheet(tester);

    tester.widget<ComposerField>(find.byType(ComposerField)).onSubmit();
    await tester.pump();

    expect(felt, isEmpty);
    expect(find.textContaining('Not connected'), findsNothing);
    await teardownBoard(tester, h);
  });

  testWidgets('the offline hint is the one the other composers use', (tester) async {
    final (h, _) = await offlineSheet(tester);

    expect(tester.widget<TextField>(_field).decoration!.hintText, composerReason(AgentLink.reconnecting));
    await teardownBoard(tester, h);
  });
}
