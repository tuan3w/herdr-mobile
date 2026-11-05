import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'boot.dart';
import 'ui/support/error_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installErrorReporting();
  // The OFL asks the licence to travel with the font; read only when Settings >
  // About > Licences opens.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'HerdrSymbols (Noto Sans Symbols)',
    ], await rootBundle.loadString('assets/fonts/HerdrSymbols-OFL.txt'));
  });
  await configureSystemUi();
  await launchApp();
}
