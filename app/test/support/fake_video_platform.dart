import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The phone's video player, replaced: a player that opens, "plays" and records
/// what it was asked, so a screen can be tested without a platform channel.
/// Install with `VideoPlayerPlatform.instance = FakeVideoPlatform()`.
class FakeVideoPlatform extends VideoPlayerPlatform {
  /// What a player does when asked to open: throw this instead of opening.
  Object? openFails;

  /// When set, a player says it has opened only once this completes, as a
  /// phone's player does some frames after it was asked (the instant fake hid
  /// a view that never redrew when the real one opened).
  Completer<void>? opening;

  /// The calls, in order: `create`, `play`, `pause`, `dispose`.
  final calls = <String>[];

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (openFails != null) throw openFails!;
    calls.add('create');
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) async* {
    await opening?.future;
    yield VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(minutes: 2),
      size: const Size(1280, 720),
    );
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async => calls.add('play');

  @override
  Future<void> pause(int playerId) async => calls.add('pause');

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async => calls.add('dispose');

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const ColoredBox(color: Color(0xFF3B4A5A));
}
