import 'dart:ui' show IsolateNameServer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/services/local_notifier.dart';
import 'package:herdr_mobile/data/services/notifier.dart';

/// The plugin's method channel: what it sends to Android is recorded, what
/// Android answers is set by each test.
const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

class _Android {
  final calls = <MethodCall>[];

  bool initializeFails = false;
  Object? startForegroundError;
  bool? notificationsEnabled = true;
  bool? permissionAnswer = true;
  Map<String, Object?>? launch;
  List<Map<String, Object?>> active = [];

  Iterable<MethodCall> called(String method) => calls.where((c) => c.method == method);

  Map<Object?, Object?> only(String method) => called(method).single.arguments as Map<Object?, Object?>;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'initialize':
        if (initializeFails) throw PlatformException(code: 'boom');
        return true;
      case 'getNotificationAppLaunchDetails':
        return launch;
      case 'getActiveNotifications':
        return active;
      case 'areNotificationsEnabled':
        return notificationsEnabled;
      case 'requestNotificationsPermission':
        return permissionAnswer;
      case 'startForegroundService':
        if (startForegroundError != null) throw startForegroundError!;
        return null;
    }
    return null;
  }

  /// What Android sends when a notification is tapped.
  Future<void> tap(String? payload, {int type = 0}) async {
    final data = _channel.codec.encodeMethodCall(MethodCall('didReceiveNotificationResponse', {
      'notificationId': 7,
      'actionId': null,
      'input': null,
      'payload': payload,
      'notificationResponseType': type,
    }));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(_channel.name, data, (_) {});
  }
}

Map<String, Object?> _active(int id, String channelId) => {'id': id, 'channelId': channelId, 'tag': null};

AgentNotification _note({
  int id = 42,
  NotifyKind kind = NotifyKind.needsYou,
  String link = 'herdr://agent/m1/w1%3Ap1',
}) =>
    AgentNotification(id: id, kind: kind, title: 'omp needs you', body: 'Run rm -rf build?', link: link);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Android android;

  setUp(() {
    android = _Android();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, android.handle);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  Future<Notifier> start({Color? accent}) async {
    final notifier = await LocalNotifier.start(accent: accent);
    expect(notifier, isA<LocalNotifier>());
    android.calls.clear();
    return notifier;
  }

  group('starting', () {
    test('another platform gets the no-op notifier and never touches the plugin', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(await LocalNotifier.start(), isA<NullNotifier>());
      expect(android.calls, isEmpty);
    });

    test('a plugin that fails to start degrades to the no-op notifier, not to a throw', () async {
      android.initializeFails = true;
      expect(await LocalNotifier.start(), isA<NullNotifier>());
    });

    test('registers the small icon and the three channels', () async {
      await LocalNotifier.start();
      expect(android.only('initialize'), containsPair('defaultIcon', 'ic_stat_herdr'));
      final channels = {
        for (final c in android.called('createNotificationChannel'))
          (c.arguments as Map)['id'] as String: c.arguments as Map,
      };
      expect(channels.keys, ['needs_you', 'finished', 'watching']);
      expect(channels['needs_you']!['importance'], Importance.high.value);
      expect(channels['finished']!['importance'], Importance.defaultImportance.value);
      expect(channels['finished']!['playSound'], isFalse);
      expect(channels['watching']!['importance'], Importance.min.value);
      expect(channels['watching']!['showBadge'], isFalse);
      expect(channels['watching']!['playSound'], isFalse);
    });
  });

  group('showing', () {
    test('a question goes to the loud channel, keyed by the agent, carrying its link', () async {
      final notifier = await start(accent: const Color(0xFF5E6AD2));
      await notifier.show(_note());
      final shown = android.only('show');
      expect(shown['id'], 42);
      expect(shown['title'], 'omp needs you');
      expect(shown['body'], 'Run rm -rf build?');
      expect(shown['payload'], 'herdr://agent/m1/w1%3Ap1');
      final details = shown['platformSpecifics'] as Map;
      expect(details['channelId'], 'needs_you');
      expect(details['importance'], Importance.high.value);
      expect(details['groupKey'], 'agents');
      expect(details['autoCancel'], isTrue);
      expect(details['onlyAlertOnce'], isTrue);
      expect(details['icon'], 'ic_stat_herdr');
      expect([details['colorRed'], details['colorGreen'], details['colorBlue']], [0x5E, 0x6A, 0xD2]);
      expect(details['when'], isA<int>());
    });

    test('a finished agent goes to the quiet channel', () async {
      final notifier = await start();
      await notifier.show(_note(kind: NotifyKind.finished));
      final details = android.only('show')['platformSpecifics'] as Map;
      expect(details['channelId'], 'finished');
      expect(details['importance'], Importance.defaultImportance.value);
      expect(details['playSound'], isFalse);
    });

    test('the same agent shows under the same id, so it replaces its earlier notification', () async {
      final notifier = await start();
      final id = notificationIdFor('m1|w1:p1');
      await notifier.show(_note(id: id));
      await notifier.show(_note(id: id, kind: NotifyKind.finished));
      expect(android.called('show').map((c) => (c.arguments as Map)['id']), [id, id]);
    });
  });

  group('cancelling', () {
    test('cancel removes one agent notification', () async {
      final notifier = await start();
      await notifier.cancel(42);
      expect(android.only('cancel'), {'id': 42, 'tag': null});
    });

    test('cancelAll removes every agent notification and keeps the Watching notice', () async {
      android.active = [
        _active(11, 'needs_you'),
        _active(watchingNotificationId, watchingChannelId),
        _active(12, 'finished'),
      ];
      final notifier = await start();
      await notifier.cancelAll();
      expect(android.called('cancel').map((c) => (c.arguments as Map)['id']), [11, 12]);
      expect(android.called('cancelAll'), isEmpty, reason: 'the plugin-wide cancel takes the notice too');
    });

    test('the Watching notice is recognised by its channel on any id, and by its id without one', () async {
      android.active = [_active(99, watchingChannelId), {'id': watchingNotificationId, 'channelId': null}];
      final notifier = await start();
      await notifier.cancelAll();
      expect(android.called('cancel'), isEmpty);
    });

    test('cancel never cancels the Watching notice', () async {
      final notifier = await start();
      await notifier.cancel(watchingNotificationId);
      expect(android.called('cancel'), isEmpty);
    });
  });

  group('the Watching notice', () {
    Map<Object?, Object?> started() => android.called('startForegroundService').last.arguments as Map;
    Map<Object?, Object?> data() => started()['notificationData'] as Map<Object?, Object?>;

    test('starts a quiet special-use foreground service that says how many agents', () async {
      final notifier = await start();
      expect(await notifier.setWatching(2), isTrue);
      expect(data()['id'], watchingNotificationId);
      expect(data()['title'], 'Watching 2 agents');
      expect(data()['body'], '2 working');
      final details = data()['platformSpecifics'] as Map;
      expect(details['channelId'], watchingChannelId);
      expect(details['importance'], Importance.min.value);
      expect(details['ongoing'], isTrue);
      expect(details['silent'], isTrue);
      expect(details['autoCancel'], isFalse);
      expect(started()['foregroundServiceTypes'], [AndroidServiceForegroundType.foregroundServiceTypeSpecialUse.value]);
      expect(started()['startType'], AndroidServiceStartType.startNotSticky.index,
          reason: 'a killed process must not leave a notice nothing backs');
    });

    test('a new count updates the text; the same numbers ask Android nothing', () async {
      final notifier = await start();
      await notifier.setWatching(1);
      expect(data()['title'], 'Watching 1 agent');
      expect(data()['body'], '1 working');
      await notifier.setWatching(1);
      expect(android.called('startForegroundService'), hasLength(1));
      await notifier.setWatching(3);
      expect(android.called('startForegroundService'), hasLength(2));
      expect(data()['title'], 'Watching 3 agents');
    });

    test('the line under the title says how many need you and how many work', () async {
      final notifier = await start();
      await notifier.setWatching(5, blocked: 2);
      expect(data()['title'], 'Watching 5 agents');
      expect(data()['body'], '2 need you · 3 working');
      // The same total with another split is a new line.
      await notifier.setWatching(5, blocked: 2);
      expect(android.called('startForegroundService'), hasLength(1));
      await notifier.setWatching(5, blocked: 1);
      expect(android.called('startForegroundService'), hasLength(2));
      expect(data()['body'], '1 needs you · 4 working');
    });

    test('parts that are zero are left out, and the words agree with the numbers', () {
      expect(watchingSummary(1, 0), '1 working');
      expect(watchingSummary(4, 0), '4 working');
      expect(watchingSummary(1, 1), '1 needs you');
      expect(watchingSummary(3, 3), '3 need you');
      expect(watchingSummary(2, 1), '1 needs you · 1 working');
      expect(watchingSummary(5, 2), '2 need you · 3 working');
      expect(watchingSummary(2, 9), '2 need you', reason: 'more blocked than watched cannot make a negative part');
      expect(watchingSummary(2, -1), '2 working');
    });

    test('zero stops the service, and the next count starts it again', () async {
      final notifier = await start();
      await notifier.setWatching(2);
      expect(await notifier.setWatching(0), isFalse, reason: 'nothing is being watched');
      expect(android.called('stopForegroundService'), hasLength(1));
      await notifier.setWatching(2);
      expect(android.called('startForegroundService'), hasLength(2));
    });

    test('Android refusing the service is a false, never a throw, and is retried', () async {
      final notifier = await start();
      android.startForegroundError = PlatformException(code: 'ForegroundServiceStartNotAllowedException');
      expect(await notifier.setWatching(2), isFalse);
      android.startForegroundError = null;
      expect(await notifier.setWatching(2), isTrue, reason: 'a refusal is not remembered as success');
      expect(android.called('startForegroundService'), hasLength(2));
    });
  });

  group('permission', () {
    test('reads what Android allows', () async {
      final notifier = await start();
      expect(await notifier.permission(), NotifyPermission.granted);
      android.notificationsEnabled = false;
      expect(await notifier.permission(), NotifyPermission.denied);
      android.notificationsEnabled = null;
      expect(await notifier.permission(), NotifyPermission.denied);
    });

    test('a granted dialog is granted', () async {
      final notifier = await start();
      android.notificationsEnabled = false;
      android.permissionAnswer = true;
      expect(await notifier.requestPermission(), NotifyPermission.granted);
    });

    test('a refused dialog is denied', () async {
      final notifier = await start();
      android.notificationsEnabled = false;
      android.permissionAnswer = false;
      expect(await notifier.requestPermission(), NotifyPermission.denied);
    });

    test('before Android 13 there is no dialog: the system switch decides', () async {
      final notifier = await start();
      android.permissionAnswer = null;
      android.notificationsEnabled = true;
      expect(await notifier.requestPermission(), NotifyPermission.granted);
      android.notificationsEnabled = false;
      expect(await notifier.requestPermission(), NotifyPermission.denied);
    });
  });

  group('taps', () {
    test('a tap hands the link to the handler', () async {
      final notifier = await start();
      final links = <String>[];
      notifier.onOpen(links.add);
      await android.tap('herdr://agent/m1/w1%3Ap1');
      expect(links, ['herdr://agent/m1/w1%3Ap1']);
    });

    test('a tap before the handler exists waits for it, once', () async {
      final notifier = await start();
      await android.tap('herdr://agent/m1/w1%3Ap1');
      final first = <String>[];
      notifier.onOpen(first.add);
      expect(first, ['herdr://agent/m1/w1%3Ap1']);
      final second = <String>[];
      notifier.onOpen(second.add);
      expect(second, isEmpty);
    });

    test('the notification that launched the app is delivered once the handler is set', () async {
      android.launch = {
        'notificationLaunchedApp': true,
        'notificationResponse': {
          'notificationId': 7,
          'actionId': null,
          'input': null,
          'notificationResponseType': 0,
          'payload': 'herdr://session/m1/k1',
          'data': <String, dynamic>{},
        },
      };
      final notifier = await LocalNotifier.start();
      final links = <String>[];
      notifier.onOpen(links.add);
      expect(links, ['herdr://session/m1/k1']);
    });

    test('an app that was not launched by a notification has nothing to deliver', () async {
      android.launch = {'notificationLaunchedApp': false};
      final notifier = await LocalNotifier.start();
      final links = <String>[];
      notifier.onOpen(links.add);
      expect(links, isEmpty);
    });

    test('a tap on the Watching notice (no link) and other responses open nothing', () async {
      final notifier = await start();
      final links = <String>[];
      notifier.onOpen(links.add);
      await android.tap('');
      await android.tap(null);
      await android.tap('herdr://agent/m1/p', type: NotificationResponseType.selectedNotificationAction.index);
      expect(links, isEmpty);
    });
  });

  group('answer buttons', () {
    const link = 'herdr://agent/m1/w1%3Ap1';
    const yes = NotificationAnswer(
        machineId: 'm1', paneId: 'w1:p1', digest: '00ff00ff00ff00ff', index: 0, nonce: 'k-1', label: '1. Yes');
    const no = NotificationAnswer(
        machineId: 'm1', paneId: 'w1:p1', digest: '00ff00ff00ff00ff', index: 2, nonce: 'k-1', label: '3. No');

    NotificationResponse pressed(NotificationAnswer a, {int id = 42}) => NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction,
          id: id,
          actionId: a.actionId,
          payload: link,
        );

    /// The press crosses a port: give the event loop a turn.
    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

    test('buttons are actions that do not open the app; the whole question is the expanded text', () async {
      final notifier = await start();
      await notifier.show(const AgentNotification(
        id: 42,
        kind: NotifyKind.needsYou,
        title: 'api',
        body: 'Do you want to proceed?\ngit push origin main\nneeds you · claude · Alpha',
        collapsed: 'git push origin main',
        link: link,
        answers: [yes, no],
      ));
      final shown = android.only('show');
      expect(shown['body'], 'git push origin main', reason: 'what a heads-up shows is the command');
      final details = shown['platformSpecifics'] as Map;
      expect((details['styleInformation'] as Map)['bigText'],
          'Do you want to proceed?\ngit push origin main\nneeds you · claude · Alpha');
      final actions = (details['actions'] as List).cast<Map>();
      expect(actions.map((a) => a['title']), ['1. Yes', '3. No']);
      expect(actions.map((a) => a['id']), [yes.actionId, no.actionId]);
      expect(actions.map((a) => a['showsUserInterface']), everyElement(isFalse));
      expect(actions.map((a) => a['cancelNotification']), everyElement(isTrue),
          reason: 'a pressed button must not stay to be pressed again');
    });

    test('never more than two buttons, and none for a notification without answers', () async {
      final notifier = await start();
      await notifier.show(const AgentNotification(
        id: 1, kind: NotifyKind.needsYou, title: 't', body: 'b', link: link, answers: [yes, no, yes]));
      expect(((android.only('show')['platformSpecifics'] as Map)['actions'] as List), hasLength(2));
      android.calls.clear();
      await notifier.show(_note());
      final plain = android.only('show')['platformSpecifics'] as Map;
      expect(plain['actions'], anyOf(isNull, isEmpty));
      expect(plain['style'], isNot(AndroidNotificationStyle.bigText.index));
    });

    test('an action id carries which option of which question, and survives odd names', () {
      const odd = NotificationAnswer(
          machineId: 'a|b c', paneId: 'w1:p%2', digest: 'deadbeefdeadbeef', index: 11, nonce: 'x|y-3');
      final back = NotificationAnswer.tryParse(odd.actionId)!;
      expect([back.machineId, back.paneId, back.digest, back.index, back.nonce],
          ['a|b c', 'w1:p%2', 'deadbeefdeadbeef', 11, 'x|y-3']);
      expect(NotificationAnswer.tryParse(null), isNull);
      expect(NotificationAnswer.tryParse('open'), isNull);
      expect(NotificationAnswer.tryParse('answer|m|p|d|x|n'), isNull, reason: 'the index is a number');
      expect(NotificationAnswer.tryParse('answer|m|p|d|-1|n'), isNull);
      expect(NotificationAnswer.tryParse('answer|m|p||1|n'), isNull, reason: 'no question named');
      expect(NotificationAnswer.tryParse('answer|%E0%A4%A|p|d|1|n'), isNull, reason: 'a broken escape');
    });

    test('a press heard by the background isolate is handled by the main isolate, once', () async {
      final notifier = await start();
      final heard = <(NotificationAnswer, int)>[];
      notifier.onAnswer((answer, id) async => heard.add((answer, id)));
      notificationActionInBackground(pressed(no));
      await settle();
      expect(heard, hasLength(1));
      expect(heard.single.$1.actionId, no.actionId);
      expect(heard.single.$2, 42);
      expect(android.called('show'), isEmpty, reason: 'the handler decides what the person is told');
    });

    test('anything that is not one of our buttons is ignored', () async {
      final notifier = await start();
      final heard = <int>[];
      notifier.onAnswer((answer, id) async => heard.add(id));
      notificationActionInBackground(const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction, id: 3, actionId: 'other'));
      notificationActionInBackground(const NotificationResponse(
          notificationResponseType: NotificationResponseType.selectedNotificationAction, id: 3));
      await settle();
      expect(heard, isEmpty);
      expect(android.called('show'), isEmpty);
    });

    test('a press with nobody to check the question sends nothing and says so', () async {
      await start();
      notificationActionInBackground(pressed(yes, id: 7));
      await settle();
      final shown = android.only('show');
      expect(shown['id'], 7);
      expect(shown['title'], answerNotSentTitle);
      expect(shown['payload'], link, reason: 'a tap opens the agent');
    });

    test('a handler that fails leaves the person told that nothing was sent', () async {
      final notifier = await start();
      notifier.onAnswer((answer, id) async => throw StateError('boom'));
      notificationActionInBackground(pressed(yes, id: 7));
      await settle();
      expect(android.only('show')['title'], answerNotSentTitle);
    });

    test('when the main isolate cannot be reached the background isolate says nothing was sent', () async {
      await start();
      IsolateNameServer.removePortNameMapping(answerPortName);
      notificationActionInBackground(pressed(yes, id: 7));
      await settle();
      final shown = android.only('show');
      expect(shown['id'], 7);
      expect(shown['title'], answerNotSentTitle);
      expect(shown['payload'], link);
    });
  });
}
