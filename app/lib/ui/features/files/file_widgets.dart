import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../core/controls.dart';
import '../../core/rows.dart';
import '../../core/status_panel.dart';
import '../../core/theme.dart';
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

/// Copies [text] and says so with the themed snackbar.
void copyToClipboard(BuildContext context, String text, String done) {
  Clipboard.setData(ClipboardData(text: text));
  HapticFeedback.selectionClick();
  showToast(context, done);
}

/// A quiet one-line message (the themed snackbar), replacing any showing one.
void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
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
          message: '$name is no longer there. It may have been moved or deleted.',
          retry: true,
          danger: false,
        ),
      RemoteFileErrorKind.permission => (
          icon: LucideIcons.lock,
          title: 'Permission denied',
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
          title: 'Connection lost',
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
  });

  final RemoteFileException error;

  /// What the failed path is called, for the sentence.
  final String name;
  final VoidCallback? onRetry;

  /// Replaces Retry (e.g. "Go up" for a folder that is gone).
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final d = describeFileError(error, name);
    return StatusPanel(
      color: d.danger ? ds.danger : ds.blocked,
      icon: d.icon,
      title: d.title,
      message: d.message,
      trailing: action ??
          (d.retry && onRetry != null
              ? AppButton(label: 'Retry', kind: AppButtonKind.secondary, compact: true, onPressed: onRetry)
              : null),
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
