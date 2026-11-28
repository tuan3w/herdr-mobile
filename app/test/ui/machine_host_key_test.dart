// A machine whose host key changed cannot be fixed by trying again: the app
// never replaces a key it trusted, so every Retry fails the same way. The words
// tell the person to add the machine again, so the way out must be on the row and
// on the machine's own screen: Remove, with the same hold as the menu's Remove.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart' show hostKeyChangedMessage;
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:provider/provider.dart';

import '../support/shot.dart' show loadAppFonts;
import 'hold_support.dart';
import 'ui_harness.dart';

HerdrTransport _noTransport(
  MachineProfile profile,
  MachineSecrets secrets,
  void Function(String) onPin,
  void Function(String) onNotice,
) => throw StateError('this test never opens a connection');

const _changed = HerdrTransportException(hostKeyChangedMessage, fatal: true);
const _denied = HerdrTransportException('Permission denied (publickey).', fatal: true);

MachineProfile _m(String id, String label) =>
    MachineProfile(id: id, label: label, host: 'h.example', username: 'dev', auth: SshAuth.password);

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<UiHarness> _pump(WidgetTester tester) async {
  final h = await UiHarness.create([
    (profile: _m('key', 'staging'), snapshot: snapshotWith(const [])),
    (profile: _m('pw', 'laptop'), snapshot: snapshotWith(const [])),
  ]);
  h.transports['key']!.failure = _changed;
  h.fleet.connection('key')!.reconnect();
  h.transports['pw']!.failure = _denied;
  h.fleet.connection('pw')!.reconnect();
  tester.view
    ..physicalSize = const Size(360, 740) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<TransportFactory>.value(value: _noTransport),
        ChangeNotifierProvider.value(value: h.machines),
        ChangeNotifierProvider.value(value: h.fleet),
        attentionSetProvider(),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const MachinesScreen()),
    ),
  );
  await _flush(tester);
  return h;
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('a changed host key offers Remove on its row, other failures keep Retry', (tester) async {
    final h = await _pump(tester);

    expect(find.text('Retry'), findsOneWidget, reason: 'only the machine with another problem can try again');
    expect(
      find.text('Remove'),
      findsOneWidget,
      reason: 'the changed key has nothing to retry: it is removed and added',
    );

    // The one delete flow: a confirm sheet naming the machine, then a hold.
    await tester.tap(find.text('Remove'));
    await _flush(tester);
    expect(find.text('Remove staging?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await _flush(tester);
    expect(h.machines.machines.map((m) => m.id), ['key', 'pw'], reason: 'cancelling keeps it');

    await tester.tap(find.text('Remove'));
    await _flush(tester);
    await holdFor(tester, find.byType(HoldToConfirm));
    await _flush(tester);
    expect(h.machines.machines.map((m) => m.id), ['pw']);
    expect(find.text('staging'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });

  testWidgets('the machine’s own screen offers the same Remove and leaves once it is done', (tester) async {
    final h = await _pump(tester);

    await tester.tap(find.text('staging'));
    await _flush(tester);
    expect(find.byType(MachineScreen), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.tap(find.text('Remove'));
    await _flush(tester);
    expect(find.text('Remove staging?'), findsOneWidget);
    await holdFor(tester, find.byType(HoldToConfirm));
    await _flush(tester);

    expect(h.machines.machines.map((m) => m.id), ['pw']);
    expect(find.byType(MachineScreen), findsNothing, reason: 'a removed machine has no screen to stay on');
    expect(find.byType(MachinesScreen), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });
}
