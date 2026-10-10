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
import '../../../data/services/notifier.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/open_link.dart';
import '../../core/rows.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import 'app_switch.dart';
import 'font_size_control.dart';
import 'quick_phrases_editor.dart';
import 'settings_group.dart';
import 'update_group.dart';

/// The groups of Settings, top to bottom. The page opens one at a time.
enum _Open { update, look, agents, notifications, about }

/// The third root tab: four groups (Look, Agents, Notifications, About), each
/// a row that says what it is set to and opens in place, one at a time, with
/// a newer version's row above them. Everything here applies at once and is
/// remembered.
///
/// Why groups, not a long page: the page was about 1,800 dp, and every new
/// setting made the next one harder to find. Four rows fit one screen at any
/// text size; a group grows without lengthening the page.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.update});

  /// Looks for and installs a newer version; null where the app cannot (not
  /// Android, tests), and the screen then shows nothing about updates.
  final AppUpdate? update;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Closed on the first visit, except that a newer version is open: it is the
  // one thing that came to the person, and Download is then one tap away, not
  // two. A version found while this tab is behind another opens it too (the
  // tab's dot is what brings the person here; the state outlives a visit). Not
  // when found while the page is showing: nothing moves under the thumb.
  late _Open? _open = widget.update?.release != null ? _Open.update : null;
  late bool _hadRelease = widget.update?.release != null;

  @override
  void initState() {
    super.initState();
    widget.update?.addListener(_onUpdate);
  }

  @override
  void didUpdateWidget(SettingsScreen old) {
    super.didUpdateWidget(old);
    if (old.update == widget.update) return;
    old.update?.removeListener(_onUpdate);
    widget.update?.addListener(_onUpdate);
  }

  @override
  void dispose() {
    widget.update?.removeListener(_onUpdate);
    super.dispose();
  }

  void _onUpdate() {
    final has = widget.update?.release != null;
    final found = has && !_hadRelease;
    _hadRelease = has;
    final showing = TickerMode.getValuesNotifier(context).value.enabled;
    if (found && !showing && mounted) setState(() => _open = _Open.update);
  }

  void _toggle(_Open group) => setState(() => _open = _open == group ? null : group);

  @override
  Widget build(BuildContext context) {
    final update = widget.update;
    return Scaffold(
      backgroundColor: context.ds.bg,
      body: CustomScrollView(
        slivers: [
          const SliverLargeTitle(title: 'Settings'),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (update != null)
                  UpdateGroup(
                    update: update,
                    open: _open == _Open.update,
                    onToggle: () => _toggle(_Open.update),
                  ),
                _LookGroup(open: _open == _Open.look, onToggle: () => _toggle(_Open.look)),
                _AgentsGroup(open: _open == _Open.agents, onToggle: () => _toggle(_Open.agents)),
                _NotificationsGroup(
                  open: _open == _Open.notifications,
                  onToggle: () => _toggle(_Open.notifications),
                ),
                _AboutGroup(
                  update: update,
                  open: _open == _Open.about,
                  onToggle: () => _toggle(_Open.about),
                ),
                SizedBox(height: FloatingBar.clearance(context) + Gap.md),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A switch row inset to the page gutter, as a group's body holds it.
class _Inset extends StatelessWidget {
  const _Inset(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.gutter), child: child);
}

/// How the app and the terminal look: theme, the agent list, the terminal's
/// size and wrapping, and how an answer is shown.
class _LookGroup extends StatelessWidget {
  const _LookGroup({required this.open, required this.onToggle});

  final bool open;
  final VoidCallback onToggle;

  static String _theme(ThemeChoice choice) => switch (choice) {
        ThemeChoice.light => 'Light',
        ThemeChoice.dark => 'Dark',
        ThemeChoice.system => 'System',
      };

  static String _density(BoardDensity density) => switch (density) {
        BoardDensity.auto => 'Auto',
        BoardDensity.cards => 'Cards',
        BoardDensity.compact => 'Compact',
      };

  @override
  Widget build(BuildContext context) {
    final settings = context.read<AppSettings>();
    final terminal = context.read<TerminalSettings>();
    final theme = context.select<AppSettings, ThemeChoice>((s) => s.theme);
    final density = context.select<AppSettings, BoardDensity>((s) => s.density);
    final smoothText = context.select<AppSettings, bool>((s) => s.smoothText);
    final darkTerminal = context.select<AppSettings, bool>((s) => s.darkTerminal);
    final wrap = context.select<TerminalSettings, bool>((s) => s.wrap);
    final fontSize = context.select<TerminalSettings, double>((s) => s.fontSize);
    return SettingsGroup(
      icon: LucideIcons.sunMoon,
      title: 'Look',
      summary: '${_theme(theme)} \u00b7 ${_density(density)} \u00b7 ${FontSizeControl.format(fontSize)} pt',
      open: open,
      onToggle: onToggle,
      children: [
        SettingsField(
          title: 'Theme',
          child: Segmented<ThemeChoice>(
            options: const [
              SegmentOption(ThemeChoice.light, 'Light', LucideIcons.sun),
              SegmentOption(ThemeChoice.dark, 'Dark', LucideIcons.moon),
              SegmentOption(ThemeChoice.system, 'System', LucideIcons.smartphone),
            ],
            value: theme,
            onChanged: (next) => unawaited(settings.setTheme(next)),
          ),
        ),
        SettingsField(
          title: 'Agent list',
          // Only where the setting hides a rule: Cards and Compact say it all.
          hint: density == BoardDensity.auto
              ? 'Cards up to ${AppSettings.autoCompactFrom - 1} agents, the compact list from '
                  '${AppSettings.autoCompactFrom}; a blocked agent always keeps its answers.'
              : null,
          child: Segmented<BoardDensity>(
            options: const [
              SegmentOption(BoardDensity.auto, 'Auto', LucideIcons.sparkles),
              SegmentOption(BoardDensity.cards, 'Cards', LucideIcons.layoutGrid),
              SegmentOption(BoardDensity.compact, 'Compact', LucideIcons.list),
            ],
            value: density,
            onChanged: (next) => unawaited(settings.setDensity(next)),
          ),
        ),
        const _Inset(Padding(padding: EdgeInsets.only(top: Gap.sm), child: FontSizeControl())),
        const SizedBox(height: Gap.sm),
        _Inset(
          SwitchRow(
            title: 'Wrap long lines',
            subtitle: 'Fit lines to the screen instead of scrolling sideways.',
            value: wrap,
            onChanged: (next) => unawaited(terminal.setWrap(next)),
          ),
        ),
        _Inset(
          SwitchRow(
            title: 'Dark terminal',
            subtitle: 'Keep it dark when the app is light.',
            value: darkTerminal,
            onChanged: (next) => unawaited(settings.setDarkTerminal(next)),
          ),
        ),
        _Inset(
          SwitchRow(
            title: 'Smooth text',
            subtitle: 'Show answers at an even pace, not in bursts.',
            value: smoothText,
            onChanged: (next) => unawaited(settings.setSmoothText(next)),
          ),
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
    final ds = context.ds;
    final settings = context.read<AppSettings>();
    final openAs = context.select<AppSettings, OpenAgentsAs>((s) => s.openAgentsAs);
    // Absent where the app runs without them (tests).
    final phrases = context.watch<QuickPhrases?>()?.phrases.length;
    final opens = openAs == OpenAgentsAs.chat ? 'Opens as chat' : 'Opens as terminal';
    return SettingsGroup(
      icon: LucideIcons.messagesSquare,
      title: 'Agents',
      summary: phrases == null ? opens : '$opens \u00b7 $phrases ${phrases == 1 ? 'phrase' : 'phrases'}',
      open: open,
      onToggle: onToggle,
      children: [
        SettingsField(
          title: 'Open agents as',
          hint: openAs == OpenAgentsAs.chat
              ? 'omp, Claude Code and Codex open as a chat when the app can find their session log; the terminal is one tap away. Any other agent, or one it cannot find, opens as a terminal.'
              : 'A running agent opens as its terminal.',
          child: Segmented<OpenAgentsAs>(
            options: const [
              SegmentOption(OpenAgentsAs.chat, 'Chat', LucideIcons.messageSquare),
              SegmentOption(OpenAgentsAs.terminal, 'Terminal', LucideIcons.terminal),
            ],
            value: openAs,
            onChanged: (next) => unawaited(settings.setOpenAgentsAs(next)),
          ),
        ),
        if (phrases != null)
          ListRow(
            title: 'Quick phrases',
            titleMaxLines: 1,
            divider: false,
            onTap: () => unawaited(Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const QuickPhrasesPage()),
            )),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$phrases', style: Type.secondary.copyWith(color: ds.textSecondary)),
                const SizedBox(width: Gap.xs),
                Icon(LucideIcons.chevronRight, size: 16, color: ds.textTertiary),
              ],
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
      icon: _blocked ? LucideIcons.bellOff : LucideIcons.bell,
      // The orange that means "needs you", only while it does.
      tint: _blocked ? ds.blocked : null,
      title: 'Notifications',
      summary: _blocked
          ? 'Blocked by Android'
          : !enabled
              ? 'Off'
              : alsoDone
                  ? 'When an agent needs me or finishes'
                  : 'When an agent needs me',
      open: widget.open,
      onToggle: widget.onToggle,
      children: [
        if (_blocked)
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.sm, Gap.gutter, Gap.xs),
            child: Semantics(
              liveRegion: true,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: ds.blockedWash,
                  borderRadius: BorderRadius.circular(Radii.chip),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(Gap.md),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(LucideIcons.bellOff, size: 18, color: ds.blockedText),
                      const SizedBox(width: Gap.md),
                      Expanded(
                        child: Text(
                          'Android is blocking notifications for herdr. '
                          'Allow them in the system settings for this app.',
                          style: Type.secondary.copyWith(color: ds.blockedText),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        _Inset(
          SwitchRow(
            title: 'Notify me when an agent needs me',
            value: enabled,
            onChanged: (next) => unawaited(_setEnabled(next)),
          ),
        ),
        _Inset(
          SwitchRow(
            title: 'Also when an agent finishes',
            value: alsoDone,
            enabled: enabled,
            onChanged: (next) => unawaited(settings.setAlsoDone(next)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.gutter, vertical: Gap.sm),
          child: Text(
            'While agents work, herdr keeps a quiet \u201cWatching\u201d notice so '
            'Android keeps the connection alive. Notifications clear when you open the app.',
            style: Type.secondary.copyWith(color: ds.textMuted),
          ),
        ),
      ],
    );
  }
}

class _AboutGroup extends StatelessWidget {
  const _AboutGroup({this.update, required this.open, required this.onToggle});

  final AppUpdate? update;
  final bool open;
  final VoidCallback onToggle;

  static const _repoLabel = 'github.com/tuan3w/herdr-mobile · GPL-3.0';

  /// The notice GPL-3.0 section 5(d) asks an interactive program to show.
  static const _legalese = 'Copyright © 2026 Tuan Nguyen. herdr mobile is free '
      'software under the GNU General Public License v3.0, and comes with no '
      'warranty. Its source is at github.com/tuan3w/herdr-mobile.';

  Future<void> _openRepo(BuildContext context) async {
    final toaster = Toaster.of(context);
    if (!await openInBrowser(appRepositoryUrl)) {
      toaster.show('No browser could open the link.', kind: ToastKind.failed);
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
      icon: LucideIcons.info,
      title: 'About',
      // A newer version is said once, on its own row at the top.
      summary: 'Version $appVersion',
      open: open,
      onToggle: onToggle,
      divider: false,
      children: [
        if (update != null) _UpdateRows(update: update),
        ListRow(
          title: 'Connection',
          titleMaxLines: 1,
          subtitleMaxLines: 8,
          subtitle: update == null
              ? 'Talks to herdr over SSH and sends nothing anywhere else. '
                  'Dictation uses your phone\'s own speech service.'
              : 'Talks to herdr over SSH. The only other place it contacts is GitHub, '
                  'to look for a new version and, when you tap Download, to fetch it. '
                  'Dictation uses your phone\'s own speech service.',
        ),
        ListRow(
          title: 'Source code',
          titleMaxLines: 1,
          subtitle: _repoLabel,
          subtitleMaxLines: 2,
          trailing: Icon(LucideIcons.externalLink, size: 16, color: context.ds.textTertiary),
          onTap: () => unawaited(_openRepo(context)),
        ),
        ListRow(
          title: 'Licenses',
          titleMaxLines: 1,
          trailing: Icon(LucideIcons.chevronRight, size: 16, color: context.ds.textTertiary),
          onTap: () => _openLicenses(context),
          divider: false,
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListRow(
                title: 'Check for updates',
                titleMaxLines: 1,
                subtitle: subtitle,
                subtitleMaxLines: 4,
                subtitleColor: problem != null ? ds.dangerText : null,
                trailing: checking
                    ? const BusySpinner(size: 18)
                    : Icon(LucideIcons.refreshCw, size: 16, color: ds.textTertiary),
                onTap: update.stage == UpdateStage.idle ? () => unawaited(update.check()) : null,
              ),
              _Inset(
                SwitchRow(
                  title: 'Check automatically',
                  subtitle: 'Asks github.com about twice a day while you use the app, with this '
                      'app\'s name and version. A download comes from GitHub\'s file servers.',
                  value: update.autoCheck,
                  onChanged: (on) => unawaited(update.setAutoCheck(on)),
                ),
              ),
              const Hairline(indent: Gap.gutter),
            ],
          );
        },
      );
}
