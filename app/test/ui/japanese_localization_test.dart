import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/models/remote_file.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/notifier.dart';
import 'package:herdr_mobile/data/words/elapsed.dart';
import 'package:herdr_mobile/l10n/app_localizations.dart';
import 'package:herdr_mobile/l10n/app_localizations_en.dart';
import 'package:herdr_mobile/l10n/app_localizations_ja.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/composer/composer_frame.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/files/file_thumb.dart';
import 'package:herdr_mobile/ui/features/files/file_widgets.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/features/settings/settings_screen.dart';
import 'package:provider/provider.dart';

import '../support/fake_fs.dart';
import '../support/files_support.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/settings_support.dart';
import '../support/shot.dart' show loadAppFonts, shoot;
import 'board_support.dart';
import 'ui_harness.dart';

Widget _app(ValueNotifier<Locale> locale, {Brightness brightness = Brightness.light, double scale = 1}) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
        ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
        ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
        Provider<Notifier>.value(value: const NullNotifier()),
      ],
      child: ValueListenableBuilder<Locale>(
        valueListenable: locale,
        builder: (_, language, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: brightness == Brightness.dark ? AppTheme.dark() : AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          locale: language,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const SettingsScreen(),
        ),
      ),
    );

/// Named `.png`: the browser decides what is a picture by name, so these bytes
/// are never decoded. A folder of them is what the grid count is read on.
const _png = 'x';

void main() {
  setUpAll(loadAppFonts);
  if (Platform.environment['HERDR_JA_SHOTS'] == '1') {
    final out = Directory('/tmp/herdr-ja-shots')..createSync(recursive: true);
    for (final brightness in Brightness.values) {
      for (final size in [const Size(412, 892), const Size(320, 640)]) {
        for (final scale in [1.0, 1.6]) {
          final name = '${brightness.name}-${size.width.toInt()}-$scale';
          testWidgets('Japanese settings render $name', (tester) async {
            final locale = ValueNotifier(const Locale('ja'));
            addTearDown(locale.dispose);
            await shoot(
              tester,
              _app(locale, brightness: brightness, scale: scale),
              '${out.path}/settings-$name.png',
              brightness: brightness,
              size: size,
              pump: (tester) => openSettingsGroup(tester, '外観'),
            );
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }

  testWidgets('Japanese controls retain the selected theme across a locale change', (tester) async {
    final locale = ValueNotifier(const Locale('ja', 'JP'));
    addTearDown(locale.dispose);
    await tester.pumpWidget(_app(locale));
    await tester.pumpAndSettle();
    for (final label in ['設定', '外観', 'エージェント', '通知', 'ストレージ', 'このアプリについて']) {
      expect(find.text(label), findsOneWidget);
    }
    await openSettingsGroup(tester, '外観');
    expect(find.text('文字サイズ'), findsOneWidget);
    expect(find.text('自動'), findsOneWidget);
    await tester.tap(find.text('ダーク'));
    await tester.pumpAndSettle();
    final settings = tester.element(find.byType(SettingsScreen)).read<AppSettings>();
    expect(settings.theme, ThemeChoice.dark);
    locale.value = const Locale('en');
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(settings.theme, ThemeChoice.dark);
    expect(tester.takeException(), isNull);
  });
  testWidgets('an unsupported language falls back to English', (tester) async {
    final locale = ValueNotifier(const Locale('fr'));
    addTearDown(locale.dispose);
    await tester.pumpWidget(_app(locale));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Look'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('Japanese counts and freshness', () {
    final ja = AppLocalizationsJa();
    final en = AppLocalizationsEn();

    test('the count resources say the Japanese words and keep the English plurals', () {
      expect(ja.machinesHealth(2, 5), '5台中2台');
      expect(ja.machineCount(1), 'マシン1台');
      expect(ja.machineCount(5), 'マシン5台');
      expect(ja.agentCount(3), 'エージェント3件');
      expect(ja.agentCountCompact(3), '3件');
      expect(ja.statusNeedsYou(1), '対応待ち1件');
      expect(ja.statusNeedsYou(2), '対応待ち2件');
      expect(ja.statusToReview(2), '確認待ち2件');
      expect(ja.statusWorking(4), '実行中4件');
      expect(ja.statusNotConnected(1), '未接続1件');
      expect(ja.machinesNotConnected(2), '未接続2台');
      expect(ja.allMachinesOff, '全マシン停止');
      expect(ja.noAgents, 'エージェントなし');
      expect(ja.heardJustNow, 'たった今応答');
      expect(ja.heardAgo(Elapsed.compact(const Duration(minutes: 3), seconds: false, l10n: ja)), '最終応答：3分前');

      expect(en.machineCount(1), '1 machine');
      expect(en.machineCount(2), '2 machines');
      expect(en.agentCount(1), '1 agent');
      expect(en.agentCount(2), '2 agents');
      expect(en.agentCountCompact(1), '1 agent');
      expect(en.agentCountCompact(2), '2 agents');
      expect(en.machinesHealth(1, 2), '1 of 2 machines');
      expect(en.statusNeedsYou(1), '1 needs you');
      expect(en.statusNeedsYou(2), '2 need you');
      expect(en.heardJustNow, 'heard just now');
      expect(en.heardAgo('3m'), 'heard 3m ago');
    });

    test('the remaining count resources say Japanese and keep the English plurals', () {
      expect(ja.messageOfNeedsYou(3, 2), '対応待ち3件中2件目');
      expect(en.messageOfNeedsYou(3, 2), '2 of 3 need you');
      expect(en.messageOfNeedsYou(1, 1), '1 of 1 needs you');
      expect(ja.messageForgetRemembered(3), '保存済みのメッセージ3件を削除');
      expect(ja.messageForgetRemembered(1), '保存済みのメッセージ1件を削除');
      expect(en.messageForgetRemembered(1), 'Forget 1 remembered message');
      expect(en.messageForgetRemembered(3), 'Forget 3 remembered messages');
      expect(ja.messageWorkingThereWillStop(2), 'ここで実行中のエージェント2体は停止します。');
      expect(en.messageWorkingThereWillStop(1), '1 agent working there will stop. ');
      expect(ja.messageRunningThereWillLoseTheFolder(1), 'ここで実行中の携帯セッション1件はフォルダーを失います。');
      expect(en.messageRunningThereWillLoseTheFolder(2), '2 phone sessions running there will lose the folder. ');
      expect(ja.messageHiddenItemCount(2), '非表示の項目2件');
      expect(en.messageHiddenItemCount(2), '2 hidden items');
      expect(ja.messageAgentsWorkingHereAWorktreeKeepsThemApart(2), 'ここでエージェント2体が作業中 · worktreeなら分けて実行できます');
      expect(
        en.messageAgentsWorkingHereAWorktreeKeepsThemApart(1),
        '1 agent working here · a worktree keeps them apart',
      );
      expect(ja.messageWorkspaceCount(2), 'ワークスペース2件');
      expect(en.messageWorkspaceCount(2), '2 workspaces');
      expect(ja.messageConnectedHerdrVersion('1.2.3'), '接続済み · herdr 1.2.3');
      expect(en.messageConnectedHerdrVersion('1.2.3'), 'Connected · herdr 1.2.3');
      expect(ja.messageHostKey('SHA256:abc'), 'ホスト鍵 SHA256:abc');
      expect(en.messageHostKey('SHA256:abc'), 'Host key SHA256:abc');
    });

    test('file errors translate app-owned words and keep the host message', () {
      final notFound = describeFileError(RemoteFileException(RemoteFileErrorKind.notFound, 'raw'), 'notes.md', ja);
      expect(notFound.title, '見つかりません');
      expect(notFound.message, 'notes.mdはもうありません。移動または削除された可能性があります。');
      expect(
        describeFileError(RemoteFileException(RemoteFileErrorKind.notFound, 'raw'), 'notes.md', en).title,
        'Not found',
      );

      final failed = describeFileError(RemoteFileException(RemoteFileErrorKind.failed, 'permission denied'), 'x', ja);
      expect(failed.title, 'これを読み取れませんでした');
      expect(failed.message, 'permission denied');
    });

    test('the compact elapsed labels use Japanese units and keep English', () {
      expect(Elapsed.compact(Duration.zero, seconds: false, l10n: ja), '1分未満');
      expect(Elapsed.compact(const Duration(minutes: 59), seconds: false, l10n: ja), '59分');
      expect(Elapsed.compact(const Duration(hours: 1, minutes: 5), seconds: false, l10n: ja), '1時間5分');
      expect(Elapsed.compact(const Duration(days: 3), seconds: false, l10n: ja), '3日');

      expect(Elapsed.compact(Duration.zero, seconds: false, l10n: en), '<1m');
      expect(Elapsed.compact(const Duration(minutes: 59), seconds: false, l10n: en), '59m');
      expect(Elapsed.compact(const Duration(hours: 1, minutes: 5), seconds: false, l10n: en), '1h 05m');
      expect(Elapsed.compact(const Duration(days: 3), seconds: false, l10n: en), '3d');
      expect(Elapsed.compact(const Duration(hours: 23, minutes: 59), seconds: false), '23h 59m');
    });

    testWidgets('the board says its counts and freshness in Japanese', (tester) async {
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: 'a', label: 'solo', host: 'a.example', username: 'dev'),
          snapshot: snapshotWith([
            (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
            (id: 'w1:p2', ws: 'w1', agent: 'claude', status: 'working'),
          ]),
        ),
      ]);
      await pumpUi(tester, h, locale: const Locale('ja'), height: 1600);

      expect(find.text('1台中1台'), findsOneWidget);
      expect(find.textContaining('対応待ち1件', findRichText: true), findsOneWidget);
      expect(find.textContaining('実行中1件', findRichText: true), findsOneWidget);
      expect(find.textContaining('たった今応答', findRichText: true), findsOneWidget);
      expect(find.textContaining(' needs you', findRichText: true), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('the machines screen counts machines and agents in Japanese', (tester) async {
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: 'a', label: 'solo', host: 'a.example', username: 'dev'),
          snapshot: snapshotWith([
            (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'working'),
            (id: 'w1:p2', ws: 'w1', agent: 'codex', status: 'idle'),
          ]),
        ),
      ]);
      await pumpUi(tester, h, locale: const Locale('ja'), height: 1600);
      await tester.tap(find.byKey(const ValueKey('machine-health')));
      await settle(tester);

      expect(find.text('マシン1台'), findsOneWidget);
      expect(find.textContaining('エージェント2件', findRichText: true), findsOneWidget);
      expect(find.textContaining(' machines', findRichText: true), findsNothing);
      await teardownUi(tester, h);
    });

    testWidgets('a narrow machine row keeps the agent count visible', (tester) async {
      final h = await UiHarness.create([
        (
          profile: const MachineProfile(id: 'a', label: 'solo', host: 'a.example', username: 'dev'),
          snapshot: snapshotWith([
            (id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked'),
            (id: 'w1:p2', ws: 'w1', agent: 'claude', status: 'working'),
            (id: 'w1:p3', ws: 'w1', agent: 'codex', status: 'idle'),
          ]),
        ),
      ]);
      await pumpUi(tester, h, locale: const Locale('ja'), width: 320, textScale: 1.6, height: 1600);
      await tester.tap(find.byKey(const ValueKey('machine-health')));
      await settle(tester);

      // The long "エージェント3件" gives way to the number, not the other way
      // around: the count is what the person is looking for.
      expect(find.textContaining('エージェント3件', findRichText: true), findsNothing);
      expect(find.textContaining('3件', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
      await teardownUi(tester, h);
    });
  });

  group('Japanese file and pane words', () {
    final ja = AppLocalizationsJa();
    final en = AppLocalizationsEn();

    /// The file browser on [path], in the phone's Japanese.
    Future<void> pumpBrowser(WidgetTester tester, FakeFs fs, String path) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
            ChangeNotifierProvider(create: (_) => TerminalSettings(MemoryTerminalSettingsStore())),
            ChangeNotifierProvider(create: (_) => NotificationSettings(MemoryNotificationStore())),
          ],
          // A fresh key per call: a second folder in one test must not inherit
          // the first one's view model.
          child: MaterialApp(
            key: UniqueKey(),
            debugShowCheckedModeBanner: false,
            theme: AppTheme.light(),
            locale: const Locale('ja'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: FileBrowserScreen(
              machine: machineWithFiles(fs),
              path: path,
              clock: () => DateTime.utc(2026, 5, 20, 12),
              thumbs: ThumbLoader(),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    String list(
      AppLocalizations l10n, {
      bool failed = false,
      String path = '/home/dev/notes',
      int shown = 0,
      int hidden = 0,
      int base = 0,
      bool filtered = false,
      bool folders = false,
      bool pickFile = false,
    }) => fileCountLine(
      l10n,
      failed: failed,
      path: path,
      shown: shown,
      hidden: hidden,
      base: base,
      filtered: filtered,
      folders: folders,
      pickFile: pickFile,
    );

    test('the list count says Japanese, groups digits and keeps the English plurals', () {
      expect(list(ja, shown: 1, base: 1), '1件');
      expect(list(ja, shown: 1234, base: 1234), '1,234件');
      expect(list(ja, shown: 2, base: 2, folders: true), 'フォルダー2件');
      expect(list(ja, shown: 5, base: 1234, filtered: true), '全1,234件中5件');
      expect(list(ja, shown: 1, base: 1, filtered: true, folders: true), '全1件中1件のフォルダー');
      expect(list(ja, shown: 15, base: 15, hidden: 3), '15件 · 非表示3件');
      expect(list(ja, shown: 0, base: 1, hidden: 1), '0件 · 非表示1件');
      // A search or "changed in the last hour" says what it found of the whole
      // folder. The hidden count speaks for files that are not in the list, so
      // a filtered line drops it rather than saying it twice.
      expect(list(ja, shown: 3, base: 8, hidden: 2, filtered: true), '全8件中3件');
      expect(list(ja, shown: 0, base: 9, filtered: true), '全9件中0件');
      expect(list(ja, shown: 2, base: 2, hidden: 1, folders: true), 'フォルダー2件 · 非表示1件');
      expect(list(ja, shown: 2, base: 2, pickFile: true), '2件 · ファイルを選択');

      expect(list(en, shown: 1, base: 1), '1 item');
      expect(list(en, shown: 3, base: 3), '3 items');
      expect(list(en, shown: 2, base: 2, folders: true), '2 folders');
      expect(list(en, shown: 5, base: 1234, filtered: true), '5 of 1,234 items');
      expect(list(en, shown: 15, base: 15, hidden: 3), '15 items · 3 hidden');
      expect(list(en, shown: 0, base: 1, hidden: 1), '0 items · 1 hidden');
      expect(list(en, shown: 3, base: 8, hidden: 2, filtered: true), '3 of 8 items');
      expect(list(en, shown: 0, base: 9, filtered: true), '0 of 9 items');
      expect(list(en, shown: 2, base: 2, hidden: 1, folders: true), '2 folders · 1 hidden');
      expect(list(en, shown: 2, base: 2, pickFile: true), '2 items · choose a file');
    });

    test('an unreadable folder shows the path as the host gave it', () {
      // The path is the host's, not the app's: it is never re-worded or wrapped.
      expect(list(ja, failed: true, path: '/home/dev/日本語 の メモ', shown: 2, base: 2), '/home/dev/日本語 の メモ');
      expect(list(en, failed: true, path: '/home/dev/日本語 の メモ', shown: 2, base: 2), '/home/dev/日本語 の メモ');
    });

    testWidgets('a folder the phone may not read offers its way out in Japanese', (tester) async {
      const secret = '/home/dev/secret';
      final fs = FakeFs()
        ..addDir(secret)
        ..deny.add(secret);
      await pumpBrowser(tester, fs, secret);

      // The title, the retry and the way out are one panel: none of them may
      // stay English next to the others.
      expect(find.text('権限がありません'), findsOneWidget);
      expect(find.text('再試行'), findsOneWidget);
      expect(find.text('親フォルダーを開く'), findsOneWidget);
      expect(find.text('Open parent'), findsNothing);

      await pumpBrowser(tester, fs, '/home/dev/gone');
      expect(find.text('見つかりません'), findsOneWidget);
      expect(find.text('上へ'), findsOneWidget);
      expect(find.text('Go up'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    test('the photo grid count says Japanese and says where the folders went', () {
      expect(photoCountLine(ja, photos: 1, folders: 0), '写真1枚');
      expect(photoCountLine(ja, photos: 1200, folders: 0), '写真1,200枚');
      expect(photoCountLine(ja, photos: 1, folders: 1), '写真1枚 · フォルダー1件はリスト内');
      expect(photoCountLine(ja, photos: 1200, folders: 3), '写真1,200枚 · フォルダー3件はリスト内');

      expect(photoCountLine(en, photos: 1, folders: 0), '1 photo');
      expect(photoCountLine(en, photos: 2, folders: 0), '2 photos');
      expect(photoCountLine(en, photos: 1, folders: 1), '1 photo · 1 folder in list');
      expect(photoCountLine(en, photos: 2, folders: 3), '2 photos · 3 folders in list');
    });

    test('the composer hint follows the phone and keeps its English default', () {
      // The argument is optional, and the two callers that pass no l10n (the
      // chat composer and the reply sheet) keep the English they shipped with.
      expect(composerHint(null), 'Type a command…');
      expect(composerHint('Claude'), 'Message Claude…');

      expect(composerHint(null, l10n: ja), 'コマンドを入力…');
      expect(composerHint('Claude', l10n: ja), 'Claudeにメッセージ…');
      expect(composerHint(null, l10n: en), 'Type a command…');
      expect(composerHint('Claude', l10n: en), 'Message Claude…');

      // What is in the way wins, in the same language.
      expect(composerHint('Claude', linkWord: ja.uiOfflineReconnecting, l10n: ja), 'オフライン · 再接続中');
    });

    test('every connection state has its own Japanese word', () {
      const words = {
        LinkState.connecting: '接続中…',
        LinkState.online: 'オンライン',
        LinkState.reconnecting: '再接続中…',
        LinkState.attention: '対応が必要',
        LinkState.disabled: '無効',
        LinkState.offline: 'オフライン',
        LinkState.approval: '承認待ち',
      };
      // A state added later has no word here, so this fails instead of passing
      // on a screen that would say nothing about it.
      expect(words.keys.toSet(), LinkState.values.toSet(), reason: 'every state is worded');
      for (final MapEntry(key: state, value: word) in words.entries) {
        expect(state.labelFor(ja), word);
      }
    });

    testWidgets('the file browser counts a Japanese folder in Japanese', (tester) async {
      const root = '/home/dev/notes';
      final fs = FakeFs()
        ..addDir('$root/sub')
        ..addFile('$root/日本語のメモ.txt', 'メモ\n')
        ..addFile('$root/.env', 'SECRET=1\n');
      await pumpBrowser(tester, fs, root);

      // Two things to see (a folder and a file), one hidden: the words are the
      // app's, the names are the host's.
      expect(find.text('2件 · 非表示1件'), findsOneWidget);
      expect(find.textContaining(' items', findRichText: true), findsNothing);
      expect(find.textContaining('hidden', findRichText: true), findsNothing);
      expect(find.textContaining('日本語のメモ.txt', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the photo grid says its count in Japanese and says where the folders went', (tester) async {
      const root = '/home/dev/camera';
      final fs = FakeFs()..addDir('$root/trips');
      // Well above the number of pictures a grid needs, so this test is about
      // the words, not about the toggle appearing.
      for (var i = 1; i <= 12; i++) {
        fs.addFile('$root/IMG_$i.png', _png);
      }
      await pumpBrowser(tester, fs, root);

      await tester.tap(find.byIcon(HerdrIcons.pictures));
      await settle(tester);

      expect(find.text('写真12枚 · フォルダー1件はリスト内'), findsOneWidget);
      expect(find.textContaining(' photos', findRichText: true), findsNothing);
      expect(find.textContaining('folders in list', findRichText: true), findsNothing);
      expect(tester.takeException(), isNull);
    });

    /// The pane screen for pane 1 of a one-machine fleet, in the phone's
    /// Japanese until a test says otherwise.
    Future<({BoardHarness h, ValueNotifier<Locale> locale})> pumpPane(WidgetTester tester) async {
      final h = await BoardHarness.create([
        (
          profile: const MachineProfile(id: 'm', label: 'box', host: 'h', username: 'u'),
          snapshot: snapshotWith([(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')]),
        ),
      ]);
      tester.view
        ..physicalSize = const Size(412, 892)
        ..devicePixelRatio = 1;
      final locale = ValueNotifier(const Locale('ja'));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        h.dispose();
        locale.dispose();
      });
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: h.providers,
          child: ValueListenableBuilder<Locale>(
            valueListenable: locale,
            builder: (_, language, _) => MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.dark(),
              locale: language,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const PaneScreen(agent: PaneAgent('m', 'w1:p1')),
            ),
          ),
        ),
      );
      await settle(tester);
      return (h: h, locale: locale);
    }

    testWidgets('the pane screen says its offline state and hint in Japanese, then in English', (tester) async {
      final (:h, :locale) = await pumpPane(tester);

      // The phone loses its radio: the banner and what the composer is waiting
      // for are the app's words, in the phone's language.
      h.network.goOffline();
      await settle(tester);
      expect(find.text('オフライン'), findsWidgets);
      expect(find.text('オフライン · 再接続中'), findsOneWidget);

      locale.value = const Locale('en');
      await settle(tester);
      expect(find.text('オフライン'), findsNothing);
      expect(find.text('Offline · reconnecting'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pane on an offline machine says why, and keeps the machine name', (tester) async {
      final (:h, locale: _) = await pumpPane(tester);
      h.network.goOffline();
      await settle(tester);

      await tester.tap(find.byTooltip('ペインの操作'));
      await settle(tester);

      expect(find.text('複製'), findsOneWidget);
      // `box` is the host's name for the machine: it is not translated.
      expect(find.text('boxはオフラインです'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
