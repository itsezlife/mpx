import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// Where a player stands in its life, as one closed set.
///
/// Whether it plays once it can is not a phase: that is
/// [PlayerState.playing], the wish, which survives buffering and the end of a
/// pass the way a backend's "play when ready" does.
enum PlayerPhase {
  /// Nothing is held: no decoder, no texture. A new player, and one whose
  /// engine the pool released to stay inside its budget.
  idle,

  /// The engine opens the media and fills its first buffer.
  preparing,

  /// The engine holds a decoder and a buffer and can show frames now.
  ready,

  /// The engine ran out of buffer while it could play and waits for bytes.
  buffering,

  /// A pass that does not loop reached its end.
  ended,

  /// The media cannot play; [PlayerState.error] says why.
  failed,
}

/// A stretch of the media, from [start] to [end], that is buffered.
@immutable
final class PlayerTimeRange {
  /// Creates a range; [end] is not before [start].
  const PlayerTimeRange(this.start, this.end)
    : assert(start <= end, 'A range ends no earlier than it starts.');

  /// Where the range starts.
  final Duration start;

  /// Where the range ends.
  final Duration end;

  /// Whether [position] falls inside the range, both ends included.
  bool contains(Duration position) => position >= start && position <= end;

  @override
  bool operator ==(Object other) =>
      other is PlayerTimeRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'PlayerTimeRange($start, $end)';
}

/// What a player is, as one immutable value: its phase, what it holds
/// buffered, the size of its picture and the settings it plays with.
///
/// It changes seldom (a phase, a buffer step, a command) and is pushed to
/// listeners. The playhead is not part of it: it moves every frame and is read
/// when painting (`PlayerLease.position`), never pushed.
@immutable
final class PlayerState {
  /// Creates a state; the default is a new, idle player.
  const PlayerState({
    this.phase = PlayerPhase.idle,
    this.playing = false,
    this.duration,
    this.buffered = const [],
    this.videoSize,
    this.quarterTurns = 0,
    this.textureId,
    this.firstFrameRendered = false,
    this.speed = 1,
    this.looping = false,
    this.volume = 1,
    this.error,
  }) : assert(
         (phase == PlayerPhase.failed) == (error != null),
         'A failed player carries its error, and only a failed one.',
       ),
       assert(speed > 0, 'Speed is positive.'),
       assert(volume >= 0 && volume <= 1, 'Volume is 0 to 1.');

  /// Where the player stands.
  final PlayerPhase phase;

  /// Whether the player plays as soon as it can: the host's wish, kept while
  /// it prepares or buffers. A player that is [playing] in [PlayerPhase.ready]
  /// advances its playhead.
  final bool playing;

  /// How long the media lasts, once the engine knows; null before, and for a
  /// live stream.
  final Duration? duration;

  /// The buffered stretches of the media, in order.
  final List<PlayerTimeRange> buffered;

  /// The size of the decoded picture in pixels, before [quarterTurns]; null
  /// until the engine knows it, and for media without video.
  final Size? videoSize;

  /// Clockwise quarter turns a view applies to show the picture upright.
  ///
  /// A backend whose texture is already upright reports 0. Where the engine's
  /// texture comes unrotated (Android's zero-copy path), the rotation of the
  /// media's track is reported here and the view turns the picture, so every
  /// backend shows the same thing through one view.
  final int quarterTurns;

  /// The engine's texture the picture is drawn into, or null while it holds
  /// none (idle, preparing, failed).
  final int? textureId;

  /// Whether the texture shows a frame of this media yet. A view keeps the
  /// stand-in it was given (the bubble's frame) until it does.
  final bool firstFrameRendered;

  /// The playback rate, 1 for normal speed.
  final double speed;

  /// Whether a pass that ends starts again from the beginning.
  final bool looping;

  /// The audio volume, 0 (silent) to 1.
  final double volume;

  /// Why the player failed, for logs and for the host's decision to show an
  /// error; non-null exactly in [PlayerPhase.failed].
  final Object? error;

  /// The size of the picture as it is shown, after [quarterTurns]; null while
  /// [videoSize] is.
  Size? get displaySize => switch (videoSize) {
    null => null,
    final size when quarterTurns.isOdd => size.flipped,
    final size => size,
  };

  /// Whether the engine holds a decoder: neither idle nor failed.
  bool get holdsEngine =>
      phase != PlayerPhase.idle && phase != PlayerPhase.failed;

  /// Whether [position] is inside a buffered range.
  bool isBuffered(Duration position) =>
      buffered.any((range) => range.contains(position));

  /// A copy with the given fields replaced. [error] is cleared unless given,
  /// since only a failed state carries one.
  PlayerState copyWith({
    PlayerPhase? phase,
    bool? playing,
    Duration? duration,
    List<PlayerTimeRange>? buffered,
    Size? videoSize,
    int? quarterTurns,
    int? textureId,
    bool? firstFrameRendered,
    double? speed,
    bool? looping,
    double? volume,
    Object? error,
  }) => PlayerState(
    phase: phase ?? this.phase,
    playing: playing ?? this.playing,
    duration: duration ?? this.duration,
    buffered: buffered ?? this.buffered,
    videoSize: videoSize ?? this.videoSize,
    quarterTurns: quarterTurns ?? this.quarterTurns,
    textureId: textureId ?? this.textureId,
    firstFrameRendered: firstFrameRendered ?? this.firstFrameRendered,
    speed: speed ?? this.speed,
    looping: looping ?? this.looping,
    volume: volume ?? this.volume,
    error: error,
  );

  /// The same settings without anything the engine held: what a player shows
  /// once its engine is released. The wish to play is kept, so the next
  /// prepare picks it up.
  PlayerState released() => PlayerState(
    playing: playing,
    duration: duration,
    videoSize: videoSize,
    quarterTurns: quarterTurns,
    speed: speed,
    looping: looping,
    volume: volume,
  );

  @override
  bool operator ==(Object other) =>
      other is PlayerState &&
      other.phase == phase &&
      other.playing == playing &&
      other.duration == duration &&
      listEquals(other.buffered, buffered) &&
      other.videoSize == videoSize &&
      other.quarterTurns == quarterTurns &&
      other.textureId == textureId &&
      other.firstFrameRendered == firstFrameRendered &&
      other.speed == speed &&
      other.looping == looping &&
      other.volume == volume &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    phase,
    playing,
    duration,
    Object.hashAll(buffered),
    videoSize,
    quarterTurns,
    textureId,
    firstFrameRendered,
    speed,
    looping,
    volume,
    error,
  );

  @override
  String toString() =>
      'PlayerState(${phase.name}, playing: $playing, duration: $duration, '
      'buffered: $buffered, videoSize: $videoSize, '
      'quarterTurns: $quarterTurns, textureId: $textureId, '
      'firstFrameRendered: $firstFrameRendered, speed: $speed, '
      'looping: $looping, volume: $volume, error: $error)';
}
