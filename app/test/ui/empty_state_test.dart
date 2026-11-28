import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/shot.dart' show loadAppFonts;

// An empty state may have no picture when its title already says it all
// (`No agents running`: a moon beside it said it twice). It stays centred like the
// ones with an icon, and the message keeps the gap under the title.

void main() {
  setUpAll(loadAppFonts);

  Future<void> pump(WidgetTester tester, Widget body) async {
    tester.view
      ..physicalSize = const Size(412, 892) * 2.625
      ..devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(body: body),
      ),
    );
  }

  testWidgets('without an icon the title and message are centred and nothing else is drawn', (tester) async {
    await pump(tester, const EmptyState(title: 'No agents running', message: 'Start one in herdr and it shows here.'));

    expect(tester.takeException(), isNull);
    expect(find.byType(Icon), findsNothing, reason: 'no tile when there is no icon');
    final screen = tester.getCenter(find.byType(Scaffold));
    expect(tester.getCenter(find.text('No agents running')).dx, closeTo(screen.dx, 0.5));
    expect(tester.getCenter(find.text('Start one in herdr and it shows here.')).dx, closeTo(screen.dx, 0.5));
    expect(
      tester.getCenter(find.text('No agents running')).dy,
      lessThan(tester.getCenter(find.text('Start one in herdr and it shows here.')).dy),
    );
  });

  testWidgets('with an icon it is the same column with the tile above the title', (tester) async {
    await pump(
      tester,
      const EmptyState(icon: LucideIcons.searchX, title: 'Nothing named “x”', message: 'Nothing in the folder.'),
    );

    expect(find.byIcon(LucideIcons.searchX), findsOneWidget);
    expect(
      tester.getCenter(find.byIcon(LucideIcons.searchX)).dy,
      lessThan(tester.getCenter(find.text('Nothing named “x”')).dy),
    );
    final screen = tester.getCenter(find.byType(Scaffold));
    expect(tester.getCenter(find.text('Nothing named “x”')).dx, closeTo(screen.dx, 0.5));
  });
}
