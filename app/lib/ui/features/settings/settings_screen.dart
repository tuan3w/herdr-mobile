import 'package:herdr_mobile/l10n/l10n_context.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/app_info.dart';
import '../../../data/repositories/app_settings.dart';
import '../../../data/repositories/app_update.dart';
import '../../../data/repositories/notification_settings.dart';
import '../../../data/repositories/quick_phrases.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../../data/services/disk_cache.dart';
import '../../../data/services/notifier.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../support/open_link.dart';
import '../files/file_format.dart';
import '../kit/kit_screen.dart';
import 'font_size_control.dart';
import 'quick_phrases_editor.dart';
import 'release_history_screen.dart';
import 'settings_group.dart';
import 'update_group.dart';

/// The groups of Settings, top to bottom. The page opens one at a time.
enum _Open { look, agents, notifications, storage, about }

/// Settings, a page over home opened from its header's gear: five groups (Look, Agents, Notifications, Storage, About), each
/// a row that says what it is set to and opens in place, one at a time, with
/// a newer version's row above them (it opens the update sheet). Everything
/// here applies at once and is remembered.
///
/// Why groups, not a long page: the page was about 1,800 dp, and every new
/// setting made the next one harder to find. Five rows fit one screen at normal
/// text size (at 2x on 320 dp the last one scrolls); a group grows without
/// lengthening the page.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.update});

  /// Looks for and installs a newer version; null where the app cannot (not
  /// Android, tests), and the screen then shows nothing about updates.
  final AppUpdate? update;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Closed on every visit: one group opens at a time, on a tap. Each visit is
  // a new page that opens at its top, so a newer version's Update row, the
  // first row, is in view when the gear's dot brings the person here. (As a
  // tab the page kept its place, and had to scroll itself back to that row.)
  _Open? _open;

  void _openUpdate(AppUpdate update) => unawaited(showUpdateSheet(context, update));

  void _toggle(_Open group) => setState(() => _open = _open == group ? null : group);

  @override
  Widget build(BuildContext context) {
    final update = widget.update;
    return Scaffold(
      backgroundColor: context.ds.bg,
      body: CustomScrollView(
        primary: true,
        slivers: [
          SliverLargeTitle.back(title: context.l10n.uiSettings),
          // Each group draws its own hairline (it opens in place), so the
          // groups are custom rows that bring their own separation. Built
          // whole, not lazily: five groups, and an opening group measures
          // the one above it to scroll itself into view.
          SliverToBoxAdapter(
            child: RowColumn(
              rows: [
                if (update != null)
                  CustomRow(
                    id: 'update',
                    child: UpdateGroup(update: update, onOpen: () => _openUpdate(update)),
                  ),
                CustomRow(
                  id: 'look',
                  child: _LookGroup(open: _open == _Open.look, onToggle: () => _toggle(_Open.look)),
                ),
                CustomRow(
                  id: 'agents',
                  child: _AgentsGroup(open: _open == _Open.agents, onToggle: () => _toggle(_Open.agents)),
                ),
                CustomRow(
                  id: 'notifications',
                  child: _NotificationsGroup(
                    open: _open == _Open.notifications,
                    onToggle: () => _toggle(_Open.notifications),
                  ),
                ),
                CustomRow(
                  id: 'storage',
                  child: _StorageGroup(open: _open == _Open.storage, onToggle: () => _toggle(_Open.storage)),
                ),
                CustomRow(
                  id: 'about',
                  child: _AboutGroup(update: update, open: _open == _Open.about, onToggle: () => _toggle(_Open.about)),
                ),
                GapRow(id: 'clearance', height: MediaQuery.paddingOf(context).bottom + Gap.xl),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// How the app and the terminal look: theme, the terminal's
/// size and wrapping, and how an answer is shown.
class _LookGroup extends StatelessWidget {
  const _LookGroup({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  static String _theme(BuildContext context, ThemeChoice choice) => switch (choice) {
    ThemeChoice.light => context.l10n.uiLight,
    ThemeChoice.dark => context.l10n.uiDark,
    ThemeChoice.system => context.l10n.uiSystem,
  };

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppSettings>();
    final terminal = context.read<TerminalSettings>();
    final theme = context.select<AppSettings, ThemeChoice>((s) => s.theme);
    final smoothText = context.select<AppSettings, bool>((s) => s.smoothText);
    final darkTerminal = context.select<AppSettings, bool>((s) => s.darkTerminal);
    final wrap = context.select<TerminalSettings, bool>((s) => s.wrap);
    final fontSize = context.select<TerminalSettings, double>((s) => s.fontSize);
    return SettingsGroup(
      icon: HerdrIcons.look,
      title: context.l10n.uiLook,
      summary: context.l10n.messagePt(_theme(context, theme), FontSizeControl.format(fontSize)),
      open: open,
      onToggle: onToggle,
      rows: [
        CustomRow(
          id: 'theme',
          child: SettingsField(
            title: context.l10n.uiTheme,
            child: Segmented<ThemeChoice>(
              options: [
                SegmentOption(ThemeChoice.light, context.l10n.uiLight, icon: LucideIcons.sun),
                SegmentOption(ThemeChoice.dark, context.l10n.uiDark, icon: LucideIcons.moon),
                SegmentOption(ThemeChoice.system, context.l10n.uiSystem, icon: LucideIcons.smartphone),
              ],
              value: theme,
              onChanged: (next) => unawaited(settings.setTheme(next)),
            ),
          ),
        ),
        const CustomRow(
          id: 'font-size',
          child: Padding(
            padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, Gap.sm),
            child: FontSizeControl(),
          ),
        ),
        ToggleRow(
          id: 'wrap',
          title: context.l10n.uiWrapLongLines,
          subtitle: context.l10n.uiFitLinesToTheScreenInsteadOfScrollingSideways,
          value: wrap,
          onChanged: (next) => unawaited(terminal.setWrap(next)),
        ),
        ToggleRow(
          id: 'dark-terminal',
          title: context.l10n.uiDarkTerminal,
          subtitle: context.l10n.uiKeepItDarkWhenTheAppIsLight,
          value: darkTerminal,
          onChanged: (next) => unawaited(settings.setDarkTerminal(next)),
        ),
        ToggleRow(
          id: 'smooth-text',
          title: context.l10n.uiSmoothText,
          subtitle: context.l10n.uiShowAnswersAtAnEvenPaceNotInBursts,
          value: smoothText,
          onChanged: (next) => unawaited(settings.setSmoothText(next)),
        ),
      ],
    );
  }
}

/// How an agent opens, and the one-tap phrases for talking to one.
class _AgentsGroup extends StatelessWidget {
  const _AgentsGroup({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppSettings>();
    final openAs = context.select<AppSettings, OpenAgentsAs>((s) => s.openAgentsAs);
    // Absent where the app runs without them (tests).
    final phrases = context.watch<QuickPhrases?>()?.phrases.length;
    final opens = openAs == OpenAgentsAs.chat ? context.l10n.uiOpensAsChat : context.l10n.uiOpensAsTerminal;
    return SettingsGroup(
      icon: HerdrIcons.agents,
      title: context.l10n.uiAgents,
      summary: phrases == null ? opens : '$opens \u00b7 ${context.l10n.phraseCount(phrases)}',
      open: open,
      onToggle: onToggle,
      rows: [
        CustomRow(
          id: 'open-as',
          child: SettingsField(
            title: context.l10n.uiOpenAgentsAs,
            hint: openAs == OpenAgentsAs.chat
                ? context.l10n.uiAgentsOpenAsAChatHint
                : context.l10n.uiARunningAgentOpensAsItsTerminal,
            child: Segmented<OpenAgentsAs>(
              options: [
                SegmentOption(OpenAgentsAs.chat, context.l10n.uiChat, icon: HerdrIcons.message),
                SegmentOption(OpenAgentsAs.terminal, context.l10n.uiTerminal, icon: LucideIcons.terminal),
              ],
              value: openAs,
              onChanged: (next) => unawaited(settings.setOpenAgentsAs(next)),
            ),
          ),
        ),
        if (phrases != null)
          ActionRow(
            id: 'quick-phrases',
            title: context.l10n.uiQuickPhrases,
            value: '$phrases',
            chevron: true,
            onTap: () => unawaited(
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QuickPhrasesPage())),
            ),
          ),
      ],
    );
  }
}

/// Local notifications: off until the person turns them on, which asks Android
/// for the permission first. The notifications themselves are posted by the
/// app (`AttentionNotifier`), nothing leaves the phone.
///
/// The row is always built, so it can say "Blocked by Android" with the group
/// closed: it checks the permission when the page opens, not when the group
/// does.
class _NotificationsGroup extends StatefulWidget {
  const _NotificationsGroup({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  @override
  State<_NotificationsGroup> createState() => _NotificationsGroupState();
}

class _NotificationsGroupState extends State<_NotificationsGroup> {
  /// Android refused (or was taken back) the permission the switch needs.
  bool _blocked = false;
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    // Switched on earlier, then blocked in the system settings: say so.
    if (context.read<NotificationSettings>().enabled) unawaited(_checkPermission());
  }

  Future<void> _checkPermission() async {
    final permission = await context.read<Notifier>().permission();
    if (mounted && permission == NotifyPermission.denied) setState(() => _blocked = true);
  }

  Future<void> _setEnabled(bool next) async {
    final settings = context.read<NotificationSettings>();
    if (!next) {
      setState(() => _blocked = false);
      await settings.setEnabled(false);
      return;
    }
    if (_asking) return;
    _asking = true;
    final NotifyPermission permission;
    try {
      permission = await context.read<Notifier>().requestPermission();
    } finally {
      _asking = false;
    }
    if (permission == NotifyPermission.granted) {
      if (mounted) setState(() => _blocked = false);
      await settings.setEnabled(true);
    } else if (mounted) {
      setState(() => _blocked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final settings = context.read<NotificationSettings>();
    final enabled = context.select<NotificationSettings, bool>((s) => s.enabled);
    final alsoDone = context.select<NotificationSettings, bool>((s) => s.alsoDone);
    return SettingsGroup(
      icon: _blocked ? HerdrIcons.notificationsOff : HerdrIcons.notifications,
      // The orange that means "needs you", only while it does.
      tint: _blocked ? ds.blocked : null,
      title: context.l10n.uiNotifications,
      summary: _blocked
          ? context.l10n.uiBlockedByAndroid
          : !enabled
          ? context.l10n.uiOff69
          : alsoDone
          ? context.l10n.uiWhenAnAgentNeedsMeOrFinishes
          : context.l10n.uiWhenAnAgentNeedsMe,
      open: widget.open,
      onToggle: widget.onToggle,
      rows: [
        if (_blocked)
          CustomRow(
            id: 'blocked',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, Gap.xs),
              child: StatusPanel(
                color: ds.blocked,
                icon: HerdrIcons.notificationsOff,
                liveRegion: true,
                message: context.l10n.uiAndroidIsBlockingNotificationsForHerdrAllowThemIn,
              ),
            ),
          ),
        ToggleRow(
          id: 'notify',
          title: context.l10n.uiNotifyMeWhenAnAgentNeedsMe,
          value: enabled,
          onChanged: (next) => unawaited(_setEnabled(next)),
        ),
        ToggleRow(
          id: 'also-done',
          title: context.l10n.uiAlsoWhenAnAgentFinishes,
          value: alsoDone,
          enabled: enabled,
          onChanged: (next) => unawaited(settings.setAlsoDone(next)),
        ),
        NoteRow(id: 'watching', text: context.l10n.uiWhileAgentsWorkOrAPageFromAMachine),
      ],
    );
  }
}

class _StorageGroup extends StatefulWidget {
  const _StorageGroup({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  @override
  State<_StorageGroup> createState() => _StorageGroupState();
}

class _StorageGroupState extends State<_StorageGroup> {
  late Future<int> _size = DiskCache.shared.totalBytes();
  Listenable? _tab;

  /// The size is read again whenever the person can see it again: when the tab
  /// comes back (the shell keeps this screen alive for the whole run, so the
  /// first reading would otherwise stand for good) and when the group opens.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tab = TickerMode.getValuesNotifier(context);
    if (identical(tab, _tab)) return;
    _tab?.removeListener(_onTab);
    _tab = tab..addListener(_onTab);
  }

  @override
  void didUpdateWidget(_StorageGroup old) {
    super.didUpdateWidget(old);
    if (!old.open && widget.open) _refresh();
  }

  @override
  void dispose() {
    _tab?.removeListener(_onTab);
    super.dispose();
  }

  void _onTab() {
    // The tab's tickers switch while the shell builds: ask after it.
    if (TickerMode.getValuesNotifier(context).value.enabled) scheduleMicrotask(_refresh);
  }

  void _refresh() {
    final size = DiskCache.shared.totalBytes();
    if (mounted) {
      setState(() {
        _size = size;
      });
    }
  }

  Future<void> _clear() async {
    final toaster = Toaster.of(context);
    final words = context.l10n;
    final freed = await DiskCache.shared.clear();
    toaster.show(freed == 0 ? words.uiNothingToClear : words.messageCleared(formatBytes(freed)));
    _refresh();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: _size,
    builder: (context, snapshot) {
      final bytes = snapshot.data;
      return SettingsGroup(
        icon: HerdrIcons.storage,
        title: context.l10n.uiStorage,
        summary: bytes == null
            ? context.l10n.uiCache
            : bytes == 0
            ? context.l10n.uiCacheEmpty
            : context.l10n.messageCache(formatBytes(bytes)),
        open: widget.open,
        onToggle: widget.onToggle,
        rows: [
          EntityRow(
            id: 'clear-cache',
            title: context.l10n.uiClearCache,
            titleMaxLines: 1,
            subtitle: context.l10n.uiCopiesOfWhatYouLookedAtOnYourMachines,
            subtitleMaxLines: 4,
            trailing: Icon(LucideIcons.trash2, size: IconSize.row, color: context.ds.textTertiary),
            // A plain tap is the right guard: all of it can be downloaded again.
            onTap: () => unawaited(_clear()),
          ),
        ],
      );
    },
  );
}

class _AboutGroup extends StatelessWidget {
  const _AboutGroup({this.update, required this.open, required this.onToggle});

  final AppUpdate? update;
  final bool open;
  final VoidCallback onToggle;

  static const _repoLabel = 'github.com/tuan3w/herdr-mobile · GPL-3.0';

  /// The notice GPL-3.0 section 5(d) asks an interactive program to show.
  static const _legalese =
      'Copyright © 2026 Tuan Nguyen. herdr mobile is free '
      'software under the GNU General Public License v3.0, and comes with no '
      'warranty. Its source is at github.com/tuan3w/herdr-mobile.';

  Future<void> _openRepo(BuildContext context) async {
    final toaster = Toaster.of(context);
    final openFailed = context.l10n.uiCouldnTOpenOnThisPhoneNoBrowserCould;
    if (!await openInBrowser(appRepositoryUrl)) {
      toaster.show(openFailed, kind: ToastKind.failed);
    }
  }

  void _openLicenses(BuildContext context) => showLicensePage(
    context: context,
    applicationName: 'herdr mobile',
    applicationVersion: appVersion,
    applicationLegalese: _legalese,
  );

  @override
  Widget build(BuildContext context) {
    final update = this.update;
    return SettingsGroup(
      icon: HerdrIcons.about,
      title: context.l10n.uiAbout,
      // A newer version is said once, on its own row at the top.
      summary: context.l10n.messageVersion(appVersion),
      open: open,
      onToggle: onToggle,
      divider: false,
      // Hidden: holding the version opens the kit catalog, in every build.
      onLongPress: () =>
          unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const KitScreen()))),
      rows: [
        if (update != null)
          CustomRow(
            id: 'updates',
            dividerIndent: Gap.gutter,
            child: _UpdateRows(update: update),
          ),
        EntityRow(
          id: 'connection',
          title: context.l10n.uiConnection,
          titleMaxLines: 1,
          subtitleMaxLines: 8,
          subtitle: update == null
              ? context.l10n.uiTalksToHerdrOverSSHAndSendsNothingAnywhere
              : context.l10n.uiTalksToHerdrOverSSHTheOnlyOtherPlace,
        ),
        EntityRow(
          id: 'whatsnew',
          title: context.l10n.uiWhatSNew,
          titleMaxLines: 1,
          subtitle: context.l10n.messageTheNotesOfEveryReleaseUpTo(appVersion),
          subtitleMaxLines: 2,
          trailing: Icon(LucideIcons.chevronRight, size: IconSize.row, color: context.ds.textTertiary),
          onTap: () => unawaited(openReleaseHistory(context)),
        ),
        EntityRow(
          id: 'source',
          title: context.l10n.uiSourceCode,
          titleMaxLines: 1,
          subtitle: _repoLabel,
          subtitleMaxLines: 2,
          trailing: Icon(LucideIcons.externalLink, size: IconSize.row, color: context.ds.textTertiary),
          onTap: () => unawaited(_openRepo(context)),
        ),
        EntityRow(
          id: 'licenses',
          title: context.l10n.uiLicenses,
          titleMaxLines: 1,
          trailing: Icon(LucideIcons.chevronRight, size: IconSize.row, color: context.ds.textTertiary),
          onTap: () => _openLicenses(context),
        ),
      ],
    );
  }
}

/// Looking for a newer version: the check, and whether it happens by itself.
/// What a newer version offers is the row at the top of the screen.
class _UpdateRows extends StatelessWidget {
  const _UpdateRows({required this.update});

  final AppUpdate update;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: update,
    builder: (context, _) {
      final ds = context.ds;
      final release = update.release;
      final checking = update.stage == UpdateStage.checking;
      final problem = update.checkProblem;
      final subtitle = checking
          ? 'Asking github.com\u2026'
          : problem ??
                (release != null
                    ? 'Version ${release.version} is available, at the top of this page.'
                    : update.upToDate
                    ? 'You have the latest version.'
                    : 'Asks github.com for the newest release.');
      return RowColumn(
        rows: [
          EntityRow(
            id: 'check',
            title: context.l10n.uiCheckForUpdates,
            titleMaxLines: 1,
            subtitle: subtitle,
            subtitleMaxLines: 4,
            subtitleColor: problem != null ? ds.dangerText : null,
            trailing: checking
                ? const BusySpinner(size: IconSize.bar)
                : Icon(LucideIcons.refreshCw, size: IconSize.row, color: ds.textTertiary),
            onTap: update.stage == UpdateStage.idle ? () => unawaited(update.check()) : null,
          ),
          ToggleRow(
            id: 'auto-check',
            title: context.l10n.uiCheckAutomatically,
            subtitle: context.l10n.uiAsksGithubComAboutTwiceADayWhileYou,
            value: update.autoCheck,
            onChanged: (on) => unawaited(update.setAutoCheck(on)),
          ),
        ],
      );
    },
  );
}
