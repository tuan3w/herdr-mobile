import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/sent_phrases.dart';
import 'package:herdr_mobile/ui/features/pane/quick_phrases_row.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/memory_quick_phrases_store.dart';
import 'support/memory_sent_phrases_store.dart';
import 'support/photo_support.dart';

Future<(QuickPhrases, SentPhrases, TextEditingController)> _mount(
  WidgetTester tester, {
  List<String>? own,
  Map<String, int> sent = const {},
}) async {
  final phrases = QuickPhrases(MemoryQuickPhrasesStore(own));
  await phrases.load();
  final learned = SentPhrases(MemorySentPhrasesStore());
  await learned.load();
  for (final e in sent.entries) {
    for (var i = 0; i < e.value; i++) {
      await learned.learn(e.key);
    }
  }
  final input = TextEditingController();
  final focus = FocusNode();
  addTearDown(input.dispose);
  addTearDown(focus.dispose);
  await pumpApp(
    tester,
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: phrases),
        ChangeNotifierProvider.value(value: learned),
      ],
      child: Scaffold(
        body: Column(
          children: [
            QuickPhrasesRow(input: input, focus: focus),
            TextField(controller: input, focusNode: focus),
          ],
        ),
      ),
    ),
  );
  focus.requestFocus();
  // Focus is applied in a microtask: the row builds on the frame after it.
  await tester.pump();
  await tester.pump();
  return (phrases, learned, input);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('what you send most comes before the shipped phrases', (tester) async {
    await _mount(tester, sent: {'create pr': 3});
    final first = tester.getTopLeft(find.text('create pr')).dx;
    final second = tester.getTopLeft(find.text('continue')).dx;
    expect(first, lessThan(second));
  });

  testWidgets('a list the person edited keeps its place, learned ones follow', (tester) async {
    await _mount(tester, own: ['mine'], sent: {'create pr': 3});
    expect(tester.getTopLeft(find.text('mine')).dx, lessThan(tester.getTopLeft(find.text('create pr')).dx));
    expect(find.text('continue'), findsNothing);
  });

  testWidgets('a tap fills the box and sends nothing', (tester) async {
    final (_, learned, input) = await _mount(tester, sent: {'create pr': 2});
    await tester.tap(find.text('create pr'));
    await tester.pump();
    expect(input.text, 'create pr');
    expect(learned.tracked, 1, reason: 'filling the box is not sending: nothing was counted');
    expect(learned.chips(), ['create pr']);
  });

  testWidgets('the row leaves once there is text, and learning off hides learned chips', (tester) async {
    final (_, learned, input) = await _mount(tester, sent: {'create pr': 2});
    input.text = 'x';
    await tester.pump();
    expect(find.text('create pr'), findsNothing);
    input.clear();
    await learned.setEnabled(false);
    await tester.pump();
    expect(find.text('create pr'), findsNothing);
    expect(find.text('continue'), findsOneWidget);
  });
}
