import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';

/// Sound in a list of posts, as a feed of video has it: every clip plays
/// muted and loops on the software path, and the reader's switch gives
/// sound to one at a time, the one most in view.
///
/// The pool is the one sound owner (ADR 0004), so this holds at most one
/// lease. The switch is the reader's, shared by every list: once on, the
/// next clip that comes into view takes the sound as the last one leaves.
///
/// Headless: a tile reports how much of it shows ([report]) and asks for the
/// switch ([toggle]); what it draws of the result is its own.
final class InlineSound extends ChangeNotifier {
  /// Creates the switch over [pool], or one that is never available.
  InlineSound(this._pool);

  final PlayerPool? _pool;

  /// How much of a clip must show for it to take the sound, and how little it
  /// may show before it gives the sound back.
  static const double takesAt = 0.6;
  static const double leavesBelow = 0.35;

  final Map<MediaKey, double> _shown = {};
  PlayerLease? _lease;
  MediaKey? _playing;
  bool _wanted = false;
  bool _suspended = false;
  bool _disposed = false;

  /// Whether the build has a player to give sound with.
  bool get isAvailable => _pool != null;

  /// Whether the reader switched the sound on.
  bool get isWanted => _wanted;

  /// The clip that plays aloud, or null.
  MediaKey? get playing => _playing;

  /// The lease of [playing], for the view that draws it.
  PlayerLease? get lease => _lease;

  /// The reader's switch on [key]'s tile: on gives it the sound, off (on the
  /// clip that has it) takes it from every clip.
  void toggle(MediaKey key) {
    if (_pool == null) return;
    if (_playing == key) {
      _wanted = false;
      _stop();
    } else {
      _wanted = true;
      _suspended = false;
      _start(key);
    }
  }

  /// [key]'s tile shows [fraction] of itself now.
  void report(MediaKey key, double fraction) {
    if (fraction <= 0) {
      _shown.remove(key);
    } else {
      _shown[key] = fraction;
    }
    _reconsider();
  }

  /// [key]'s tile is gone.
  void forget(MediaKey key) {
    _shown.remove(key);
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

  void _reconsider() {
    if (!_wanted || _suspended || _pool == null) return;
    final playing = _playing;
    if (playing != null) {
      if ((_shown[playing] ?? 0) < leavesBelow) _stop();
      if (_playing != null) return;
    }
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
    _stop();
    _lease = pool.lease(key)
      ..setLooping(looping: true)
      ..setVolume(1)
      ..play();
    _playing = key;
    notifyListeners();
  }

  void _stop() {
    final lease = _lease;
    if (lease == null) return;
    _lease = null;
    _playing = null;
    lease
      ..pause()
      ..release();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    super.dispose();
  }
}
