import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/audio/audio_focus.dart';
import 'package:mpx_player/src/backend/player_backend.dart';
import 'package:mpx_player/src/player/player_state.dart';

/// A [PlayerBackend] that plays nothing: its engines move through the phases
/// the way a native one does, and a test drives their playhead.
///
/// With [autoPrepare] an engine becomes ready a microtask after `prepare`, as
/// the contract suite expects; without it the test calls
/// [FakePlayerEngine.completePrepare] or [FakePlayerEngine.fail].
final class FakePlayerBackend implements PlayerBackend {
  /// Creates a backend whose media is [videoSize] large and [duration] long.
  /// Keys in [unplayable] fail to prepare.
  FakePlayerBackend({
    this.autoPrepare = true,
    this.videoSize = const Size(1280, 720),
    this.duration = const Duration(seconds: 60),
    this.unplayable = const {},
  });

  /// Whether engines become ready on their own.
  final bool autoPrepare;

  /// The picture size every engine reports.
  final Size videoSize;

  /// How long every engine's media lasts.
  final Duration duration;

  /// Keys whose engines fail to prepare.
  final Set<MediaKey> unplayable;

  @override
  final FakeAudioFocus audioFocus = FakeAudioFocus();

  final List<FakePlayerEngine> _created = [];
  int _nextTexture = 1;

  /// Every engine created, oldest first.
  List<FakePlayerEngine> get created => List.unmodifiable(_created);

  /// The engines not disposed yet.
  List<FakePlayerEngine> get live =>
      _created.where((engine) => !engine.isDisposed).toList();

  /// The newest engine created for [key], or null.
  FakePlayerEngine? latestFor(MediaKey key) {
    for (final engine in _created.reversed) {
      if (engine.key == key) return engine;
    }
    return null;
  }

  @override
  FakePlayerEngine create(MediaKey key) {
    final engine = FakePlayerEngine._(this, key);
    _created.add(engine);
    return engine;
  }
}

/// An engine of [FakePlayerBackend].
final class FakePlayerEngine implements PlayerEngine {
  FakePlayerEngine._(this._backend, this.key);

  final FakePlayerBackend _backend;

  /// The media this engine plays.
  final MediaKey key;

  final ValueNotifier<PlayerState> _state = ValueNotifier(const PlayerState());
  Duration _position = Duration.zero;
  Duration? _pendingSeek;
  bool _disposed = false;
  int _prepares = 0;

  /// Whether [dispose] has run.
  bool get isDisposed => _disposed;

  /// How many times [prepare] started a preparation.
  int get prepareCount => _prepares;

  @override
  ValueListenable<PlayerState> get state => _state;

  @override
  Duration get position => _position;

  @override
  void prepare({Duration startAt = Duration.zero}) {
    if (_disposed || _state.value.phase != PlayerPhase.idle) return;
    _prepares++;
    _position = _clamp(startAt);
    _emit(_state.value.copyWith(phase: PlayerPhase.preparing));
    if (_backend.autoPrepare) scheduleMicrotask(_autoComplete);
  }

  void _autoComplete() {
    if (_disposed || _state.value.phase != PlayerPhase.preparing) return;
    if (_backend.unplayable.contains(key)) {
      fail(StateError('$key cannot play'));
    } else {
      completePrepare();
    }
  }

  /// Ends a preparation successfully: a texture, the size and the duration,
  /// the first buffer and the first frame.
  void completePrepare() {
    if (_disposed || _state.value.phase != PlayerPhase.preparing) return;
    final pending = _pendingSeek;
    _pendingSeek = null;
    if (pending != null) _position = _clamp(pending);
    _emit(
      _state.value.copyWith(
        phase: PlayerPhase.ready,
        textureId: _backend._nextTexture++,
        videoSize: _backend.videoSize,
        duration: _backend.duration,
        buffered: [PlayerTimeRange(_position, _clamp(_position + _ahead))],
        firstFrameRendered: true,
      ),
    );
  }

  static const Duration _ahead = Duration(seconds: 5);

  /// Ends a preparation, or playback, with [error].
  void fail(Object error) {
    if (_disposed) return;
    _emit(
      _state.value.released().copyWith(phase: PlayerPhase.failed, error: error),
    );
  }

  /// Reports a stall: the engine waits for bytes.
  void stall() {
    if (_disposed || _state.value.phase != PlayerPhase.ready) return;
    _emit(_state.value.copyWith(phase: PlayerPhase.buffering));
  }

  /// Ends a stall.
  void resume() {
    if (_disposed || _state.value.phase != PlayerPhase.buffering) return;
    _emit(_state.value.copyWith(phase: PlayerPhase.ready));
  }

  /// Moves the playhead as [elapsed] of wall time would, at the current
  /// speed, if the engine plays: wraps when looping, ends otherwise.
  void advance(Duration elapsed) {
    final current = _state.value;
    if (_disposed || !current.playing || current.phase != PlayerPhase.ready) {
      return;
    }
    final duration = current.duration ?? _backend.duration;
    final next = _position + elapsed * current.speed;
    if (next < duration) {
      _position = next;
    } else if (current.looping) {
      _position = Duration(
        microseconds: next.inMicroseconds % duration.inMicroseconds,
      );
    } else {
      _position = duration;
      _emit(current.copyWith(phase: PlayerPhase.ended));
    }
  }

  @override
  void play() {
    if (_disposed) return;
    final current = _state.value;
    if (current.phase == PlayerPhase.ended) {
      _position = Duration.zero;
      _emit(current.copyWith(phase: PlayerPhase.ready, playing: true));
      return;
    }
    _emit(current.copyWith(playing: true));
  }

  @override
  void pause() {
    if (_disposed) return;
    _emit(_state.value.copyWith(playing: false));
  }

  @override
  void seekTo(Duration position) {
    if (_disposed) return;
    final phase = _state.value.phase;
    if (phase == PlayerPhase.idle || phase == PlayerPhase.preparing) {
      _pendingSeek = position;
      return;
    }
    _position = _clamp(position);
    if (phase == PlayerPhase.ended && _position < (_state.value.duration!)) {
      _emit(_state.value.copyWith(phase: PlayerPhase.ready));
    }
  }

  @override
  void setSpeed(double speed) {
    if (_disposed) return;
    _emit(_state.value.copyWith(speed: speed));
  }

  @override
  void setLooping({required bool looping}) {
    if (_disposed) return;
    _emit(_state.value.copyWith(looping: looping));
  }

  @override
  void setVolume(double volume) {
    if (_disposed) return;
    _emit(_state.value.copyWith(volume: volume.clamp(0, 1)));
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _state.dispose();
  }

  Duration _clamp(Duration position) {
    if (position.isNegative) return Duration.zero;
    final duration = _state.value.duration ?? _backend.duration;
    return position > duration ? duration : position;
  }

  void _emit(PlayerState next) {
    if (_state.value != next) _state.value = next;
  }
}

/// An [AudioFocus] a test drives: it records requests and emits the changes
/// the test asks for.
final class FakeAudioFocus implements AudioFocus {
  final StreamController<AudioFocusChange> _changes =
      StreamController.broadcast();
  int _requests = 0;
  bool _held = false;

  /// Whether the pool holds the focus now: requested and not abandoned.
  bool get held => _held;

  /// How many times the pool requested focus.
  int get requests => _requests;

  @override
  void request() {
    _requests++;
    _held = true;
  }

  @override
  void abandon() => _held = false;

  @override
  Stream<AudioFocusChange> get changes => _changes.stream;

  /// Reports [change] as the system would.
  void emit(AudioFocusChange change) => _changes.add(change);
}
