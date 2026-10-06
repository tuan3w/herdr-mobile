import 'package:flutter/material.dart';

import 'boot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await configureSystemUi();
  runApp(await bootApp());
}
