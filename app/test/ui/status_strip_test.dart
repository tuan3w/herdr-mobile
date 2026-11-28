// A `StatusStrip` that is a button as a whole (it opens the thing it reports)
// can also carry an action of its own (`Retry`). Assistive technology must
// reach both: the strip, and the action, each one node, each doing its own thing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

void main() {
  testWidgets('the action inside a tappable strip is its own node and fires on its own', (tester) async {
    final handle = tester.ensureSemantics();
    var strip = 0;
    var retry = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatusStrip(
            color: Ds.paper.danger,
            title: 'Offline',
            detail: 'studio-mac',
            onTap: () => strip++,
            action: AppButton(label: 'Retry', compact: true, kind: AppButtonKind.secondary, onPressed: () => retry++),
          ),
        ),
      ),
    );

    final action = find.semantics.byLabel('Retry');
    expect(action, findsOne, reason: 'the action says its own name');
    expect(action.evaluate().single.label, 'Retry', reason: 'not merged into the strip\'s words');

    final whole = find.semantics.byLabel(RegExp('Offline'));
    expect(whole, findsOne);
    expect(whole.evaluate().single.label, isNot(contains('Retry')), reason: 'the strip does not repeat its action');

    tester.semantics.tap(action);
    await tester.pump();
    expect(retry, 1);
    expect(strip, 0, reason: 'the action is not the strip');

    tester.semantics.tap(whole);
    await tester.pump();
    expect(strip, 1);
    expect(retry, 1);
    handle.dispose();
  });
}
