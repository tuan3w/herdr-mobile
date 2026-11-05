import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../../../data/models/remote_file.dart';

import 'package:herdr_mobile/ui/core/kit.dart';

import 'file_copy_model.dart';
import 'file_format.dart';
import 'file_kind.dart';

/// A video up to this size starts copying as soon as it is opened. A bigger
/// one waits for a tap on Play: a long copy over the phone's radio is the
/// person's to start.
const videoAutoCopyLimit = 24 * 1024 * 1024;

/// The player for a controller made from the copy on the phone.
typedef VideoControllerFor = VideoPlayerController Function(File copy);

/// A video file of a machine, in four steps the person can read: the card
/// (what it is, how big, Play), the copy to the phone (a bar, the bytes, Cancel),
/// the player, and, when the phone cannot play it, what to do instead.
///
/// The copy is the price of playing from a file on another computer: the phone's
/// player opens files, not an SFTP channel, so the whole file comes first and
/// plays from the phone, and Save to gallery and Share use that same copy.
class VideoView extends StatefulWidget {
  const VideoView({
    super.key,
    required this.stat,
    required this.type,
    required this.onShare,
    required this.onSave,
    required this.controllerFor,
    this.canSave = true,
  });

  final RemoteStat stat;
  final FileType type;

  /// Share or save the copy, which the screen does (it owns the toasts).
  final VoidCallback onShare;
  final VoidCallback onSave;

  /// Makes the player; a test hands in one that needs no platform.
  final VideoControllerFor controllerFor;

  /// Whether Save to gallery is offered: the gallery needs a video file name
  /// (an extension it can tell), which a video known only by its bytes may lack.
  final bool canSave;

  @override
  State<VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<VideoView> with WidgetsBindingObserver {
  VideoPlayerController? _video;
  var _cannotPlay = false;
  var _starting = false;
  var _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _resumed = state == null || state == AppLifecycleState.resumed;
    final size = widget.stat.size;
    if (size != null && size <= videoAutoCopyLimit) WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_video?.dispose());
    super.dispose();
  }

  /// A video does not keep playing behind a locked screen or another app: the
  /// person is not watching, and it would cost battery and sound.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) unawaited(_video?.pause());
  }

  Future<void> _start() async {
    if (_starting || !mounted) return;
    _starting = true;
    setState(() => _cannotPlay = false);
    try {
      final copy = context.read<FileCopyModel>();
      final file = await copy.copy(widget.stat);
      if (file == null || !mounted) return;
      final video = widget.controllerFor(file);
      final old = _video;
      setState(() => _video = video);
      unawaited(old?.dispose());
      try {
        await video.initialize();
        if (!mounted || _video != video) return;
        // A copy that finished while the app was in the background is ready, not
        // playing: the person taps Play when they are back.
        if (_resumed) await video.play();
      } on Object {
        if (mounted && _video == video) {
          setState(() {
            _video = null;
            _cannotPlay = true;
          });
          unawaited(video.dispose());
        }
      }
    } finally {
      _starting = false;
    }
  }

  void _toggle(VideoPlayerController video) {
    final v = video.value;
    if (v.isCompleted || (v.position >= v.duration && v.duration > Duration.zero)) {
      unawaited(video.seekTo(Duration.zero).then((_) => video.play()));
    } else if (v.isPlaying) {
      unawaited(video.pause());
    } else {
      unawaited(video.play());
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = context.watch<FileCopyModel>();
    final video = _video;
    final onSave = widget.canSave ? widget.onSave : null;
    if (video != null && video.value.isInitialized) {
      return _Player(
        video: video,
        onToggle: () => _toggle(video),
        onShare: widget.onShare,
        onSave: onSave,
        busy: copy.handing,
      );
    }
    if (copy.running) return _Copying(stat: widget.stat, copy: copy, willPlay: _starting);
    if (video != null) return const Center(child: BusySpinner(size: IconSize.lead));
    if (_cannotPlay) return _CannotPlay(onShare: widget.onShare, onSave: onSave, busy: copy.handing);
    if (copy.phase == CopyPhase.failed) {
      return _CopyFailed(message: copy.failure ?? '', onRetry: () => unawaited(_start()));
    }
    return _Card(stat: widget.stat, type: widget.type, onPlay: () => unawaited(_start()));
  }
}

/// The room a state of the video view is centred in, and no wider than a
/// readable measure on a tablet.
class _Frame extends StatelessWidget {
  const _Frame({required this.children});

  final List<Widget> children;

  static const _measure = 360.0;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(Gap.gutter, Gap.lg, Gap.gutter, Gap.xl + MediaQuery.paddingOf(context).bottom),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _measure),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    ),
  );
}

/// Before anything is copied: what the file is, and the one thing to do.
class _Card extends StatelessWidget {
  const _Card({required this.stat, required this.type, required this.onPlay});

  final RemoteStat stat;
  final FileType type;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final size = stat.size;
    return _Frame(
      children: [
        const IconTile(icon: LucideIcons.fileVideo, size: IconSize.hero),
        const SizedBox(height: Gap.md),
        Text(
          stat.name,
          textAlign: TextAlign.center,
          style: Type.title.copyWith(color: ds.text),
        ),
        const SizedBox(height: Gap.xs),
        Text(
          [type.label, if (size != null) formatBytes(size)].join(' · '),
          textAlign: TextAlign.center,
          style: Type.secondary.copyWith(color: ds.textSecondary),
        ),
        const SizedBox(height: Gap.lg),
        AppButton(label: 'Play', icon: LucideIcons.play, onPressed: onPlay),
        const SizedBox(height: Gap.md),
        Text(
          'It is copied to the phone first, then it plays from there.',
          textAlign: TextAlign.center,
          style: Type.compact.copyWith(color: ds.textMuted),
        ),
      ],
    );
  }
}

/// The copy under way: how far, and a way out.
class _Copying extends StatelessWidget {
  const _Copying({required this.stat, required this.copy, required this.willPlay});

  final RemoteStat stat;
  final FileCopyModel copy;

  /// The copy was started by Play: it plays when it is done. A copy for sharing does not.
  final bool willPlay;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final total = copy.total;
    final line = total > 0 ? '${formatBytes(copy.written)} of ${formatBytes(total)}' : formatBytes(copy.written);
    return _Frame(
      children: [
        Semantics(
          liveRegion: true,
          // No numbers: a label that changes with every piece would be read out every piece.
          label: 'Copying ${stat.name} to the phone',
          child: ExcludeSemantics(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const IconTile(icon: LucideIcons.fileVideo, size: IconSize.hero),
                const SizedBox(height: Gap.md),
                Text(
                  stat.name,
                  textAlign: TextAlign.center,
                  style: Type.title.copyWith(color: ds.text),
                ),
                const SizedBox(height: Gap.lg),
                if (total > 0) ProgressLine(fraction: copy.written / total) else const BusySpinner(size: IconSize.lead),
                const SizedBox(height: Gap.md),
                Text(
                  'Copying to the phone · $line',
                  textAlign: TextAlign.center,
                  style: Type.compact.copyWith(color: ds.textSecondary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Gap.lg),
        AppButton(label: 'Cancel', kind: AppButtonKind.secondary, onPressed: copy.cancel),
        if (willPlay) ...[
          const SizedBox(height: Gap.md),
          Text(
            'It plays when the copy is done.',
            textAlign: TextAlign.center,
            style: Type.compact.copyWith(color: ds.textMuted),
          ),
        ],
      ],
    );
  }
}

/// The copy did not finish: the machine's reason, and Retry.
class _CopyFailed extends StatelessWidget {
  const _CopyFailed({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return _Frame(
      children: [
        StatusPanel(
          color: ds.danger,
          icon: LucideIcons.circleAlert,
          title: 'Couldn\u2019t copy the video',
          message: message,
          trailing: AppButton(label: 'Retry', kind: AppButtonKind.secondary, compact: true, onPressed: onRetry),
        ),
      ],
    );
  }
}

/// The video is on the phone, and the phone's player refused it (a codec it
/// does not have): the way out is another app, or the gallery.
class _CannotPlay extends StatelessWidget {
  const _CannotPlay({required this.onShare, required this.onSave, required this.busy});

  final VoidCallback onShare;
  final VoidCallback? onSave;

  /// A share or a save is under way: the buttons wait for it.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return _Frame(
      children: [
        StatusPanel(
          color: ds.danger,
          icon: LucideIcons.circleAlert,
          title: 'This phone can\u2019t play this video',
          message:
              'Android couldn\u2019t open it, usually because of its format. Share it to open it in a player that can.',
        ),
        const SizedBox(height: Gap.lg),
        AppButton(
          label: 'Share or save\u2026',
          icon: LucideIcons.share2,
          expand: true,
          loading: busy,
          onPressed: onShare,
        ),
        if (onSave != null) ...[
          const SizedBox(height: Gap.sm),
          AppButton(
            label: 'Save to gallery',
            icon: LucideIcons.download,
            expand: true,
            kind: AppButtonKind.secondary,
            loading: busy,
            onPressed: onSave,
          ),
        ],
      ],
    );
  }
}

/// The video, whole, over its seek bar and the two ways to keep it.
class _Player extends StatelessWidget {
  const _Player({
    required this.video,
    required this.onToggle,
    required this.onShare,
    required this.onSave,
    required this.busy,
  });

  final VideoPlayerController video;
  final VoidCallback onToggle;
  final VoidCallback onShare;
  final VoidCallback? onSave;
  final bool busy;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(left: Gap.gutter, top: Gap.md, right: Gap.gutter),
          child: VideoStage(video: video, onTap: onToggle),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.gutter),
        child: VideoSeekBar(video: video),
      ),
      Padding(
        padding: EdgeInsets.only(
          left: Gap.gutter,
          right: Gap.gutter,
          bottom: Gap.md + MediaQuery.paddingOf(context).bottom,
        ),
        // Stacked: two labels side by side are cut at a narrow phone or a large text size.
        child: Column(
          spacing: Gap.sm,
          children: [
            if (onSave != null)
              AppButton(
                label: 'Save to gallery',
                icon: LucideIcons.download,
                kind: AppButtonKind.secondary,
                compact: true,
                expand: true,
                loading: busy,
                onPressed: onSave,
              ),
            AppButton(
              label: 'Share or save\u2026',
              icon: LucideIcons.share2,
              kind: AppButtonKind.secondary,
              compact: true,
              expand: true,
              loading: busy,
              onPressed: onShare,
            ),
          ],
        ),
      ),
    ],
  );
}
