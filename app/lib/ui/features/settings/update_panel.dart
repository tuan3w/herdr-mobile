import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/app_info.dart';
import '../../../data/models/release_info.dart';
import '../../../data/repositories/app_update.dart';
import '../../core/chrome.dart';
import '../../core/controls.dart';
import '../../core/form_sections.dart';
import '../../core/markdown/markdown.dart';
import '../../core/open_link.dart';
import '../../core/toast.dart';
import '../../core/tokens.dart';

/// The top of Settings while a newer version exists: what it is, what is in
/// it, and the one next step (Download, then Install). Absent otherwise, so
/// nothing at rest says "update" when there is none. It is a suggestion and
/// stays quiet: a plain panel, no colour that belongs to a question.
class UpdatePanel extends StatelessWidget {
  const UpdatePanel({super.key, required this.update});

  final AppUpdate update;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: update,
        builder: (context, _) {
          final release = update.release;
          if (release == null) return const SizedBox.shrink();
          return FormSection(
            label: 'Update',
            endsWithField: false,
            children: [
              _Summary(update: update, release: release),
              if (update.stage == UpdateStage.downloading) _ProgressBar(update.received / release.size),
              if (update.problem case final problem?) _Note(problem, failed: true),
              if (update.needsInstallPermission)
                const _Note(
                  'Allow herdr under \u201cInstall unknown apps\u201d on the Android page that opened, '
                  'then come back and tap Install.',
                ),
              _Actions(update: update, release: release),
            ],
          );
        },
      );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.update, required this.release});

  final AppUpdate update;
  final ReleaseInfo release;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final line = switch (update.stage) {
      UpdateStage.downloading =>
        'Downloading ${megabytes(update.received)} of ${megabytes(release.size)}',
      UpdateStage.ready => 'Downloaded and compared with its checksum. Android asks you to confirm the install.',
      _ => '${megabytes(release.size)} from github.com. You have $appVersion.',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Version ${release.version} is available', style: Type.row.copyWith(color: ds.text)),
        const SizedBox(height: 2),
        Semantics(
          liveRegion: update.stage == UpdateStage.ready,
          child: Text(line, style: Type.secondary.copyWith(color: ds.textSecondary)),
        ),
      ],
    );
  }
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
