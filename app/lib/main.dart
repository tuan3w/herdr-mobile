import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'boot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(await bootApp());
}
