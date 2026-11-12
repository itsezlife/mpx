import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/player/player_state.dart';

/// Makes the engines of one platform: Media3 on Android, AVPlayer on Apple, a
/// fake in tests.
///
/// The seam between the pool and native playback. The pool decides which
/// players hold an engine and when; a backend only creates them. Contract
/// suite: `PlayerEngineContract` in `testing.dart`.
abstract interface class PlayerBackend {
  /// A new engine for [key], idle until `PlayerEngine.prepare`.
  ///
  /// The engine reads the media's bytes itself, by [key], through the bytes
  /// cache's reader of ranged resources; the pool hands it nothing else.
  PlayerEngine create(MediaKey key);
}

/// One native player: a decoder, a buffer and a texture its frames land in.
///
/// Commands return at once and their effect shows in [state]. A command the
/// engine cannot take yet (a seek while preparing) is kept and applied when it
/// can, so the caller never orders its calls around the phases.
///
/// Every call is on the UI isolate. After [dispose] the engine is silent:
/// commands do nothing and [state] no longer changes.
abstract interface class PlayerEngine {
  /// The engine's state; see [PlayerState]. Starts idle with the default
  /// settings.
  ValueListenable<PlayerState> get state;

  /// The playhead now, read when painting. Between the engine's own reports a
  /// backend extrapolates it from the last report, the time since and the
  /// speed, so a read per frame costs no platform call.
  Duration get position;

  /// Opens the media, fills the first buffer and creates the texture, starting
  /// at [startAt]. Phases: idle, preparing, then ready (or failed). Preparing
  /// a prepared engine does nothing.
  void prepare({Duration startAt = Duration.zero});

  /// Plays once it can; sets [PlayerState.playing]. Playing at the end of a
  /// pass that does not loop starts again from the beginning.
  void play();

  /// Stops advancing; clears [PlayerState.playing].
  void pause();

  /// Moves the playhead to [position], clamped to the media.
  void seekTo(Duration position);

  /// Sets the playback rate; positive.
  void setSpeed(double speed);

  /// Sets whether a pass that ends starts again.
  void setLooping({required bool looping});

  /// Sets the audio volume, 0 to 1.
  void setVolume(double volume);

  /// Releases the decoder, the buffer and the texture. Idempotent.
  void dispose();
}
