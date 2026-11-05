import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../../data/models/remote_file.dart';
import '../../../data/repositories/path_finder.dart' show PathNotFound;

import 'package:herdr_mobile/ui/core/kit.dart';

import 'file_kind.dart';

const _codeExt = {
  'dart',
  'py',
  'js',
  'mjs',
  'cjs',
  'ts',
  'tsx',
  'jsx',
  'rb',
  'go',
  'rs',
  'java',
  'kt',
  'kts',
  'swift',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'php',
  'sh',
  'bash',
  'zsh',
  'fish',
  'sql',
  'lua',
  'html',
  'htm',
  'css',
  'scss',
  'xml',
  'yaml',
  'yml',
  'toml',
  'ini',
  'cfg',
  'conf',
  'gradle',
  'vue',
  'svelte',
  'r',
  'pl',
  'ex',
  'exs',
  'hs',
  'scala',
  'zig',
  'nix',
  'tf',
  'proto',
  'graphql',
  'make',
  'mk',
  'cmake',
  'dockerfile',
};

const _archiveExt = {
  'zip',
  'tar',
  'gz',
  'tgz',
  'bz2',
  'xz',
  '7z',
  'rar',
  'zst',
  'jar',
  'war',
  'apk',
  'deb',
  'rpm',
  'iso',
  'dmg',
};
const _audioExt = {'mp3', 'wav', 'flac', 'ogg', 'm4a'};
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
  return switch (typeForName(name).kind) {
    FileKind.image || FileKind.svg => LucideIcons.fileImage,
    FileKind.video => LucideIcons.fileVideo,
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

/// What a failed file operation says: an icon, a short title, a sentence.
({IconData icon, String title, String message, bool retry, bool danger}) describeFileError(
  RemoteFileException e,
  String name,
) => switch (e.kind) {
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
    message: 'Your login on this machine isn’t allowed to read $name.',
    retry: true,
    danger: true,
  ),
  RemoteFileErrorKind.unsupported => (
    icon: HerdrIcons.machinesOff,
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
    title: 'Can’t open this',
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
    icon: LucideIcons.circleAlert,
    title: 'Couldn’t read this',
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

/// A whole page for a path that is still being looked up (or could not be):
/// Back, what was asked for, and a skeleton after [Dwell.spinnerDelay]; or the
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
          AppTopBar(title: title),
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
                            onPressed: () => copyText(context, path!, what: 'Path copied'),
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
                width: _labelWidth,
                child: Text(label, style: Type.secondary.copyWith(color: ds.textSecondary)),
              ),
              Expanded(
                child: Text(
                  value,
                  style: mono ? Mono.base.copyWith(color: ds.text) : Type.secondary.copyWith(color: ds.text),
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

/// The label column of a details table: the longest label fits at 1.0.
const _labelWidth = 96.0;
