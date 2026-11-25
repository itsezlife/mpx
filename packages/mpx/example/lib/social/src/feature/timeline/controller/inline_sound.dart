import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

/// Sound in a list of posts, as a feed of video has it: every clip plays
/// muted and loops on the software path, and the reader's switch gives
/// sound to one at a time, the one most in view.
///
/// The pool is the one sound owner (ADR 0004), so this holds at most one
/// lease. The sound is that lease's volume: the clip that has it is drawn by
/// its player, and switching the sound off on it only mutes the player, so
/// the picture and the time never change hands (one track, not two that drift
/// apart). It gives the player back once the clip leaves the view.
///
/// - **The switch** is the reader's, shared by every list: once on, the next
///   clip that comes into view takes the sound as the last one leaves.
/// - **Where it starts**: a clip takes the player at the place its loop is
///   (`clipPosition` of [report]), so the sound goes on from the picture.
/// - **The layers** that pause a feed (the app out of focus, a route moving)
///   pause the player and their end plays it again, as the feed's own clips
///   do; the pool does not know them.
/// - **The system volume**: [unmute] is what a rise of it does, as a volume key
///   does: the clip that plays muted gets its sound, or the
///   clip most in view takes it.
///
/// Headless: a tile reports how much of it shows ([report]) and asks for the
/// switch ([toggle]); what it draws of the result is its own.
final class InlineSound extends ChangeNotifier {
  /// Creates the switch over [pool], or one that is never available. With a
  /// [clock] the layers of [pausingLayers] pause the player.
  InlineSound(
    this._pool, {
    PlaybackClock? clock,
    Set<PlaybackPauseLayer> pausingLayers = FeedPolicy.standardPausingLayers,
  }) : _clock = clock,
       _pausingLayers = pausingLayers {
    _clock?.addLayerListener(_onLayers);
  }

  final PlayerPool? _pool;
  final PlaybackClock? _clock;
  final Set<PlaybackPauseLayer> _pausingLayers;

  /// How much of a clip must show for it to take the sound, and how little it
  /// may show before it gives the sound back.
  static const double takesAt = 0.6;
  static const double leavesBelow = 0.35;

  final Map<MediaKey, double> _shown = {};
  final Map<MediaKey, Duration? Function()?> _positions = {};
  PlayerLease? _lease;
  MediaKey? _playing;
  bool _soundOn = false;
  bool _wanted = false;
  bool _suspended = false;
  bool _disposed = false;

  /// Whether the build has a player to give sound with.
  bool get isAvailable => _pool != null;

  /// Whether the reader switched the sound on: the next clips in view take
  /// it.
  bool get isWanted => _wanted;

  /// Whether the player that plays has its sound on (it may play muted).
  bool get isSoundOn => _soundOn;

  /// The clip that plays on the player, aloud or not, or null.
  MediaKey? get playing => _playing;

  /// The lease of [playing], for the view that draws it.
  PlayerLease? get lease => _lease;

  /// Where the player of [key] is, when it plays that clip now, else null.
  /// Read before a [suspend]: the viewer that takes the player goes on from
  /// there.
  Duration? positionOf(MediaKey key) =>
      _playing == key ? _lease?.position : null;

  /// The reader's switch on [key]'s tile: on gives it the sound, off (on the
  /// clip that has it) mutes it and takes the sound from every other clip.
  void toggle(MediaKey key) {
    if (_pool == null) return;
    if (_playing == key) {
      _setSound(on: !_soundOn);
      _wanted = _soundOn;
      notifyListeners();
    } else {
      _wanted = true;
      _suspended = false;
      _start(key);
    }
  }

  /// The system volume went up: the clip that plays muted gets its sound, and
  /// with none playing the clip most in view takes it.
  void unmute() {
    if (_pool == null || _disposed) return;
    _wanted = true;
    if (_playing != null) {
      if (!_soundOn) {
        _setSound(on: true);
        notifyListeners();
      }
      return;
    }
    _reconsider();
  }

  /// [key]'s tile shows [fraction] of itself now. [clipPosition] reads where
  /// its loop is, for the sound to start from.
  void report(
    MediaKey key,
    double fraction, {
    Duration? Function()? clipPosition,
  }) {
    if (fraction <= 0) {
      _shown.remove(key);
    } else {
      _shown[key] = fraction;
    }
    if (clipPosition != null) _positions[key] = clipPosition;
    _reconsider();
  }

  /// [key]'s tile is gone.
  void forget(MediaKey key) {
    _shown.remove(key);
    _positions.remove(key);
    if (_playing == key) _stop();
    _reconsider();
  }

  /// Nothing plays aloud while a surface that plays its own sound is over the
  /// list (the viewer); [resume] gives it back.
  void suspend() {
    _suspended = true;
    _stop();
  }

  /// Ends a [suspend].
  void resume() {
    _suspended = false;
    _reconsider();
  }

  bool get _gated {
    final clock = _clock;
    return clock != null && clock.pausedLayers.any(_pausingLayers.contains);
  }

  // The layers changed: the player pauses with them and plays when they end.
  void _onLayers() {
    final lease = _lease;
    if (lease == null || _disposed) return;
    if (_gated) {
      lease.pause();
    } else {
      _playIfShown();
    }
  }

  void _playIfShown() {
    final lease = _lease;
    final key = _playing;
    if (lease == null || key == null || _gated || _suspended) return;
    if ((_shown[key] ?? 0) < leavesBelow) return;
    if (!lease.state.value.playing) lease.play();
  }

  void _setSound({required bool on}) {
    _soundOn = on;
    _lease?.setVolume(on ? 1 : 0);
  }

  void _reconsider() {
    if (_suspended || _pool == null) return;
    final playing = _playing;
    if (playing != null) {
      if ((_shown[playing] ?? 0) < leavesBelow) _stop();
      if (_playing != null) {
        // Back in view after a pause, the player plays on.
        _playIfShown();
        return;
      }
    }
    if (!_wanted) return;
    MediaKey? best;
    var bestFraction = takesAt;
    for (final MapEntry(:key, :value) in _shown.entries) {
      if (value >= bestFraction) {
        best = key;
        bestFraction = value;
      }
    }
    if (best != null) _start(best);
  }

  void _start(MediaKey key) {
    final pool = _pool;
    if (pool == null || _disposed) return;
    _stop(notify: false);
    final lease = _lease = pool.lease(key)..setLooping(looping: true);
    _soundOn = true;
    lease.setVolume(1);
    // From where the loop of the clip is, so the sound goes on from the
    // picture the reader is looking at.
    final from = _positions[key]?.call();
    if (from != null && from > Duration.zero) lease.seekTo(from);
    _playing = key;
    if (!_gated) lease.play();
    notifyListeners();
  }

  void _stop({bool notify = true}) {
    final lease = _lease;
    if (lease == null) return;
    _lease = null;
    _playing = null;
    _soundOn = false;
    lease
      ..pause()
      ..release();
    if (notify && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clock?.removeLayerListener(_onLayers);
    _stop(notify: false);
    super.dispose();
  }
}
