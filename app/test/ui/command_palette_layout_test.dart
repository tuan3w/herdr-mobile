// The command palette on a phone with the keyboard up and a busy composer
// stack (settings chips, queued messages, a background strip). Seen on a
// Galaxy A51: the palette's rows were drawn over the strip, the chips and the
// queue, because it was a fixed height in a column that is given what is left.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agent_session/queued_messages.dart';
import 'package:herdr_mobile/ui/features/agent_session/session_chips_row.dart';
import 'package:herdr_mobile/ui/features/composer/command_palette.dart';

import '../support/fake_agent_session.dart';
import 'history_support.dart';

void main() {
  testWidgets('while a command is typed, the rows between the palette and the field step aside', (tester) async {
    final session = FakeAgentSession(
      agent: 'omp',
      agentLabel: 'omp',
      state: stateWith(
        turnActive: true,
        options: const [
          SelectConfigOption(
            id: 'model',
            name: 'Model',
            category: 'model',
            value: 'a',
            choices: [ConfigChoice(value: 'a', name: 'Claude Sonnet 5.5')],
          ),
        ],
        commands: [
          for (final n in ['clear', 'compact', 'model', 'skill:design', 'switch', 'session', 'settings'])
            AcpCommand(name: n, description: 'Does $n'),
        ],
      ),
    );
    await session.sendBlocks(const [TextBlock('first queued')]);
    await session.sendBlocks(const [TextBlock('second queued')]);

    final e = await historyEnv();
    await pumpUnder(tester, e, AgentSessionScreen(key: ObjectKey(session), session: session), size: const Size(360, 800));
    tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 2);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(SessionChipsRow), findsOneWidget);
    expect(find.byType(QueuedMessages), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '/');
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    final palette = tester.getRect(find.byType(CommandPalette));
    final field = tester.getRect(find.byType(TextField).last);
    expect(palette.height, greaterThan(100), reason: 'at least two matches have room to be read');
    expect(palette.bottom, lessThanOrEqualTo(field.top), reason: 'the palette ends above the field, over nothing');
    expect(find.text('first queued'), findsNothing, reason: 'the queue steps aside while a command is picked');
    expect(find.text('Claude Sonnet 5.5'), findsNothing);

    await tester.enterText(find.byType(TextField).last, 'a plain message');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('first queued'), findsOneWidget, reason: 'and comes back when it is a message again');
    expect(find.text('Claude Sonnet 5.5'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    await e.tearDown(tester);
  });
}
