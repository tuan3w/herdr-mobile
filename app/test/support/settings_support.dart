import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/motion.dart';

/// Opens a group of the Settings screen by its row's title. The groups start
/// closed and open one at a time; the row is scrolled to first, as a person
/// would, because an open group above it can push it off the screen.
///
/// Two pumps: the frame that starts the fold, then its whole length.
Future<void> openSettingsGroup(WidgetTester tester, String title) async {
  await tester.ensureVisible(find.text(title));
  await tester.pump();
  await tester.tap(find.text(title));
  await tester.pump();
  await tester.pump(Motion.expand + const Duration(milliseconds: 30));
}
