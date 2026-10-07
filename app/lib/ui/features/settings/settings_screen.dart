import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/app_info.dart';
import '../../../data/repositories/app_settings.dart';
import '../../../data/repositories/notification_settings.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../../data/services/notifier.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/form_sections.dart';
import '../../core/motion.dart';
import '../../core/open_link.dart';
import '../../core/rows.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import 'app_switch.dart';
import 'font_size_control.dart';
import 'quick_phrases_editor.dart';

/// The third root tab: how the app looks, how the terminal is drawn, and what
/// this app is. Everything here applies at once and is remembered.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.ds.bg,
        body: CustomScrollView(
          slivers: [
            const SliverLargeTitle(title: 'Settings'),
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _AppearanceSection(),
                  const _TerminalSection(),
                  const QuickPhrasesSection(),
                  const _NotificationsSection(),
                  const _AboutSection(),
                  SizedBox(height: FloatingTabBar.clearance(context) + Gap.md),
                ],
              ),
            ),
          ],
        ),
      );
}

class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  static String _hint(ThemeChoice choice) => switch (choice) {
        ThemeChoice.light => 'Warm paper, easy to read in daylight.',
        ThemeChoice.dark => 'Near-black, easy on the eyes at night.',
        ThemeChoice.system => 'Follows your phone\u2019s dark mode.',
      };

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final settings = context.read<AppSettings>();
    final choice = context.select<AppSettings, ThemeChoice>((s) => s.theme);
    final density = context.select<AppSettings, BoardDensity>((s) => s.density);
    final openAs = context.select<AppSettings, OpenAgentsAs>((s) => s.openAgentsAs);
    final smoothText = context.select<AppSettings, bool>((s) => s.smoothText);
    return FormSection(
      label: 'Appearance',
      endsWithField: false,
      children: [
        // Two groups, each a title over its control and its hint; the gap
        // between groups is wider than the gaps inside one.
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Theme', style: Type.row.copyWith(color: ds.text)),
            const SizedBox(height: Gap.sm),
            Segmented<ThemeChoice>(
              options: const [
                SegmentOption(ThemeChoice.light, 'Light', LucideIcons.sun),
                SegmentOption(ThemeChoice.dark, 'Dark', LucideIcons.moon),
                SegmentOption(ThemeChoice.system, 'System', LucideIcons.smartphone),
              ],
              value: choice,
              onChanged: (next) => unawaited(settings.setTheme(next)),
            ),
            const SizedBox(height: Gap.md),
            _ThemePreview(choice: choice),
            const SizedBox(height: Gap.sm),
            Text(_hint(choice), style: Type.secondary.copyWith(color: ds.textSecondary)),
          ],
        ),
        const SizedBox(height: Gap.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Agent list', style: Type.row.copyWith(color: ds.text)),
            const SizedBox(height: Gap.sm),
            Segmented<BoardDensity>(
              options: const [
                SegmentOption(BoardDensity.auto, 'Auto', LucideIcons.sparkles),
                SegmentOption(BoardDensity.cards, 'Cards', LucideIcons.layoutGrid),
                SegmentOption(BoardDensity.compact, 'Compact', LucideIcons.list),
              ],
              value: density,
              onChanged: (next) => unawaited(settings.setDensity(next)),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              'Auto uses cards up to ${AppSettings.autoCompactFrom - 1} agents and the compact '
              'list from ${AppSettings.autoCompactFrom}; a blocked agent always keeps its answers.',
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ],
        ),
        const SizedBox(height: Gap.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Open omp agents as', style: Type.row.copyWith(color: ds.text)),
            const SizedBox(height: Gap.sm),
            Segmented<OpenAgentsAs>(
              options: const [
                SegmentOption(OpenAgentsAs.chat, 'Chat', LucideIcons.messageSquare),
                SegmentOption(OpenAgentsAs.terminal, 'Terminal', LucideIcons.terminal),
              ],
              value: openAs,
              onChanged: (next) => unawaited(settings.setOpenAgentsAs(next)),
            ),
            const SizedBox(height: Gap.sm),
            Text(
              openAs == OpenAgentsAs.chat
                  ? 'A running omp opens as a chat you can read and answer; the terminal is one tap away.'
                  : 'A running omp opens as its terminal, like any other agent.',
              style: Type.secondary.copyWith(color: ds.textSecondary),
            ),
          ],
        ),
        SwitchRow(
          title: 'Smooth text',
          subtitle: 'Show an answer at an even pace as it is written, not in bursts.',
          value: smoothText,
          onChanged: (next) => unawaited(settings.setSmoothText(next)),
        ),
      ],
    );
  }
}

/// Two miniature screens, paper and ink, with the one in use outlined. For
/// `system` it is the one the phone currently picks. Decorative: the control
/// above carries the names.
class _ThemePreview extends StatelessWidget {
  const _ThemePreview({required this.choice});

  final ThemeChoice choice;

  @override
  Widget build(BuildContext context) {
    final inUse = switch (choice) {
      ThemeChoice.light => Brightness.light,
      ThemeChoice.dark => Brightness.dark,
      ThemeChoice.system => MediaQuery.platformBrightnessOf(context),
    };
    return ExcludeSemantics(
      child: Row(
        children: [
          Expanded(child: _MiniScreen(look: Ds.paper, inUse: inUse == Brightness.light)),
          const SizedBox(width: Gap.sm),
          Expanded(child: _MiniScreen(look: Ds.ink, inUse: inUse == Brightness.dark)),
        ],
      ),
    );
  }
}

class _MiniScreen extends StatelessWidget {
  const _MiniScreen({required this.look, required this.inUse});

  final Ds look;
  final bool inUse;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final reduced = Motion.reduced(context);
    Widget bar(double widthFactor, double height, Color color) => FractionallySizedBox(
          widthFactor: widthFactor,
          alignment: Alignment.centerLeft,
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(height / 2),
            ),
          ),
        );
    return AnimatedContainer(
      duration: reduced ? Duration.zero : Motion.standard,
      curve: Motion.easeOut,
      height: 72,
      padding: const EdgeInsets.all(Gap.sm + 2),
      decoration: BoxDecoration(
        color: look.bg,
        borderRadius: BorderRadius.circular(Radii.control),
        border: Border.all(color: inUse ? ds.accent : ds.hairline, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bar(0.5, 8, look.text),
          const SizedBox(height: 5),
          bar(0.8, 6, look.textSecondary.withValues(alpha: 0.55)),
          const Spacer(),
          Container(
            height: 16,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            decoration: BoxDecoration(
              color: look.surface,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: look.hairline),
            ),
            child: Row(
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(color: look.blocked, shape: BoxShape.circle),
                ),
                const SizedBox(width: 5),
                Expanded(child: bar(0.6, 4, look.textMuted.withValues(alpha: 0.6))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalSection extends StatelessWidget {
  const _TerminalSection();

  @override
  Widget build(BuildContext context) {
    final settings = context.read<TerminalSettings>();
    final wrap = context.select<TerminalSettings, bool>((s) => s.wrap);
    final app = context.read<AppSettings>();
    final darkTerminal = context.select<AppSettings, bool>((s) => s.darkTerminal);
    return FormSection(
      label: 'Terminal',
      endsWithField: false,
      children: [
        const FontSizeControl(),
        SwitchRow(
          title: 'Wrap long lines',
          subtitle: 'Fit lines to the screen instead of scrolling sideways.',
          value: wrap,
          onChanged: (next) => unawaited(settings.setWrap(next)),
        ),
        SwitchRow(
          title: 'Dark terminal',
          subtitle: 'Keep the terminal dark when the app is light.',
          value: darkTerminal,
          onChanged: (next) => unawaited(app.setDarkTerminal(next)),
        ),
      ],
    );
  }
}

/// Local notifications: off until the person turns them on, which asks Android
/// for the permission first. The notifications themselves are posted by the
/// app (`AttentionNotifier`), nothing leaves the phone.
class _NotificationsSection extends StatefulWidget {
  const _NotificationsSection();

  @override
  State<_NotificationsSection> createState() => _NotificationsSectionState();
}

class _NotificationsSectionState extends State<_NotificationsSection> {
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
    return FormSection(
      label: 'Notifications',
      endsWithField: false,
      children: [
        SwitchRow(
          title: 'Notify me when an agent needs me',
          value: enabled,
          onChanged: (next) => unawaited(_setEnabled(next)),
        ),
        if (_blocked)
          Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.only(bottom: Gap.sm),
              child: Text(
                'Android is blocking notifications for herdr. '
                'Allow them in the system settings for this app.',
                style: Type.secondary.copyWith(color: ds.blockedText),
              ),
            ),
          ),
        SwitchRow(
          title: 'Also when an agent finishes',
          value: alsoDone,
          enabled: enabled,
          onChanged: (next) => unawaited(settings.setAlsoDone(next)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.sm),
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

class _AboutSection extends StatelessWidget {
  const _AboutSection();

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
  Widget build(BuildContext context) => FormSection(
        label: 'About',
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _InfoRow(title: 'herdr mobile', subtitle: 'Version $appVersion'),
              const _InfoRow(
                title: 'Connection',
                subtitle: 'Talks to herdr over SSH and sends nothing anywhere else. '
                    'Dictation uses your phone\'s own speech service.',
              ),
              _InfoRow(
                title: 'Source code',
                subtitle: _repoLabel,
                trailing: LucideIcons.externalLink,
                onTap: () => unawaited(_openRepo(context)),
              ),
              _InfoRow(
                title: 'Licenses',
                trailing: LucideIcons.chevronRight,
                onTap: () => _openLicenses(context),
                divider: false,
              ),
            ],
          ),
        ],
      );
}

/// A line of an About panel: title, an optional wrapping line under it, an
/// optional trailing icon. Tappable when [onTap] is set. At least 56 high.
class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.divider = true,
  });

  final String title;
  final String? subtitle;
  final IconData? trailing;
  final VoidCallback? onTap;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final subtitle = this.subtitle;
    final trailing = this.trailing;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        PressBuilder(
          onTap: onTap,
          haptic: onTap != null,
          builder: (context, pressed) => AnimatedContainer(
            duration: Motion.pressing(pressed),
            curve: Motion.easeOut,
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(vertical: Gap.sm),
            alignment: Alignment.centerLeft,
            decoration: BoxDecoration(
              color: pressed ? ds.fill : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.row),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: Type.row.copyWith(color: ds.text)),
                      if (subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            subtitle,
                            style: Type.secondary.copyWith(color: ds.textSecondary),
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: Gap.md),
                  Icon(trailing, size: 18, color: ds.textTertiary),
                ],
              ],
            ),
          ),
        ),
        if (divider) const Hairline(),
      ],
    );
  }
}
