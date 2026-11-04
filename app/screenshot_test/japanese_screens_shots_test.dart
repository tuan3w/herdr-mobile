import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';

import '../test/support/shot.dart';
import 'demo_fleet.dart';

void main() {
  setUpAll(() async {
    await loadAppFonts();
    Directory('/tmp/herdr-ja-screens').createSync(recursive: true);
  });
  for (final screen in ['board', 'machines', 'machine-form']) {
    for (final brightness in Brightness.values) {
      for (final size in [const Size(320, 640), const Size(412, 892)]) {
        final name = '$screen-${brightness.name}-${size.width.toInt()}';
        testWidgets('Japanese $name at 1.6 text scale', (tester) async {
          final fleet = await DemoFleet.create();
          final home = switch (screen) {
            'board' => const HomeShell(),
            'machines' => const MachinesScreen(),
            _ => const MachineFormScreen(),
          };
          await shoot(
            tester,
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
                child: home,
              ),
            ),
            '/tmp/herdr-ja-screens/$name.png',
            locale: const Locale('ja'),
            brightness: brightness,
            size: size,
            wrap: demoProviders(fleet),
            pump: fleet.online,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          fleet.dispose();
        });
      }
    }
  }
}
