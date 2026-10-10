import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/app_info.dart';
import '../../../data/models/release_info.dart';
import '../../../data/repositories/app_update.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/markdown/markdown.dart';
import '../../core/open_link.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';
import 'settings_group.dart';

/// The top of Settings while a newer version exists: one row that says what
/// it is, and opens to what is in it and the one next step (Download, then
/// Install). Absent otherwise, so nothing at rest says "update" when there is
/// none. It is a suggestion and stays quiet: a neutral row with the accent
/// only on its tile, no colour that belongs to a question.
///
/// While bytes arrive the row carries the progress bar, open or not, so a
/// download is never out of sight behind another group.
class UpdateGroup extends StatelessWidget {
  const UpdateGroup({super.key, required this.update, required this.open, required this.onToggle});

  final AppUpdate update;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: update,
        builder: (context, _) {
          final release = update.release;
          if (release == null) return const SizedBox.shrink();
          final ds = context.ds;
          final summary = switch (update.stage) {
            UpdateStage.downloading => 'Downloading ${megabytes(update.received)} of ${megabytes(release.size)}',
            UpdateStage.ready => 'Ready to install',
            // The sentence itself (red, whole) is in the body; a row's line is
            // a summary.
            _ => update.problem != null
                ? 'Update failed, open to see why'
                : '${release.version} \u00b7 ${megabytes(release.size)}',
          };
          return SettingsGroup(
            icon: LucideIcons.download,
            title: 'Update available',
            summary: summary,
            tint: ds.accent,
            // Ready, or stopped: news a screen reader says even with the group
            // closed behind another one.
            announce: update.stage == UpdateStage.ready || update.problem != null,
            open: open,
            onToggle: onToggle,
            footer: update.stage == UpdateStage.downloading
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.gutter, 0, Gap.gutter, Gap.md),
                    child: _ProgressBar(update.received / release.size),
                  )
                : null,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.xs, Gap.gutter, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      update.stage == UpdateStage.ready
                          ? 'Downloaded and compared with its checksum. Android asks you to confirm the install.'
                          : 'From github.com. You have $appVersion.',
                      style: Type.secondary.copyWith(color: ds.textSecondary),
                    ),
                    if (update.problem case final problem?) ...[
                      const SizedBox(height: Gap.sm),
                      _Note(problem, failed: true),
                    ],
                    if (update.needsInstallPermission) ...[
                      const SizedBox(height: Gap.sm),
                      const _Note(
                        'Allow herdr under \u201cInstall unknown apps\u201d on the Android page that opened, '
                        'then come back and tap Install.',
                      ),
                    ],
                    const SizedBox(height: Gap.md),
                    _Actions(update: update, release: release),
                  ],
                ),
              ),
            ],
          );
        },
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.failed = false});

  final String text;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Semantics(
      liveRegion: true,
      child: Text(
        text,
        style: Type.secondary.copyWith(color: failed ? ds.dangerText : ds.textSecondary),
      ),
    );
  }
}

/// A thin determinate bar. It only exists while bytes arrive: nothing moves at
/// rest.
class _ProgressBar extends StatelessWidget {
  const _ProgressBar(this.fraction);

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final value = fraction.clamp(0.0, 1.0);
    return Semantics(
      label: 'Download progress',
      value: '${(value * 100).floor()}%',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: SizedBox(
          height: 4,
          child: Stack(
            children: [
              Positioned.fill(child: ColoredBox(color: ds.fill)),
              Positioned.fill(
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: value,
                  child: ColoredBox(color: ds.accent),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.update, required this.release});

  final AppUpdate update;
  final ReleaseInfo release;

  @override
  Widget build(BuildContext context) {
    final retry = update.problem != null;
    final primary = switch (update.stage) {
      UpdateStage.downloading => AppButton(
          label: 'Cancel',
          kind: AppButtonKind.secondary,
          expand: true,
          onPressed: update.cancelDownload,
        ),
      UpdateStage.ready => AppButton(
          label: 'Install',
          icon: LucideIcons.packageCheck,
          expand: true,
          onPressed: () => unawaited(update.install()),
        ),
      _ => AppButton(
          label: retry ? 'Try again' : 'Download',
          icon: LucideIcons.download,
          expand: true,
          onPressed: () => unawaited(update.download()),
        ),
    };
    // Side by side only while both labels fit whole: at large text sizes the
    // primary one ("Try again") would be cut, so they stack.
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 21;
    final notes = AppButton(
      label: 'What\u2019s new',
      kind: AppButtonKind.ghost,
      expand: stacked,
      onPressed: () => unawaited(showReleaseNotes(context, release)),
    );
    if (stacked) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [primary, const SizedBox(height: Gap.xs), notes],
      );
    }
    return Row(
      children: [
        Expanded(child: primary),
        const SizedBox(width: Gap.sm),
        notes,
      ],
    );
  }
}

/// The release's notes (its section of `CHANGELOG.md`: what the person
/// notices) in a sheet, before anything is downloaded. A release without
/// notes opens its page on GitHub instead.
Future<void> showReleaseNotes(BuildContext context, ReleaseInfo release) async {
  if (release.notes.isEmpty) {
    final toaster = Toaster.of(context);
    if (!await openInBrowser(release.pageUrl)) {
      toaster.show('No browser could open the link.', kind: ToastKind.failed);
    }
    return;
  }
  final document = parseMd(release.notes, softBreaksAsNewlines: false);
  if (!context.mounted) return;
  await showAppSheet<void>(
    context,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              'What\u2019s new in ${release.version}',
              style: Type.title.copyWith(color: context.ds.text),
            ),
          ),
          const SizedBox(height: Gap.md),
          MdDocumentView(document: document),
        ],
      ),
    ),
  );
}
