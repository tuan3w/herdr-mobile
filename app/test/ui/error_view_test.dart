import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/error_view.dart';
import 'package:herdr_mobile/ui/core/theme.dart';

class _Throws extends StatelessWidget {
  const _Throws();

  @override
  Widget build(BuildContext context) => throw StateError('the row had no text');
}

void main() {
  testWidgets('a row that fails to build is one readable row, not a screenful, and the rows around it stay', (tester) async {
    final before = ErrorWidget.builder;
    // The binding insists on the builder being the original at the end of the test body.
    ErrorWidget.builder = compactErrorView;
    tester.view
      ..physicalSize = const Size(360, 740) * 2
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ListView(
            children: const [Text('before'), _Throws(), Text('after')],
          ),
        ),
      ),
    );
    expect(tester.takeException(), isA<StateError>());

    expect(find.textContaining('Couldn’t draw this'), findsOneWidget);
    expect(find.textContaining('the row had no text'), findsOneWidget);
    expect(find.text('before'), findsOneWidget);
    expect(find.text('after'), findsOneWidget, reason: 'the failed row does not take the room of the ones after it');
    expect(tester.getSize(find.textContaining('Couldn’t draw this')).height, lessThan(100));
    ErrorWidget.builder = before;
  });
}
