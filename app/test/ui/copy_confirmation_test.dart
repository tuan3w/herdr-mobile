// One copy, one confirmation: where the system says "Copied to clipboard" the
// app stays quiet about a plain copy.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/system_clipboard.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/files/file_widgets.dart';

Future<void> pump(WidgetTester tester, String done) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      navigatorObservers: [ToastRouteObserver()],
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () => copyToClipboard(context, 'x', done), child: const Text('copy')),
        ),
      ),
    ),
  );
  await tester.tap(find.text('copy'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  tearDown(() => SystemClipboard.confirms = false);

  testWidgets('the app says Copied itself when the system does not', (tester) async {
    SystemClipboard.confirms = false;
    await pump(tester, 'Copied');
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('a plain Copied is left to the system where it confirms', (tester) async {
    SystemClipboard.confirms = true;
    await pump(tester, 'Copied');
    expect(find.text('Copied'), findsNothing);
  });

  testWidgets('words that say more than Copied still show where the system confirms', (tester) async {
    SystemClipboard.confirms = true;
    await pump(tester, 'Copied as Markdown');
    expect(find.text('Copied as Markdown'), findsOneWidget);
  });

  test('detect keeps the default off where there is no Android channel', () async {
    SystemClipboard.confirms = false;
    await SystemClipboard.detect();
    expect(SystemClipboard.confirms, isFalse);
  });
}
