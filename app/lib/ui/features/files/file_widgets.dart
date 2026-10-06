import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/path_finder.dart' show PathNotFound;
import '../../../data/services/system_clipboard.dart';
import '../../core/controls.dart';
import '../../core/motion.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import 'file_kind.dart';

const _codeExt = {
  'dart', 'py', 'js', 'mjs', 'cjs', 'ts', 'tsx', 'jsx', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift', 'c', 'h',
  'cc', 'cpp', 'hpp', 'cs', 'php', 'sh', 'bash', 'zsh', 'fish', 'sql', 'lua', 'html', 'htm', 'css', 'scss', 'xml',
  'yaml', 'yml', 'toml', 'ini', 'cfg', 'conf', 'gradle', 'vue', 'svelte', 'r', 'pl', 'ex', 'exs', 'hs', 'scala',
  'zig', 'nix', 'tf', 'proto', 'graphql', 'make', 'mk', 'cmake', 'dockerfile',
};

const _archiveExt = {'zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'zst', 'jar', 'war', 'apk', 'deb', 'rpm', 'iso', 'dmg'};
const _audioExt = {'mp3', 'wav', 'flac', 'ogg', 'm4a'};
const _videoExt = {'mp4', 'mov', 'mkv', 'webm', 'avi'};
const _codeNames = {'makefile', 'dockerfile', 'rakefile', 'gemfile', 'justfile', 'cmakelists.txt'};

/// The Lucide glyph for a file called [name].
IconData fileIconForName(String name) {
  final lower = name.toLowerCase();
  if (_codeNames.contains(lower)) return LucideIcons.fileCode;
  final dot = lower.lastIndexOf('.');
  final ext = dot <= 0 ? '' : lower.substring(dot + 1);
  if (_codeExt.contains(ext)) return LucideIcons.fileCode;
  if (_archiveExt.contains(ext)) return LucideIcons.fileArchive;
  if (_audioExt.contains(ext)) return LucideIcons.fileMusic;
  if (_videoExt.contains(ext)) return LucideIcons.fileVideo;
  return switch (typeForName(name).kind) {
    FileKind.image || FileKind.svg => LucideIcons.fileImage,
    FileKind.json => LucideIcons.fileBraces,
    FileKind.markdown || FileKind.pdf || FileKind.text => LucideIcons.fileText,
    FileKind.binary => LucideIcons.file,
  };
}

/// The glyph for a directory entry: folders, links, then by name.
IconData iconForEntry(RemoteEntry e) {
  if (e.isBrokenLink) return LucideIcons.fileX;
  if (e.kind == RemoteEntryKind.link) {
    return e.isDirectory ? LucideIcons.folderSymlink : LucideIcons.fileSymlink;
  }
  if (e.isDirectory) return LucideIcons.folder;
  if (e.kind == RemoteEntryKind.other) return LucideIcons.fileCog;
  return fileIconForName(e.name);
}

/// Copies [text] and says so with a toast. Where the system already shows its
/// own confirmation (Android 13+: "Copied to clipboard"), a plain `Copied` is
/// left to it, so the phone does not say it twice; words that tell more than
/// that (`Copied as Markdown`, `Copied the first 1 MB`) still show.
void copyToClipboard(BuildContext context, String text, String done) {
  Clipboard.setData(ClipboardData(text: text));
  Haptics.tick();
  if (SystemClipboard.confirms && done == 'Copied') return;
  showToast(context, done);
}

/// What a failed file operation says: an icon, a short title, a sentence.
({IconData icon, String title, String message, bool retry, bool danger}) describeFileError(
  RemoteFileException e,
  String name,
) =>
    switch (e.kind) {
      RemoteFileErrorKind.notFound => (
          icon: LucideIcons.fileX,
          title: 'Not found',
          message: e is PathNotFound ? e.message : '$name is no longer there. It may have been moved or deleted.',
          retry: true,
          danger: false,
        ),
      RemoteFileErrorKind.permission => (
          icon: LucideIcons.lock,
          title: 'No permission',
          message: "Your login on this machine isn't allowed to read $name.",
          retry: true,
          danger: true,
        ),
      RemoteFileErrorKind.unsupported => (
          icon: LucideIcons.serverOff,
          title: 'Files are unavailable',
          message: e.message,
          retry: false,
          danger: false,
        ),
      RemoteFileErrorKind.tooLarge => (
          icon: LucideIcons.fileWarning,
          title: 'Too large to open',
          message: e.message,
          retry: false,
          danger: false,
        ),
      RemoteFileErrorKind.notAFile => (
          icon: LucideIcons.fileCog,
          title: "Can't open this",
          message: e.message,
          retry: false,
          danger: false,
        ),
      RemoteFileErrorKind.notADirectory => (
          icon: LucideIcons.file,
          title: 'Not a folder',
          message: e.message,
          retry: false,
          danger: false,
        ),
      RemoteFileErrorKind.network => (
          icon: LucideIcons.cloudOff,
          title: 'Not reachable',
          message: e.message,
          retry: true,
          danger: true,
        ),
      RemoteFileErrorKind.failed => (
          icon: LucideIcons.triangleAlert,
          title: "Couldn't read this",
          message: e.message,
          retry: true,
          danger: true,
        ),
    };

/// A failed read as a tinted panel with Retry (when trying again can help)
/// and an optional second action.
class FileErrorPanel extends StatelessWidget {
  const FileErrorPanel({
    super.key,
    required this.error,
    required this.name,
    this.onRetry,
    this.action,
    this.alsoRetry = false,
  });

  final RemoteFileException error;

  /// What the failed path is called, for the sentence.
  final String name;
  final VoidCallback? onRetry;

  /// Replaces Retry (e.g. "Go up" for a folder that is gone).
  final Widget? action;

  /// Keep Retry too (when it can help) next to [action], under the message
  /// where two buttons have room.
  final bool alsoRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final d = describeFileError(error, name);
    final retry = d.retry && onRetry != null
        ? AppButton(label: 'Retry', kind: AppButtonKind.secondary, compact: true, onPressed: onRetry)
        : null;
    final both = action != null && alsoRetry && retry != null;
    return StatusPanel(
      color: d.danger ? ds.danger : ds.blocked,
      icon: d.icon,
      title: d.title,
      message: d.message,
      footer: both ? Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [action!, retry]) : null,
      trailing: both ? null : (action ?? retry),
    );
  }
}

/// Static placeholder bars while a file or folder loads: no animation, so a
/// slow link does not keep the GPU busy.
class FileSkeleton extends StatelessWidget {
  const FileSkeleton({super.key, this.rows = false});

  /// Bars shaped like list rows (a tile and two lines) instead of code lines.
  final bool rows;

  static const _widths = [0.62, 0.84, 0.4, 0.74, 0.55, 0.9, 0.3, 0.68, 0.5, 0.78];

  @override
  Widget build(BuildContext context) {
    final fill = context.ds.fill;
    Widget bar(double width, double height) => FractionallySizedBox(
          widthFactor: width,
          alignment: Alignment.centerLeft,
          child: Container(
            height: height,
            decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(5)),
          ),
        );
    return Semantics(
      label: 'Loading',
      excludeSemantics: true,
      child: ExcludeFocus(
        child: IgnorePointer(
          child: ListView.builder(
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, MediaQuery.paddingOf(context).bottom),
            itemCount: rows ? 14 : 30,
            itemBuilder: (_, i) => rows
                ? SizedBox(
                    height: 64,
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(Radii.tile)),
                        ),
                        const SizedBox(width: Gap.md),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              bar(_widths[i % _widths.length] * 0.8 + 0.1, 12),
                              const SizedBox(height: 8),
                              bar(0.28, 9),
                            ],
                          ),
                        ),
                      ],
                    ),
                  )
                : SizedBox(height: 22, child: Align(alignment: Alignment.centerLeft, child: bar(_widths[i % _widths.length], 10))),
          ),
        ),
      ),
    );
  }
}

/// A skeleton that stays out of sight for [delay]: a link that answers inside
/// that time shows the real content straight away, with no grey placeholder
/// flashing in and out. The one timer is cancelled with the widget.
class DelayedSkeleton extends StatefulWidget {
  const DelayedSkeleton({super.key, this.rows = false, this.delay = skeletonDelay, this.note});

  final bool rows;
  final Duration delay;

  /// What the wait is for when it is more than one read ("Looking in other
  /// checkouts…"), drawn above the placeholder.
  final String? note;

  @override
  State<DelayedSkeleton> createState() => _DelayedSkeletonState();
}

/// How long a loading screen waits before it draws its placeholder.
const skeletonDelay = Duration(milliseconds: 120);

class _DelayedSkeletonState extends State<DelayedSkeleton> {
  Timer? _timer;
  var _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.expand();
    final note = widget.note;
    if (note == null) return FileSkeleton(rows: widget.rows);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.gutter, Gap.md, Gap.gutter, 0),
          child: Text(note, style: Type.secondary.copyWith(color: context.ds.textSecondary)),
        ),
        Expanded(child: FileSkeleton(rows: widget.rows)),
      ],
    );
  }
}

/// A whole page for a path that is still being looked up (or could not be):
/// Back, what was asked for, and a skeleton after [skeletonDelay]; or the
/// reason it failed with what to do. The route is on screen at once, so a tap
/// answers on the next frame instead of after the host has been asked.
class FileResolvingPage extends StatelessWidget {
  const FileResolvingPage({
    super.key,
    required this.title,
    this.rows = true,
    this.error,
    this.onRetry,
    this.path,
    this.note,
    this.onSearch,
  });

  /// The name being opened (the last part of what was tapped).
  final String title;

  /// The placeholder is shaped like list rows (a folder may be coming).
  final bool rows;
  final RemoteFileException? error;
  final VoidCallback? onRetry;

  /// What was asked for, offered to copy when it failed.
  final String? path;

  /// What the wait is for, shown with the skeleton ("Looking in other checkouts…").
  final String? note;

  /// Looks for the name below the session folder; offered next to Retry when
  /// the failure says it has not been tried.
  final VoidCallback? onSearch;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final failed = error;
    return Scaffold(
      backgroundColor: ds.bg,
      body: Column(
        children: [
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.15,
            child: Padding(
              padding: EdgeInsets.fromLTRB(Gap.gutter - 6, MediaQuery.paddingOf(context).top, Gap.gutter - 6, 0),
              child: SizedBox(
                height: 60,
                child: Row(
                  children: [
                    CircleButton(
                      icon: LucideIcons.chevronLeft,
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: Gap.sm),
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Type.barTitle.copyWith(color: ds.text),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: failed == null
                ? DelayedSkeleton(rows: rows, note: note)
                : ListView(
                    padding: EdgeInsets.fromLTRB(
                      Gap.gutter,
                      Gap.md,
                      Gap.gutter,
                      Gap.xl + MediaQuery.paddingOf(context).bottom,
                    ),
                    children: [
                      FileErrorPanel(
                        error: failed,
                        name: title,
                        onRetry: onRetry,
                        alsoRetry: true,
                        action: failed is PathNotFound && failed.canSearch && onSearch != null
                            ? AppButton(
                                label: 'Search',
                                icon: LucideIcons.search,
                                kind: AppButtonKind.secondary,
                                compact: true,
                                onPressed: onSearch,
                              )
                            : null,
                      ),
                      if (path != null) ...[
                        const SizedBox(height: Gap.lg),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: AppButton(
                            label: 'Copy path',
                            icon: LucideIcons.copy,
                            kind: AppButtonKind.secondary,
                            onPressed: () => copyToClipboard(context, path!, 'Path copied'),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Mono-font style shared by every code and hex surface.
TextStyle codeStyle(Ds ds, {double size = 13, Color? color}) => TextStyle(
      fontFamily: monoFamily,
      fontSize: size,
      height: 1.5,
      color: color ?? ds.text,
      fontFeatures: const [FontFeature.disable('liga'), FontFeature.disable('calt')],
    );

/// One label and value of an info card.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value, this.mono = false, this.divider = true});

  final String label;
  final String value;
  final bool mono;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: Text(label, style: Type.secondary.copyWith(color: ds.textSecondary)),
              ),
              Expanded(
                child: Text(
                  value,
                  style: mono
                      ? codeStyle(ds, size: 12.5).copyWith(height: 1.4)
                      : Type.secondary.copyWith(color: ds.text),
                ),
              ),
            ],
          ),
        ),
        if (divider) const Hairline(),
      ],
    );
  }
}
