import 'package:flutter/widgets.dart';

import 'app_localizations.dart';
import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';

final _english = AppLocalizationsEn();
final _japanese = AppLocalizationsJa();

extension AppLocalizationContext on BuildContext {
  /// Also supports individual widgets rendered outside HerdrMobileApp.
  AppLocalizations get l10n =>
      AppLocalizations.of(this) ?? (Localizations.maybeLocaleOf(this)?.languageCode == 'ja' ? _japanese : _english);
}
