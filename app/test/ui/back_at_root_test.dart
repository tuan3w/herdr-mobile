import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/task_mover.dart';
import 'package:herdr_mobile/ui/core/theme.dart';
import 'package:herdr_mobile/ui/shell/home_shell.dart';
import 'package:provider/provider.dart';

import 'ui_harness.dart';

/// Back at the app's root: while agents are watched it sends the app to the
/// background instead of finishing it (which would end the connections the
/// "Watching" notice stands for).
void main() {
  late int systemPops;
  late List<bool> moveAnswers;
  late int moves;

  setUp(() {
    systemPops = 0;
    moves = 0;
    moveAnswers = [];
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') systemPops++;
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<bool> fakeMove() async {
    moves++;
    return moveAnswers.isEmpty ? true : moveAnswers.removeAt(0);
  }

  Future<UiHarness> pumpShell(WidgetTester tester, {bool withMover = true}) async {
    final h = await UiHarness.create([]);
    tester.view
      ..physicalSize = const Size(360, 740) * 2
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.machines),
          ChangeNotifierProvider.value(value: h.fleet),
          ChangeNotifierProvider.value(value: h.terminalSettings),
          ChangeNotifierProvider.value(value: h.appSettings),
          ChangeNotifierProvider.value(value: h.agentScreens),
          Provider<PanePreviews>.value(value: h.previews),
          attentionSetProvider(),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: HomeShell(moveToBackground: withMover ? fakeMove : null),
        ),
      ),
    );
    await settle(tester);
    return h;
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('not watching: Back leaves the app as it always did', (tester) async {
    final h = await pumpShell(tester);
    await back(tester);
    expect(systemPops, 1);
    expect(moves, 0);
    await teardownUi(tester, h);
  });

  testWidgets('watching: Back moves the app to the background and does not finish it', (tester) async {
    final h = await pumpShell(tester);
    h.fleet.keepAliveInBackground = true;
    await tester.pump();
    await back(tester);
    expect(moves, 1);
    expect(systemPops, 0);
    await teardownUi(tester, h);
  });

  testWidgets('the watching ending puts Back back to leaving the app', (tester) async {
    final h = await pumpShell(tester);
    h.fleet.keepAliveInBackground = true;
    await tester.pump();
    h.fleet.keepAliveInBackground = false;
    await tester.pump();
    await back(tester);
    expect(moves, 0);
    expect(systemPops, 1);
    await teardownUi(tester, h);
  });

  testWidgets('a task that cannot be moved falls back to leaving, so Back is never dead', (tester) async {
    moveAnswers = [false];
    final h = await pumpShell(tester);
    h.fleet.keepAliveInBackground = true;
    await tester.pump();
    await back(tester);
    expect(moves, 1);
    expect(systemPops, 1);
    await teardownUi(tester, h);
  });

  testWidgets('a pushed screen pops first; only Back at the root goes to the background', (tester) async {
    final h = await pumpShell(tester);
    h.fleet.keepAliveInBackground = true;
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('pane'))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('pane'), findsOneWidget);

    await back(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('pane'), findsNothing);
    expect(moves, 0, reason: 'the pushed screen took the Back');
    expect(systemPops, 0);

    await back(tester);
    expect(moves, 1);
    expect(systemPops, 0);
    await teardownUi(tester, h);
  });

  testWidgets('without a mover (tests, other platforms) Back is untouched even while watching', (tester) async {
    final h = await pumpShell(tester, withMover: false);
    h.fleet.keepAliveInBackground = true;
    await tester.pump();
    await back(tester);
    expect(systemPops, 1);
    await teardownUi(tester, h);
  });

  group('PlatformTaskMover', () {
    const channel = MethodChannel(PlatformTaskMover.channelName);

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('asks Android on Android and reports its answer', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return true;
      });
      expect(await const PlatformTaskMover().moveToBack(), isTrue);
      expect(calls, ['moveTaskToBack']);
    });

    test('a failing channel is a false, never a throw', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => throw PlatformException(code: 'x'));
      expect(await const PlatformTaskMover().moveToBack(), isFalse);
    });

    test('other platforms never ask', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var asked = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        asked = true;
        return true;
      });
      expect(await const PlatformTaskMover().moveToBack(), isFalse);
      expect(asked, isFalse);
    });
  });
}
