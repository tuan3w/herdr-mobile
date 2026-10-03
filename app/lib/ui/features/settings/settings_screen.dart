import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../../data/app_info.dart';
import '../../../data/repositories/app_settings.dart';
import '../../../data/repositories/terminal_settings.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/form_sections.dart';
import '../../core/motion.dart';
import '../../core/open_link.dart';
import '../../core/rows.dart';
import '../../core/tokens.dart';
import 'app_switch.dart';
import 'font_size_control.dart';

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
    return FormSection(
      label: 'Appearance',
      endsWithField: false,
      children: [
        Segmented<ThemeChoice>(
          options: const [
            SegmentOption(ThemeChoice.light, 'Light', LucideIcons.sun),
            SegmentOption(ThemeChoice.dark, 'Dark', LucideIcons.moon),
            SegmentOption(ThemeChoice.system, 'System', LucideIcons.smartphone),
          ],
          value: choice,
          onChanged: (next) => unawaited(settings.setTheme(next)),
        ),
        _ThemePreview(choice: choice),
        Text(_hint(choice), style: Type.secondary.copyWith(color: ds.textSecondary)),
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
        border: Border.all(color: inUse ? ds.accent : ds.border, width: 2),
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
      ],
    );
  }
}

class _AboutSection extends StatelessWidget {
  const _AboutSection();

  static const _repoLabel = 'github.com/tuan3w/herdr-mobile';

  Future<void> _openRepo(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    if (!await openInBrowser(appRepositoryUrl)) {
      messenger.showSnackBar(const SnackBar(content: Text('No browser could open the link.')));
    }
  }

  void _openLicenses(BuildContext context) => showLicensePage(
        context: context,
        applicationName: 'herdr mobile',
        applicationVersion: appVersion,
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
                subtitle: 'Talks to herdr over SSH. Nothing leaves your devices.',
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
