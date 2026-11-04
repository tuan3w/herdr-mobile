import 'package:herdr_mobile/l10n/l10n_context.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

import 'press.dart';
import 'theme.dart';

String _clock(Duration d) {
  final s = d.inSeconds;
  final m = (s ~/ 60) % 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return s >= 3600 ? '${s ~/ 3600}:${m.toString().padLeft(2, '0')}:$sec' : '$m:$sec';
}

/// The one place a video is shown: the picture, whole, in a rounded frame; a
/// tap pauses or resumes it, and the end offers Play again. The pause and
/// replay marks are drawn only when it is not playing: nothing moves over a
/// playing video.
class VideoStage extends StatelessWidget {
  const VideoStage({super.key, required this.video, required this.onTap});

  final VideoPlayerController video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: video,
      builder: (context, v, _) {
        final ended = v.isCompleted || (v.duration > Duration.zero && v.position >= v.duration);
        return Semantics(
          button: true,
          label: ended ? context.l10n.uiPlayAgain : (v.isPlaying ? context.l10n.uiPause : context.l10n.uiPlay),
          excludeSemantics: true,
          child: PressBuilder(
            onTap: onTap,
            builder: (context, _) => Center(
              child: AspectRatio(
                aspectRatio: v.aspectRatio,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayer(video),
                      if (!v.isPlaying)
                        Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: ds.inverseSurface,
                              borderRadius: BorderRadius.circular(Radii.pill),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.md, Gap.xs),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    ended ? LucideIcons.rotateCcw : LucideIcons.play,
                                    size: IconSize.inline,
                                    color: ds.onInverse,
                                  ),
                                  const SizedBox(width: Gap.xs),
                                  Text(
                                    ended ? context.l10n.uiPlayAgain : context.l10n.uiPlay,
                                    style: Type.labelStrong.copyWith(color: ds.onInverse),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Where the video is and how long it is, with a bar to drag along it. The
/// position text is the only thing that changes while it plays.
class VideoSeekBar extends StatelessWidget {
  const VideoSeekBar({super.key, required this.video});

  final VideoPlayerController video;

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final style = Type.caption.copyWith(color: ds.textSecondary, fontFeatures: Type.tabular);
    return Row(
      children: [
        ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: video,
          builder: (context, v, _) => Text(_clock(v.position), style: style),
        ),
        const SizedBox(width: Gap.md),
        Expanded(
          child: VideoProgressIndicator(
            video,
            allowScrubbing: true,
            padding: const EdgeInsets.symmetric(vertical: Gap.md),
            colors: VideoProgressColors(playedColor: ds.accent, bufferedColor: ds.fill, backgroundColor: ds.fill),
          ),
        ),
        const SizedBox(width: Gap.md),
        Text(_clock(video.value.duration), style: style),
      ],
    );
  }
}
