// The offer to make an agent readable as a chat: herdr's hook is installed only
// after the person confirms it, and what herdr answers is told.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/ui/core/controls.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/core/toast.dart';
import 'package:herdr_mobile/ui/features/pane/connect_chat.dart';

import '../support/create_harness.dart';
import '../support/fake_transport.dart';
import '../support/herdr_stub.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _button(String label) => find.byWidgetPredicate((w) => w is AppButton && w.label == label);

Future<(CreateHarness, HerdrStub)> _open(WidgetTester tester, {String target = 'claude'}) async {
  final h = await CreateHarness.create([
    (
      profile: profileOf('a', 'workstation'),
      snapshot: snapshotJson(
        workspaces: const [(id: 'w1', label: 'api')],
        panes: [(id: 'w1:p0', ws: 'w1', agent: target, status: 'idle')],
      ),
    ),
  ], waitOnline: false);
  final machine = h.connection('a');
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      navigatorObservers: [ToastRouteObserver()],
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showConnectChat(context, machine, 'w1:p0', target),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await _settle(tester);
  return (h, h.stubs['a']!);
}

void main() {
  testWidgets('it says what will be changed where, and installs nothing until confirmed', (tester) async {
    final (h, t) = await _open(tester);

    expect(find.text('Set up chat for Claude Code'), findsOneWidget);
    expect(find.textContaining('hook to ~/.claude on workstation'), findsOneWidget);
    expect(find.textContaining('~/.claude'), findsOneWidget);
    expect(t.paramsOf('integration.install'), isEmpty);

    await tester.tap(_button('Cancel'));
    await _settle(tester);
    expect(t.paramsOf('integration.install'), isEmpty, reason: 'cancel changes nothing');
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });

  testWidgets('confirming installs once and tells what herdr said', (tester) async {
    final (h, t) = await _open(tester, target: 'codex');
    t.on['integration.install'] = (_) => {
          'type': 'integration_install',
          'target': 'codex',
          'details': {
            'messages': ['Installed the Codex hook', 'Restart Codex'],
          },
        };

    await tester.tap(_button('Install herdr hook'));
    await _settle(tester);

    expect(t.paramsOf('integration.install'), [
      {'target': 'codex'},
    ]);
    expect(find.textContaining('Installed on workstation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    h.dispose();
  });

  testWidgets('an old herdr is told to run the command itself', (tester) async {
    final (h, t) = await _open(tester);
    t.on['integration.install'] = (_) => throw unknownMethod('integration.install');

    await tester.tap(_button('Install herdr hook'));
    await _settle(tester);

    expect(find.textContaining('too old'), findsOneWidget);
    expect(find.textContaining('herdr integration install claude'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    h.dispose();
  });
}
