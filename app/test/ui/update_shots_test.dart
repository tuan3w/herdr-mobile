// Renders Settings to PNGs for review: the four groups (closed, each open, the
// update row open, downloading behind another group, Android blocking
// notifications), the update states and the tab bar mark. Light and dark, 412 dp
// at text scale 1 and 1.6, and 320 dp at 2 for the groups. Off by default; it
// writes files:
//
//   UPDATE_SHOTS=1 flutter test test/ui/update_shots_test.dart
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/app_update.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/apk_installer.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:herdr_mobile/ui/features/settings/update_group.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/fake_notifier.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart';
import '../support/update_fakes.dart';

const _notes = '''
### Updates inside the app

- Settings can look for a newer version on GitHub, download it, check it and hand it to Android's installer.
- A quiet dot on the Settings tab says one is waiting. Nothing else changes until you open Settings.

### Answers are safer

- A cut-off command is held like any long one, and "bypass permissions" needs a second step.
''';

final _release = ReleaseInfo(
  version: '0.1.7',
  apkUrl: 'https://github.com/tuan3w/herdr-mobile/releases/download/v0.1.7/herdr-mobile-0.1.7.apk',
  size: 48 * 1024 * 1024 + 300000,
  pageUrl: 'https://github.com/tuan3w/herdr-mobile/releases/tag/v0.1.7',
  notes: _notes,
  sha256: 'a' * 64,
);

void main() {
  if (Platform.environment['UPDATE_SHOTS'] == null) {
    test('update shots are off (set UPDATE_SHOTS=1)', () {}, skip: 'set UPDATE_SHOTS=1 to render PNGs');
    return;
  }
  final out = Platform.environment['UPDATE_SHOTS_DIR'] ?? '/tmp/update_shots';
  setUpAll(() async {
    await loadAppFonts();
    Directory(out).createSync(recursive: true);
  });

  Future<AppUpdate> make(FakeReleaseFeed feed, FakeReleaseFiles files) async {
    final update = AppUpdate(
      store: MemoryUpdateStore(),
      feed: feed,
      files: files,
      installer: FakeApkInstaller()..answer = InstallStart.needsPermission,
      current: AppVersion.tryParse('0.1.6'),
    );
    addTearDown(update.dispose);
    return update;
  }

  final states = <String, Future<void> Function(AppUpdate u, FakeReleaseFeed f, FakeReleaseFiles fl)>{
    'checking-none': (u, f, fl) async {},
    'uptodate': (u, f, fl) async => u.check(),
    'check-failed': (u, f, fl) async {
      f.error = const UpdateException('Could not reach GitHub. Check the connection and try again.');
      await u.check();
    },
    'available': (u, f, fl) async {
      f.answer = _release;
      await u.check();
    },
    'downloading': (u, f, fl) async {
      f.answer = _release;
      await u.check();
      unawaited(u.download());
      fl.report(20 * 1024 * 1024 + 100000);
    },
    'ready': (u, f, fl) async {
      f.answer = _release;
      await u.check();
      final d = u.download();
      fl.running!.complete(File('/x.apk'));
      await d;
    },
    'permission': (u, f, fl) async {
      f.answer = _release;
      await u.check();
      final d = u.download();
      fl.running!.complete(File('/x.apk'));
      await d;
      await u.install();
    },
    'download-failed': (u, f, fl) async {
      f.answer = _release;
      await u.check();
      final d = u.download();
      fl.running!.completeError(const UpdateException(
        'The download stopped at 31 MB of 48 MB. It continues from there when you try again.',
      ));
      await d;
    },
  };

  for (final dark in [false, true]) {
    // `shoot` fixes the surface at 412x892; text scale 1.6 is the stress.
    for (final scale in [1.0, 1.6]) {
      for (final MapEntry(key: name, value: setup) in states.entries) {
        if (dark && !{'available', 'downloading'}.contains(name)) continue;
        testWidgets('$name ${dark ? 'dark' : 'light'} x$scale', (tester) async {
          final feed = FakeReleaseFeed();
          final files = FakeReleaseFiles();
          final update = await make(feed, files);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await setup(update, feed, files);
          await shoot(
            tester,
            SettingsScreen(update: update),
            '$out/$name-${dark ? 'dark' : 'light'}-x$scale.png',
            brightness: dark ? Brightness.dark : Brightness.light,
            wrap: (app) => MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
                ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
                ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
                Provider<Notifier>.value(value: const NullNotifier()),
              ],
              child: app,
            ),
            // The three states that differ only in About's check row.
            pump: (t) async {
              if (const {'checking-none', 'uptodate', 'check-failed'}.contains(name)) {
                await openSettingsGroup(t, 'About');
              }
            },
          );
        });
      }
    }
  }

  // Settings as the person meets it: the four groups, one open at a time, a
  // newer version's row on top and open. [taps] are what is tapped, in order,
  // before the capture.
  for (final dark in [false, true]) {
    for (final (size, scale) in [(phone, 1.0), (const Size(320, 640), 2.0)]) {
      final tag = '${dark ? 'dark' : 'light'}-${size.width.toInt()}-x$scale';
      final cases = <String, ({List<String> taps, bool update, bool blocked, bool downloading})>{
        'groups-update-open': (taps: [], update: true, blocked: false, downloading: false),
        'groups-update-closed': (taps: ['Update available'], update: true, blocked: false, downloading: false),
        'groups-downloading': (taps: ['Look'], update: true, blocked: false, downloading: true),
        'groups-quiet': (taps: [], update: false, blocked: false, downloading: false),
        'groups-look': (taps: ['Look'], update: false, blocked: false, downloading: false),
        'groups-agents': (taps: ['Agents'], update: false, blocked: false, downloading: false),
        'groups-notifications-blocked': (taps: ['Notifications'], update: false, blocked: true, downloading: false),
        'groups-about': (taps: ['About'], update: true, blocked: false, downloading: false),
      };
      for (final MapEntry(key: name, value: c) in cases.entries) {
        testWidgets('$name $tag', (tester) async {
          final feed = FakeReleaseFeed();
          final files = FakeReleaseFiles();
          final update = await make(feed, files);
          if (c.update) {
            feed.answer = _release;
            await update.check();
          }
          if (c.downloading) {
            unawaited(update.download());
            files.report(20 * 1024 * 1024 + 100000);
          }
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final notifications = NotificationSettings(MemoryNotificationStore(NotificationChoice(enabled: c.blocked)));
          await notifications.load();
          final phrases = QuickPhrases(MemoryQuickPhrasesStore(['continue', 'yes, go ahead', 'run the tests']));
          await phrases.load();
          await shoot(
            tester,
            SettingsScreen(update: c.update ? update : null),
            '$out/$name-$tag.png',
            brightness: dark ? Brightness.dark : Brightness.light,
            size: size,
            wrap: (app) => MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
                ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
                ChangeNotifierProvider.value(value: notifications),
                ChangeNotifierProvider.value(value: phrases),
                Provider<Notifier>.value(value: c.blocked ? FakeNotifier(granted: false) : const NullNotifier()),
              ],
              child: app,
            ),
            pump: (t) async {
              for (final label in c.taps) {
                await openSettingsGroup(t, label);
              }
            },
          );
        });
      }
    }
  }

  testWidgets('notes sheet', (tester) async {
    await shoot(
      tester,
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => unawaited(showReleaseNotes(context, _release)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      '$out/notes.png',
      pump: (t) async {
        await t.tap(find.text('open'));
        await t.pump(const Duration(milliseconds: 600));
      },
    );
  });

  testWidgets('tab bar mark', (tester) async {
    await shoot(
      tester,
      const Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: 80),
            child: FloatingTabBar(
              index: 0,
              onChanged: _noop,
              tabs: [
                TabSpec(icon: LucideIcons.bot, label: 'Agents', badge: 2),
                TabSpec(icon: LucideIcons.server, label: 'Machines'),
                TabSpec(icon: LucideIcons.settings, label: 'Settings', mark: true, markLabel: 'update available'),
              ],
            ),
          ),
        ),
      ),
      '$out/tabbar.png',
    );
  });
}

void _noop(int _) {}
