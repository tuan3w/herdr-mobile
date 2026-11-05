import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/app_info.dart';
import '../../../data/models/release_info.dart';
import '../../../data/repositories/app_update.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import '../../render/markdown/markdown.dart';
import '../../support/open_link.dart';
import 'clip_player.dart';
import 'settings_group.dart';

/// The top of Settings while a newer version exists: one row that says what
/// it is and opens the update sheet ([showUpdateSheet]), where the notes are
/// read on the way to Download and Install. Absent otherwise, so nothing at
/// rest says "update" when there is none. It is a suggestion and stays quiet:
/// a neutral row with the accent only on its tile, no colour that belongs to a
/// question.
///
/// While bytes arrive the row carries the progress bar, so a download stays in
/// sight after the sheet is put away.
class UpdateGroup extends StatelessWidget {
  const UpdateGroup({super.key, required this.update, required this.onOpen});

  final AppUpdate update;

  /// The row was tapped: open the sheet.
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: update,
    builder: (context, _) {
      final release = update.release;
      if (release == null) return const SizedBox.shrink();
      final summary = switch (update.stage) {
        UpdateStage.downloading => 'Downloading ${megabytes(update.received)} of ${megabytes(release.size)}',
        UpdateStage.ready => 'Ready to install',
        // The sentence itself (red, whole) is in the sheet; a row's line
        // is a summary.
        _ =>
          update.problem != null
              ? 'Update failed, open to see why'
              : '${release.version} \u00b7 ${megabytes(release.size)}',
      };
      return SettingsGroup(
        icon: HerdrIcons.update,
        title: 'Update available',
        summary: summary,
        tint: context.ds.accent,
        // Ready, or stopped: news a screen reader says even with the
        // sheet put away.
        announce: update.stage == UpdateStage.ready || update.problem != null,
        open: false,
        onToggle: onOpen,
        footer: update.stage == UpdateStage.downloading
            ? Padding(
                padding: const EdgeInsets.only(left: Gap.gutter, right: Gap.gutter, bottom: Gap.md),
                child: _ProgressBar(update.received / release.size),
              )
            : null,
        rows: const [],
      );
    },
  );
}

/// The update in one sheet: the release's walkthrough clip when it has one,
/// its notes (the version's section of `CHANGELOG.md`: what the person
/// notices), then, pinned under them, one line of what herdr knows about the
/// file and the one next step: Download, then Install. The notes come first
/// so nobody installs what they had no chance to read.
///
/// The fact line says only what is true at that moment: before the download,
/// where it comes from and which version you have; after it, that the file
/// matched the release's checksum. Android's signing rule is not claimed:
/// Android applies it after Install, and herdr does not know the outcome.
Future<void> showUpdateSheet(BuildContext context, AppUpdate update) =>
    showAppSheet<void>(context, builder: (context) => _UpdateSheet(update: update));

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet({required this.update});

  final AppUpdate update;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: update,
    builder: (context, _) {
      final release = update.release;
      // Installed, or withdrawn while the sheet was open: nothing to offer.
      if (release == null) return const SizedBox.shrink();
      final ds = context.ds;
      final clip = release.clip;
      final notes = clip == null ? release.notes : clip.without(release.notes);
      return SheetScaffold(
        kind: SheetKind.list,
        actions: [
          _Facts(update: update, release: release),
          ..._steps(context, release),
        ],
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(_inset, Gap.md, _inset, Gap.sm),
              child: Semantics(
                header: true,
                child: Text('Update to ${release.version}', style: Type.title.copyWith(color: ds.text)),
              ),
            ),
            if (clip != null) ClipCard(clip, version: release.version),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _inset),
              child: notes.isEmpty
                  ? _NoNotes(release: release)
                  : MdDocumentView(document: parseMd(notes, softBreaksAsNewlines: false)),
            ),
          ],
        ),
      );
    },
  );

  List<Widget> _steps(BuildContext context, ReleaseInfo release) {
    final ds = context.ds;
    final caption = Type.caption.copyWith(color: ds.textMuted);
    return switch (update.stage) {
      UpdateStage.downloading => [
        _ProgressBar(update.received / release.size),
        Text(
          'Downloading ${megabytes(update.received)} of ${megabytes(release.size)}',
          style: Type.secondary.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular),
        ),
        AppButton(label: 'Cancel', kind: AppButtonKind.secondary, expand: true, onPressed: update.cancelDownload),
      ],
      UpdateStage.ready => [
        if (update.needsInstallPermission)
          const _Note(
            'Allow herdr under \u201cInstall unknown apps\u201d on the Android page that opened, '
            'then come back and tap Install.',
          ),
        AppButton(
          label: 'Install ${release.version}',
          icon: LucideIcons.packageCheck,
          expand: true,
          onPressed: () => unawaited(update.install()),
        ),
        Text('Android asks before it installs.', style: caption, textAlign: TextAlign.center),
      ],
      _ => [
        if (update.problem case final problem?) _Note(problem, failed: true),
        AppButton(
          label: update.problem != null ? 'Retry' : 'Download ${megabytes(release.size)}',
          icon: HerdrIcons.update,
          expand: true,
          // A check that runs meanwhile (after a failed download) keeps the
          // button until it is back.
          onPressed: update.stage == UpdateStage.idle ? () => unawaited(update.download()) : null,
        ),
      ],
    };
  }
}

/// A list sheet insets its rows by [Gap.xs]; text takes the page gutter.
const _inset = Gap.gutter - Gap.xs;

/// What herdr knows about the file, one line over a hairline that ends the
/// notes (the last line of notes is cut by the footer otherwise, with nothing
/// to say so).
class _Facts extends StatelessWidget {
  const _Facts({required this.update, required this.release});

  final AppUpdate update;
  final ReleaseInfo release;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final caption = Type.caption.copyWith(color: ds.textMuted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Hairline(),
        const SizedBox(height: Gap.md),
        if (update.stage == UpdateStage.ready)
          Row(
            children: [
              Icon(LucideIcons.badgeCheck, size: IconSize.inline, color: ds.done),
              const SizedBox(width: Gap.xs),
              Expanded(child: Text('Checksum matched: the file the release lists', style: caption)),
            ],
          )
        else
          Text('From github.com/$appRepository \u00b7 you have $appVersion', style: caption),
      ],
    );
  }
}

/// The walkthrough's poster with a play mark, and what it is and costs under
/// it. A tap plays it in the app ([openClipPlayer]); nothing of the video
/// loads before that tap. The poster is the one picture fetched with the
/// sheet: a small JPEG, from the release itself. If it cannot load, the card
/// keeps its words and the play mark.
class ClipCard extends StatelessWidget {
  const ClipCard(this.clip, {super.key, required this.version});

  final ReleaseClip clip;
  final String version;

  void _play(BuildContext context) => unawaited(openClipPlayer(context, clip, title: 'What\u2019s new in $version'));

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final play = DecoratedBox(
      decoration: BoxDecoration(color: ds.inverseSurface, borderRadius: BorderRadius.circular(Radii.pill)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.md, Gap.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.play, size: IconSize.inline, color: ds.onInverse),
            const SizedBox(width: Gap.xs),
            Text('Play', style: Type.labelStrong.copyWith(color: ds.onInverse)),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(_inset, Gap.xs, _inset, Gap.md),
      child: Semantics(
        button: true,
        label: '${clip.label}, plays here',
        excludeSemantics: true,
        child: PressBuilder(
          minTapSize: kMinTap,
          onTap: () => _play(context),
          builder: (context, pressed) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  border: Border.all(color: ds.hairline),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: SizedBox(
                    height: _posterHeight,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ColoredBox(color: ds.fill),
                        Image.network(
                          clip.poster,
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          gaplessPlayback: true,
                          errorBuilder: (context, error, stack) => const SizedBox.shrink(),
                        ),
                        if (pressed) ColoredBox(color: ds.pressTint),
                        Center(child: play),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Gap.xs),
              Text(
                clip.label,
                style: Type.caption.copyWith(color: ds.textMuted, fontFeatures: Type.tabular),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The poster's height: the clip says it is there without pushing the notes'
/// first lines off the first screen.
const _posterHeight = 200.0;

class _NoNotes extends StatelessWidget {
  const _NoNotes({required this.release});

  final ReleaseInfo release;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('No notes came with this release.', style: Type.secondary.copyWith(color: ds.textSecondary)),
        TextAction(
          label: 'Open on GitHub',
          onTap: () async {
            final toaster = Toaster.of(context);
            if (!await openInBrowser(release.pageUrl)) {
              toaster.show('Couldn\u2019t open on this phone: no browser could open it.', kind: ToastKind.failed);
            }
          },
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
      child: Text(text, style: Type.secondary.copyWith(color: failed ? ds.dangerText : ds.textSecondary)),
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
        borderRadius: BorderRadius.circular(Radii.pill),
        child: SizedBox(
          height: _progressHeight,
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

/// The download bar's thickness.
const _progressHeight = 4.0;
