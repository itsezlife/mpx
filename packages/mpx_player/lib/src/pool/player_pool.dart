import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/audio/audio_focus.dart';
import 'package:mpx_player/src/backend/player_backend.dart';
import 'package:mpx_player/src/player/player_diagnostics.dart';
import 'package:mpx_player/src/player/player_state.dart';

/// How many players may hold an engine at once: [active] that play and
/// [prepared] more kept warm (a decoder and a first buffer, not playing).
///
/// The feed and the viewer fill it; the device class and the platform's count
/// of decoder instances bound it. The default is the pager's: one playing and
/// two prepared.
@immutable
final class PlayerBudget {
  /// Creates a budget.
  const PlayerBudget({this.active = 1, this.prepared = 2})
    : assert(active >= 1, 'At least one player may play.'),
      assert(prepared >= 0, 'A prepared count is not negative.');

  /// How many players may play at once. Playing one more pauses the coldest
  /// player that plays.
  final int active;

  /// How many more players may hold an engine without playing.
  final int prepared;

  /// How many engines may be held at once.
  int get capacity => active + prepared;

  @override
  bool operator ==(Object other) =>
      other is PlayerBudget &&
      other.active == active &&
      other.prepared == prepared;

  @override
  int get hashCode => Object.hash(active, prepared);

  @override
  String toString() => 'PlayerBudget(active: $active, prepared: $prepared)';
}

/// The players of one host, one per [MediaKey], leased by the surfaces that
/// show them.
///
/// A surface takes a [PlayerLease] for a key; every lease of a key shares one
/// player, so a bubble, a feed cell, the viewer and a picture-in-picture
/// window never hold two decoders for one file, and handing a video from one
/// to another keeps its position, its buffer and its sound.
///
/// ## Engines and the budget
///
/// A player holds an engine of the [PlayerBackend] once a lease prepares or
/// plays it. The pool keeps at most [PlayerBudget.capacity] engines and lets
/// at most [PlayerBudget.active] play. Past the capacity it releases the
/// engine of the coldest player that does not play: first players nobody
/// leases, then players no view shows, then the least recently used. A
/// released player keeps its position and settings, and its lease prepares it
/// again from there. Playing one player too many pauses the coldest one that
/// plays.
///
/// When the last lease of a player is released, the player pauses and stays
/// warm, so a surface that takes the key again (the viewer closing back onto
/// its bubble) finds it where it was, until the budget needs its engine.
///
/// ## Hand-off from the software path
///
/// A clip that loops silently in a bubble (the software decoder) opens on
/// the player where the loop is: the surface takes a lease, seeks to the
/// bubble's position and plays. A player without an engine prepares from
/// that position; a warm one seeks there. The surface shows the bubble's
/// frame as the `PlayerView`'s stand-in until the engine reports its first
/// frame, so nothing flashes black. On close it reads [PlayerLease.position]
/// for the bubble to continue from, then releases its lease.
///
/// ## The sound owner
///
/// The pool is the app's one audio owner: at most one player is audible
/// (playing, not muted, not at its end). A player that becomes audible
/// takes the sound and pauses the previous owner; muted players play
/// beside it. While a player owns the sound the pool holds the platform's
/// audio focus ([PlayerBackend.audioFocus]): a call or an alarm pauses the
/// owner and its end resumes it; another app taking the sound, or the
/// headphones coming out, pauses it for good. When the owner's last view
/// goes and no other view takes it in the same turn, the host decides what
/// happens ([onSoundOwnerLeftScreen]: pause, or picture in picture); without
/// a host decision the owner pauses.
///
/// ## Picture in picture
///
/// [startPictureInPicture] moves a player that holds an engine into the
/// platform's window ([PlayerBackend.pictureInPicture]). While the window is
/// up the player counts as shown: the budget spares it and leaving the
/// screen does not fire. When the user closes the window and no view shows
/// the player, the sound owner's host decides again, as above. A host that
/// picks picture in picture over pausing calls [startPictureInPicture] from
/// [onSoundOwnerLeftScreen].
///
/// Single-threaded: every call is on the UI isolate.
final class PlayerPool {
  /// Creates a pool over [backend].
  PlayerPool({
    required PlayerBackend backend,
    PlayerBudget budget = const PlayerBudget(),
    this.onSoundOwnerLeftScreen,
  }) : _backend = backend,
       _budget = budget {
    _focusChanges = backend.audioFocus.changes.listen(_onFocusChange);
    backend.pictureInPicture.active.addListener(_onPictureInPicture);
  }

  final PlayerBackend _backend;
  PlayerBudget _budget;
  final Map<MediaKey, _Player> _players = {};
  int _uses = 0;
  bool _disposed = false;

  /// Told the key of the sound owner when no view shows it any more, so the
  /// host pauses it or moves it to picture in picture. Null pauses it.
  final void Function(MediaKey key)? onSoundOwnerLeftScreen;

  late final StreamSubscription<AudioFocusChange> _focusChanges;
  _Player? _owner;
  // The owner a transient interruption paused; resumed when focus returns.
  _Player? _resumeOnGain;
  bool _focusHeld = false;

  final ValueNotifier<MediaKey?> _pictureInPicture = ValueNotifier(null);
  _Player? _inPictureInPicture;

  /// The key of the player in the picture-in-picture window, or null.
  ValueListenable<MediaKey?> get pictureInPicture => _pictureInPicture;

  /// Moves the player of [key] into the platform's picture-in-picture
  /// window. Returns false when the platform has none or the player holds no
  /// engine; true when the window was asked for ([pictureInPicture] follows
  /// once it is up).
  bool startPictureInPicture(MediaKey key) {
    final pip = _backend.pictureInPicture;
    final player = _players[key];
    final engine = player?._engine;
    if (_disposed || !pip.isSupported || player == null || engine == null) {
      return false;
    }
    if (!player.holdsEngine) return false;
    player.touch();
    pip.start(engine);
    return true;
  }

  /// Closes the picture-in-picture window, if one is up.
  void stopPictureInPicture() {
    if (!_disposed) _backend.pictureInPicture.stop();
  }

  // The backend's window changed: the player it shows counts as one more
  // view, and the one it stopped showing one fewer.
  void _onPictureInPicture() {
    if (_disposed) return;
    final engine = _backend.pictureInPicture.active.value;
    final shown = engine == null
        ? null
        : _players.values
              .where((player) => identical(player._engine, engine))
              .firstOrNull;
    final previous = _inPictureInPicture;
    if (identical(previous, shown)) return;
    _inPictureInPicture = shown;
    if (shown != null) shown.views++;
    _pictureInPicture.value = shown?.key;
    if (previous != null && !previous.disposed) {
      previous.views--;
      if (previous.views == 0) _viewsGone(previous);
    }
  }

  /// The key of the player that owns the sound, or null when none is
  /// audible.
  MediaKey? get soundOwner => _owner?.key;

  /// How many engines the pool may hold and play.
  PlayerBudget get budget => _budget;
  set budget(PlayerBudget value) {
    if (value == _budget) return;
    _budget = value;
    _enforce();
  }

  /// How many players hold an engine now.
  int get engineCount => _players.values.where((p) => p.holdsEngine).length;

  /// Whether [dispose] has run.
  bool get isDisposed => _disposed;

  /// A lease of the player for [key], created if the pool has none. Taking a
  /// lease makes the player the most recently used.
  ///
  /// Throws a [StateError] after [dispose].
  PlayerLease lease(MediaKey key) {
    if (_disposed) throw StateError('PlayerPool.lease called after dispose.');
    final player = _players.putIfAbsent(key, () => _Player(this, key));
    player.leases++;
    player.touch();
    return PlayerLease._(player);
  }

  /// Releases every engine and gives the audio focus back. Leases still
  /// around go silent. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_focusChanges.cancel());
    _backend.pictureInPicture.active.removeListener(_onPictureInPicture);
    if (_inPictureInPicture != null) _backend.pictureInPicture.stop();
    _inPictureInPicture = null;
    _pictureInPicture.dispose();
    _owner = null;
    _resumeOnGain = null;
    _setFocus(held: false);
    for (final player in _players.values) {
      player.dispose();
    }
    _players.clear();
  }

  int _nextUse() => ++_uses;

  // Coldest first: unleased, then unshown, then least recently used.
  static int _byWarmth(_Player a, _Player b) {
    final leased = (a.leases > 0 ? 1 : 0) - (b.leases > 0 ? 1 : 0);
    if (leased != 0) return leased;
    final shown = (a.views > 0 ? 1 : 0) - (b.views > 0 ? 1 : 0);
    if (shown != 0) return shown;
    return a.lastUse - b.lastUse;
  }

  // Brings the engines and the playing players back inside the budget,
  // sparing [keep], the player that just asked for its engine or to play.
  void _enforce({_Player? keep}) {
    if (_disposed) return;
    final playing = _players.values.where((p) => p.isPlaying).toList()
      ..sort(_byWarmth);
    while (playing.length > _budget.active) {
      final coldest = playing.firstWhere(
        (p) => !identical(p, keep),
        orElse: () => playing.first,
      );
      playing.remove(coldest);
      coldest.pause();
    }
    final holding = _players.values.where((p) => p.holdsEngine).toList()
      ..sort(_byWarmth);
    var excess = holding.length - _budget.capacity;
    for (final player in holding) {
      if (excess <= 0) break;
      if (identical(player, keep) || player.isPlaying) continue;
      player.releaseEngine();
      if (player.leases == 0) _forget(player);
      excess--;
    }
  }

  // --- Sound owner ----------------------------------------------------------

  // Called whenever [player]'s audibility may have changed: a command, an
  // engine state, a pause by the budget. An audible player takes the sound;
  // an owner that went quiet gives it back, unless an interruption paused
  // it and focus is due back.
  void _soundChanged(_Player player) {
    if (_disposed) return;
    if (player.isAudible) {
      if (identical(_owner, player)) return;
      final previous = _owner;
      _owner = player;
      _resumeOnGain = null;
      previous?.pause();
      _setFocus(held: true);
    } else if (identical(_owner, player) && !identical(_resumeOnGain, player)) {
      _owner = null;
      _setFocus(held: false);
    }
  }

  // [player] was paused or muted by a command, not by an interruption: it
  // is not resumed when focus comes back.
  void _quietedByCommand(_Player player) {
    if (identical(_resumeOnGain, player)) _resumeOnGain = null;
    _soundChanged(player);
  }

  void _setFocus({required bool held}) {
    if (held == _focusHeld) return;
    _focusHeld = held;
    if (held) {
      _backend.audioFocus.request();
    } else {
      _backend.audioFocus.abandon();
    }
  }

  void _onFocusChange(AudioFocusChange change) {
    if (_disposed) return;
    final owner = _owner;
    switch (change) {
      case AudioFocusChange.interrupted:
        if (owner == null || !owner.isAudible) return;
        _resumeOnGain = owner;
        owner.pauseQuietly();
      case AudioFocusChange.gained:
        final paused = _resumeOnGain;
        _resumeOnGain = null;
        if (paused != null && !paused.disposed && paused.leases > 0) {
          paused.play();
        } else if (paused != null) {
          _soundChanged(paused);
        }
      case AudioFocusChange.lost || AudioFocusChange.outputRemoved:
        _resumeOnGain = null;
        owner?.pause();
    }
  }

  // The last view of [player] went. If no view takes it in the same turn (a
  // hand-off from the bubble to the viewer detaches one and attaches the
  // other within one frame) and it still owns the sound, the host decides.
  void _viewsGone(_Player player) {
    if (!identical(_owner, player)) return;
    scheduleMicrotask(() {
      if (_disposed || !identical(_owner, player) || player.views > 0) return;
      if (!player.isAudible) return;
      final decide = onSoundOwnerLeftScreen;
      if (decide != null) {
        decide(player.key);
      } else {
        player.pause();
      }
    });
  }

  void _forget(_Player player) {
    if (identical(_players[player.key], player)) _players.remove(player.key);
    player.dispose();
  }
}

/// One surface's hold on the player of [key], from `PlayerPool.lease` until
/// [release].
///
/// Commands go to the player every lease of the key shares: a pause from one
/// surface pauses them all. Commands work before the player holds an engine
/// and are applied when it gets one. After [release] the lease is silent:
/// commands do nothing.
final class PlayerLease {
  PlayerLease._(this._player);

  final _Player _player;
  bool _released = false;

  /// Which media.
  MediaKey get key => _player.key;

  /// The player's state, shared by every lease of the key.
  ValueListenable<PlayerState> get state => _player.state;

  /// The playhead now; read it when painting. A player without an engine
  /// answers the position it will prepare from.
  Duration get position => _player.position;

  /// How many views show the player, through any lease.
  int get viewCount => _player.views;

  /// Whether [release] has run.
  bool get isReleased => _released;

  bool get _live => !_released && !_player.disposed;

  /// Takes an engine and fills its first buffer without playing.
  void prepare() {
    if (_live) _player.prepare();
  }

  /// Plays, preparing first if needed.
  void play() {
    if (_live) _player.play();
  }

  /// Pauses.
  void pause() {
    if (_live) _player.pause();
  }

  /// Moves the playhead to [position].
  void seekTo(Duration position) {
    if (_live) _player.seekTo(position);
  }

  /// Sets the playback rate.
  void setSpeed(double speed) {
    if (_live) _player.setSpeed(speed);
  }

  /// Sets whether a pass that ends starts again.
  void setLooping({required bool looping}) {
    if (_live) _player.setLooping(looping: looping);
  }

  /// Sets the audio volume, 0 to 1.
  void setVolume(double volume) {
    if (_live) _player.setVolume(volume);
  }

  /// Records that a view shows the player until the returned attachment is
  /// detached. Shown players are the last the budget releases.
  PlayerViewAttachment attachView() {
    if (!_live) return PlayerViewAttachment._(null);
    final player = _player..touch();
    player.views++;
    return PlayerViewAttachment._(() {
      player.views--;
      if (player.views == 0 && !player.disposed) player.pool._viewsGone(player);
    });
  }

  /// Gives the lease back. The last lease of a player pauses it; the player
  /// stays warm until the budget needs its engine. Idempotent.
  void release() {
    if (_released) return;
    _released = true;
    if (!_player.disposed) _player.leaseReleased();
  }
}

/// A view's claim that it shows a player, from `PlayerLease.attachView` until
/// [detach].
final class PlayerViewAttachment {
  PlayerViewAttachment._(this._onDetach);

  void Function()? _onDetach;

  /// Whether [detach] has run.
  bool get isDetached => _onDetach == null;

  /// Gives the claim back. Idempotent.
  void detach() {
    final onDetach = _onDetach;
    _onDetach = null;
    onDetach?.call();
  }
}

// --- Internals --------------------------------------------------------------

final class _Player {
  _Player(this.pool, this.key);

  final PlayerPool pool;
  final MediaKey key;
  final ValueNotifier<PlayerState> state = ValueNotifier(const PlayerState());

  PlayerEngine? _engine;
  // Where the next engine starts: the last engine's position when it was
  // released, or a seek made without an engine.
  Duration _resumeAt = Duration.zero;
  int leases = 0;
  int views = 0;
  int lastUse = 0;
  bool disposed = false;

  bool get holdsEngine => _engine != null && state.value.holdsEngine;

  bool get isPlaying => _engine != null && state.value.playing;

  // Playing, not muted and not at its end: the player is heard.
  bool get isAudible =>
      isPlaying &&
      state.value.volume > 0 &&
      state.value.phase != PlayerPhase.ended;

  Duration get position => _engine?.position ?? _resumeAt;

  void touch() => lastUse = pool._nextUse();

  PlayerEngine _ensureEngine() {
    final current = _engine;
    if (current != null && current.state.value.phase != PlayerPhase.failed) {
      return current;
    }
    if (current != null) {
      PlayerDiagnostics.log('pool: $key drops its failed engine for a new one');
      _dropEngine(current);
    }
    final wish = state.value;
    final engine = pool._backend.create(key)
      ..setSpeed(wish.speed)
      ..setLooping(looping: wish.looping)
      ..setVolume(wish.volume)
      ..prepare(startAt: _resumeAt);
    if (wish.playing) engine.play();
    _engine = engine;
    engine.state.addListener(_mirror);
    _mirror();
    pool._enforce(keep: this);
    return engine;
  }

  void _mirror() {
    final engine = _engine;
    if (engine == null || disposed) return;
    state.value = engine.state.value;
    pool._soundChanged(this);
  }

  void prepare() {
    touch();
    _ensureEngine();
  }

  void play() {
    touch();
    state.value = state.value.copyWith(playing: true);
    _ensureEngine().play();
    pool
      .._enforce(keep: this)
      .._soundChanged(this);
  }

  void pause() {
    pauseQuietly();
    pool._quietedByCommand(this);
  }

  // Pauses without telling the sound owner it was a command: an
  // interruption pauses this way and resumes when focus returns.
  void pauseQuietly() {
    _engine?.pause();
    if (!disposed) state.value = state.value.copyWith(playing: false);
  }

  void seekTo(Duration position) {
    touch();
    final engine = _engine;
    if (engine == null) {
      _resumeAt = position.isNegative ? Duration.zero : position;
    } else {
      engine.seekTo(position);
    }
  }

  void setSpeed(double speed) {
    touch();
    _engine?.setSpeed(speed);
    if (_engine == null) state.value = state.value.copyWith(speed: speed);
  }

  void setLooping({required bool looping}) {
    touch();
    _engine?.setLooping(looping: looping);
    if (_engine == null) state.value = state.value.copyWith(looping: looping);
  }

  void setVolume(double volume) {
    touch();
    _engine?.setVolume(volume);
    if (_engine == null) state.value = state.value.copyWith(volume: volume);
    pool._quietedByCommand(this);
  }

  void leaseReleased() {
    leases--;
    touch();
    if (leases > 0) return;
    pause();
    if (_engine == null) pool._forget(this);
  }

  void releaseEngine() {
    final engine = _engine;
    if (engine == null) return;
    PlayerDiagnostics.log(
      'pool: the budget releases the engine of $key '
      '(leases $leases, views $views, playing $isPlaying)',
    );
    _resumeAt = engine.position;
    _dropEngine(engine);
    if (!disposed) state.value = state.value.released();
    pool._soundChanged(this);
  }

  void _dropEngine(PlayerEngine engine) {
    final pip = pool._backend.pictureInPicture;
    if (identical(pip.active.value, engine)) pip.stop();
    engine.state.removeListener(_mirror);
    engine.dispose();
    _engine = null;
  }

  void dispose() {
    if (disposed) return;
    final engine = _engine;
    if (engine != null) _dropEngine(engine);
    disposed = true;
    state.dispose();
  }
}
