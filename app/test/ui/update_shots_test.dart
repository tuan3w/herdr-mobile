// Renders the update panel (Settings, top), the About rows and the tab bar mark
// to PNGs for review: every state, light and dark, 412 and 320 dp wide, text
// scale 1 and 1.6. Off by default; it writes files:
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
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/apk_installer.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/data/services/release_feed.dart';
import 'package:herdr_mobile/data/services/release_files.dart';
import 'package:herdr_mobile/ui/core/chrome.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:herdr_mobile/ui/features/settings/update_panel.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/shot.dart';

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

class _Feed implements ReleaseFeed {
  ReleaseInfo? answer;
  Object? error;

  @override
  Future<ReleaseInfo?> newerThan(AppVersion current) async {
    if (error != null) throw error!;
    return answer;
  }
}

class _Files implements ReleaseFiles {
  Completer<File>? job;

  @override
  Future<bool> intact(ReleaseInfo release, File apk) async => true;
  void Function(int)? report;

  @override
  Future<File?> verified(ReleaseInfo release) async => null;

  @override
  Future<void> prune({ReleaseInfo? keep}) async {}

  @override
  UpdateDownload download(ReleaseInfo release, void Function(int) onProgress) {
    report = onProgress;
    final c = job = Completer<File>();
    return UpdateDownload(c.future, () => c.completeError(const UpdateCancelled()));
  }
}

class _Installer implements ApkInstaller {
  @override
  Future<InstallStart> install(File apk) async => InstallStart.needsPermission;
}

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

  Future<AppUpdate> make(_Feed feed, _Files files) async {
    final update = AppUpdate(
      store: MemoryUpdateStore(),
      feed: feed,
      files: files,
      installer: _Installer(),
      current: AppVersion.tryParse('0.1.6'),
    );
    addTearDown(update.dispose);
    return update;
  }

  final states = <String, Future<void> Function(AppUpdate u, _Feed f, _Files fl)>{
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
      fl.report!(20 * 1024 * 1024 + 100000);
    },
    'ready': (u, f, fl) async {
      f.answer = _release;
      await u.check();
      final d = u.download();
      fl.job!.complete(File('/x.apk'));
      await d;
    },
    'permission': (u, f, fl) async {
      f.answer = _release;
      await u.check();
      final d = u.download();
      fl.job!.complete(File('/x.apk'));
      await d;
      await u.install();
    },
    'download-failed': (u, f, fl) async {
      f.answer = _release;
      await u.check();
      final d = u.download();
      fl.job!.completeError(const UpdateException(
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
          final feed = _Feed();
          final files = _Files();
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
            pump: (t) async {
              if (name == 'available') {
                // The About rows, the other half of the feature.
                await t.drag(find.byType(CustomScrollView), const Offset(0, -3000));
                await t.pump(const Duration(milliseconds: 300));
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
