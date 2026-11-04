// The connection state's words and the reviewed toast come from the app's
// resources, so a Japanese phone reads them in Japanese; the English getters
// remain the default for code that has no BuildContext.
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/l10n/app_localizations_en.dart';
import 'package:herdr_mobile/l10n/app_localizations_ja.dart';
import 'package:herdr_mobile/ui/core/glyphs.dart';

void main() {
  final en = AppLocalizationsEn();
  final ja = AppLocalizationsJa();

  test('every link state has a Japanese label', () {
    for (final state in LinkState.values) {
      expect(state.labelFor(en), state.label);
      expect(state.labelFor(ja), isNot(state.label));
      expect(state.labelFor(ja), isNotEmpty);
    }
  });

  test('every agent status has a Japanese label', () {
    for (final status in AgentStatus.values) {
      expect(status.labelFor(en), status.label);
      expect(status.labelFor(ja), isNot(status.label));
      expect(status.labelFor(ja), isNotEmpty);
    }
  });

  test('the reviewed toast counts in the phone’s language', () {
    expect(ja.messageReviewedCount(1), isNot(en.messageReviewedCount(1)));
    expect(ja.messageReviewedCount(3), contains('3'));
  });
}
