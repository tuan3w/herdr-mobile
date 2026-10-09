import 'package:flutter/material.dart';

import 'boot.dart';
import 'ui/core/error_view.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installErrorReporting();
  await configureSystemUi();
  await launchApp();
}
