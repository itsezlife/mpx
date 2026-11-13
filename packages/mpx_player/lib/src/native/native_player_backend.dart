import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/native_reader.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/audio/audio_focus.dart';
import 'package:mpx_player/src/backend/picture_in_picture.dart';
import 'package:mpx_player/src/backend/player_backend.dart';
import 'package:mpx_player/src/budget/player_device.dart';
import 'package:mpx_player/src/native/player_messages.g.dart';
import 'package:mpx_player/src/native/player_source.dart';
import 'package:mpx_player/src/player/player_state.dart';

/// Publishes one ranged resource to the native reader and returns what
/// withdraws it.
typedef PlayerBytesPublisher =
    Future<Future<void> Function()> Function(RangedRequest request);

/// The platform's hardware player: Media3 ExoPlayer on Android, AVPlayer on
/// iOS and macOS, each drawing into a texture of its own and reading the
/// media's bytes natively through the bytes cache's reader of ranged
/// resources.
///
/// [sourcesOf] says where a key's bytes are ([PlayerSource]s, best first).
/// Preparing an engine publishes the chosen source to [NativeRangedReaders]
/// and hands the platform player its cache key: the player reads the cached
/// sparse file directly and blocks only on missing bytes, which the cache
/// fetches at the reader's priority. Disposing the engine withdraws the
/// publication.
///
/// The platform reports each player's state when it changes and about once a
/// second while it plays; [PlayerEngine.position] extrapolates between
/// reports, so reading it per frame costs no platform call.
///
/// Also brings the platform's audio session ([audioFocus]: Android audio
/// focus and the noisy-output broadcast, Apple's audio session; macOS has
/// none), its picture in picture ([pictureInPicture]) and the hardware
/// probe ([device]). Without [backgroundAudio] every player pauses when the
/// app goes to the background, unless it is in picture in picture.
///
/// One per process: it receives the platform's reports on fixed channels.
final class NativePlayerBackend implements PlayerBackend {
  /// Creates the backend over [readers], the process's native reader.
  NativePlayerBackend({
    required NativeRangedReaders readers,
    required PlayerSourcesOf sourcesOf,
    bool backgroundAudio = false,
  }) : this.over(
         host: PlayerHostApi(),
         publish: (request) async {
           final publication = await readers.publish(request);
           return publication.close;
         },
         readerApi: NativeRangedReaders.apiAddress,
         sourcesOf: sourcesOf,
         backgroundAudio: backgroundAudio,
       );

  /// Creates the backend over [host], a stand-in for the platform side in
  /// tests; [publish] and [readerApi] stand in for the native reader.
  @visibleForTesting
  NativePlayerBackend.over({
    required PlayerHostApi host,
    required PlayerBytesPublisher publish,
    required int readerApi,
    required PlayerSourcesOf sourcesOf,
    bool backgroundAudio = false,
    bool receive = true,
  }) : _host = host,
       _publish = publish,
       _readerApi = readerApi,
       _sourcesOf = sourcesOf,
       _backgroundAudio = backgroundAudio {
    _receiver = _Receiver(this);
    if (receive) PlayerFlutterApi.setUp(_receiver);
    _audioFocus = _NativeAudioFocus(this);
    _pictureInPicture = _NativePictureInPicture(this);
    // A hot restart leaves the previous isolate's players running natively;
    // they go before anything new is created.
    _ready = _send(host.reset()).then((_) async {
      await _send(host.setBackgroundAudio(backgroundAudio));
      _pictureInPicture._supported =
          await _call(host.isPictureInPictureSupported) ?? false;
    });
    _device = _ready.then((_) => _probe());
    _lifecycle = AppLifecycleListener(onHide: _onHide);
  }

  final PlayerHostApi _host;
  final PlayerBytesPublisher _publish;
  final int _readerApi;
  final PlayerSourcesOf _sourcesOf;
  final bool _backgroundAudio;

  late final _Receiver _receiver;
  late final _NativeAudioFocus _audioFocus;
  late final _NativePictureInPicture _pictureInPicture;
  late final Future<void> _ready;
  late final Future<PlayerDevice> _device;
  late final AppLifecycleListener _lifecycle;

  final Map<int, _NativePlayerEngine> _engines = {};
  // Reports for a player whose create call has not answered yet.
  final Map<int, NativePlayerSnapshot> _early = {};
  final Set<String> _failedCodecs = {};
  bool _disposed = false;

  /// The platform side's receiver of reports, for a test that drives the
  /// backend without a platform.
  @visibleForTesting
  PlayerFlutterApi get receiver => _receiver;

  /// What this device decodes, probed once: the input to `PlayerPool.budget`
  /// (`PlayerDevice.budget`) and to the choice of a quality.
  Future<PlayerDevice> get device => _device;

  @override
  AudioFocus get audioFocus => _audioFocus;

  @override
  PictureInPicture get pictureInPicture => _pictureInPicture;

  @override
  PlayerEngine create(MediaKey key) => _NativePlayerEngine(this, key);

  /// Disposes every engine and stops receiving reports. Idempotent.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle.dispose();
    for (final engine in _engines.values.toList()) {
      engine.dispose();
    }
    _audioFocus.close();
    PlayerFlutterApi.setUp(null);
  }

  Future<PlayerDevice> _probe() async {
    final probe = await _call(_host.probe);
    if (probe == null) return const PlayerDevice();
    _failedCodecs.addAll(probe.failedCodecs);
    return PlayerDevice(
      decoders: [
        for (final decoder in probe.decoders)
          PlayerDecoder(
            mimeType: decoder.mimeType,
            hardware: decoder.hardware,
            maxInstances: decoder.maxInstances,
          ),
      ],
      lowRam: probe.lowRam,
      totalMemoryBytes: probe.totalMemoryBytes,
      cpuCount: probe.cpuCount,
      memoryClassMb: probe.memoryClassMb,
      performanceClass: probe.performanceClass,
      failedCodecs: probe.failedCodecs.toSet(),
      instanceCountsKnown: probe.decoders.any((d) => d.maxInstances > 0),
      containers: probe.containers.toSet(),
    );
  }

  // The first source the device can play; a source whose codec failed here
  // or whose container the platform does not open is skipped. With no probe
  // facts about a codec, the source is tried.
  PlayerSource? _choose(List<PlayerSource> sources, PlayerDevice device) {
    for (final source in sources) {
      if (!device.opensContainer(source.mimeType)) continue;
      final codec = source.codec;
      if (codec != null && _failedCodecs.contains(codec)) continue;
      final known = codec != null && device.decoders.isNotEmpty;
      if (known && !device.canDecode(codec)) continue;
      return source;
    }
    for (final source in sources) {
      if (!device.opensContainer(source.mimeType)) continue;
      final codec = source.codec;
      if (codec == null || !_failedCodecs.contains(codec)) return source;
    }
    return null;
  }

  void _onSnapshot(NativePlayerSnapshot snapshot) {
    final engine = _engines[snapshot.playerId];
    if (engine == null) {
      _early[snapshot.playerId] = snapshot;
      return;
    }
    engine._apply(snapshot);
  }

  void _register(int id, _NativePlayerEngine engine) {
    _engines[id] = engine;
    final early = _early.remove(id);
    if (early != null) engine._apply(early);
  }

  void _unregister(int id) {
    _engines.remove(id);
    _early.remove(id);
  }

  // Pauses every player when the app leaves the screen, unless the host
  // keeps sound in the background or a player went into picture in
  // picture (which hides the app on the way).
  void _onHide() {
    if (_backgroundAudio || _pictureInPicture.active.value != null) return;
    for (final engine in _engines.values.toList()) {
      if (engine._playing) engine.pause();
    }
  }

  /// Sends a fire-and-forget command; a platform error is reported, never
  /// dropped.
  Future<void> _send(Future<void> command) => command.catchError(_report);

  Future<T?> _call<T>(Future<T> Function() query) async {
    try {
      return await query();
    } on Object catch (error, stackTrace) {
      _report(error, stackTrace);
      return null;
    }
  }

  static void _report(Object error, StackTrace stackTrace) =>
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'mpx_player',
          context: ErrorDescription('while talking to the platform player'),
        ),
      );
}

final class _Receiver implements PlayerFlutterApi {
  _Receiver(this._backend);

  final NativePlayerBackend _backend;

  @override
  void onSnapshot(NativePlayerSnapshot snapshot) {
    if (!_backend._disposed) _backend._onSnapshot(snapshot);
  }

  @override
  void onAudioFocusChange(NativeAudioFocusChange change) {
    if (_backend._disposed) return;
    _backend._audioFocus._changes.add(switch (change) {
      NativeAudioFocusChange.gained => AudioFocusChange.gained,
      NativeAudioFocusChange.lost => AudioFocusChange.lost,
      NativeAudioFocusChange.interrupted => AudioFocusChange.interrupted,
      NativeAudioFocusChange.outputRemoved => AudioFocusChange.outputRemoved,
    });
  }

  @override
  void onPictureInPictureChange(int playerId, bool active) {
    if (_backend._disposed) return;
    final pip = _backend._pictureInPicture;
    final engine = _backend._engines[playerId];
    if (active) {
      pip._active.value = engine;
    } else if (identical(pip._active.value, engine) || engine == null) {
      pip._active.value = null;
    }
  }
}

final class _NativeAudioFocus implements AudioFocus {
  _NativeAudioFocus(this._backend);

  final NativePlayerBackend _backend;
  final StreamController<AudioFocusChange> _changes =
      StreamController.broadcast();

  @override
  Stream<AudioFocusChange> get changes => _changes.stream;

  void close() => unawaited(_changes.close());

  @override
  void request() {
    if (!_backend._disposed) {
      unawaited(_backend._send(_backend._host.requestAudioFocus()));
    }
  }

  @override
  void abandon() {
    if (!_backend._disposed) {
      unawaited(_backend._send(_backend._host.abandonAudioFocus()));
    }
  }
}

final class _NativePictureInPicture implements PictureInPicture {
  _NativePictureInPicture(this._backend);

  final NativePlayerBackend _backend;
  final ValueNotifier<PlayerEngine?> _active = ValueNotifier(null);
  bool _supported = false;

  @override
  bool get isSupported => _supported;

  @override
  ValueListenable<PlayerEngine?> get active => _active;

  @override
  void start(PlayerEngine engine) {
    if (!_supported || _backend._disposed) return;
    // Only this backend's engines reach here: the pool hands back what
    // `create` made.
    final id = (engine as _NativePlayerEngine)._id;
    if (id == null) return;
    unawaited(_backend._send(_backend._host.startPictureInPicture(id)));
  }

  @override
  void stop() {
    if (_active.value == null || _backend._disposed) return;
    unawaited(_backend._send(_backend._host.stopPictureInPicture()));
  }
}

// --- Engine -----------------------------------------------------------------

final class _NativePlayerEngine implements PlayerEngine {
  _NativePlayerEngine(this._backend, this.key);

  final NativePlayerBackend _backend;
  final MediaKey key;
  final ValueNotifier<PlayerState> _state = ValueNotifier(const PlayerState());

  // The platform player, once its create call answered.
  int? _id;
  Future<void> Function()? _unpublish;
  String? _codec;
  bool _disposed = false;

  // The host's wishes, which the platform player follows.
  bool _playing = false;
  double _speed = 1;
  bool _looping = false;
  double _volume = 1;

  // What the platform last reported.
  PlayerPhase _phase = PlayerPhase.idle;
  NativePlayerSnapshot? _last;
  Object? _error;

  // The playhead: the last reported position, the time since that report
  // and whether it moves; a seek not reported yet wins over both.
  Duration _anchor = Duration.zero;
  final Stopwatch _since = Stopwatch();
  bool _advancing = false;
  Duration? _seekTarget;
  int _seekId = 0;

  @override
  ValueListenable<PlayerState> get state => _state;

  Duration? get _duration => switch (_last?.durationUs) {
    final us? => Duration(microseconds: us),
    null => null,
  };

  @override
  Duration get position {
    final target = _seekTarget;
    if (target != null) return target;
    if (!_advancing) return _anchor;
    final moved = _anchor + _since.elapsed * _speed;
    final duration = _duration;
    if (duration == null || duration <= Duration.zero || moved <= duration) {
      return moved;
    }
    return _looping
        ? Duration(microseconds: moved.inMicroseconds % duration.inMicroseconds)
        : duration;
  }

  @override
  void prepare({Duration startAt = Duration.zero}) {
    if (_disposed || _phase != PlayerPhase.idle) return;
    _phase = PlayerPhase.preparing;
    _seekTarget ??= startAt.isNegative ? Duration.zero : startAt;
    _emit();
    unawaited(_open());
  }

  Future<void> _open() async {
    final backend = _backend;
    try {
      final device = await backend._device;
      final source = backend._choose(backend._sourcesOf(key), device);
      if (_disposed) return;
      if (source == null) {
        return _fail(StateError('$key has no source this device plays'));
      }
      _codec = source.codec;
      final unpublish = await backend._publish(source.request);
      if (_disposed) return unawaited(unpublish());
      _unpublish = unpublish;
      final sent = NativePlayerSettings(
        startAtUs: (_seekTarget ?? _anchor).inMicroseconds,
        seekId: _seekId,
        playing: _playing,
        speed: _speed,
        looping: _looping,
        volume: _volume,
      );
      final id = await backend._host.create(
        NativePlayerSource(
          cacheKey: source.request.cacheKey.value,
          readerApi: backend._readerApi,
          mimeType: source.mimeType,
        ),
        sent,
      );
      // Disposed while the call was out: the publication went with the
      // engine; the platform player is all that is left.
      if (_disposed) return backend._send(backend._host.dispose(id));
      _id = id;
      _catchUp(id, sent);
      backend._register(id, this);
    } on Object catch (error) {
      if (!_disposed) _fail(error);
    }
  }

  // Sends the wishes that changed while the create call was out.
  void _catchUp(int id, NativePlayerSettings sent) {
    final host = _backend._host;
    final send = _backend._send;
    if (_seekId != sent.seekId) {
      unawaited(send(host.seekTo(id, _seekTarget!.inMicroseconds, _seekId)));
    }
    if (_speed != sent.speed) unawaited(send(host.setSpeed(id, _speed)));
    if (_looping != sent.looping) {
      unawaited(send(host.setLooping(id, _looping)));
    }
    if (_volume != sent.volume) unawaited(send(host.setVolume(id, _volume)));
    if (_playing != sent.playing) {
      unawaited(send(_playing ? host.play(id) : host.pause(id)));
    }
  }

  void _apply(NativePlayerSnapshot snapshot) {
    if (_disposed) return;
    final failedCodec = snapshot.failedCodec;
    if (snapshot.phase == NativePlayerPhase.failed && failedCodec != null) {
      _backend._failedCodecs.add(failedCodec);
      if (failedCodec == _codec) return _retryAfterDecoderFailure();
    }
    _last = snapshot;
    if (snapshot.seekId >= _seekId) _seekTarget = null;
    _anchor = Duration(microseconds: snapshot.positionUs);
    _since
      ..reset()
      ..start();
    _advancing = snapshot.advancing;
    _phase = switch (snapshot.phase) {
      NativePlayerPhase.preparing => PlayerPhase.preparing,
      NativePlayerPhase.ready => PlayerPhase.ready,
      NativePlayerPhase.buffering => PlayerPhase.buffering,
      NativePlayerPhase.ended => PlayerPhase.ended,
      NativePlayerPhase.failed => PlayerPhase.failed,
    };
    if (_phase == PlayerPhase.failed) {
      _error = snapshot.error ?? 'The platform player failed';
      _closeNative();
    }
    _emit();
  }

  // The decoder of the chosen source's codec failed: that codec is not
  // tried again on this device, and the next source prepares from where
  // this one was.
  void _retryAfterDecoderFailure() {
    _seekTarget ??= position;
    _closeNative();
    _phase = PlayerPhase.preparing;
    _last = null;
    _emit();
    unawaited(_open());
  }

  void _fail(Object error) {
    _phase = PlayerPhase.failed;
    _error = error;
    _closeNative();
    _emit();
  }

  // Lets go of the platform player and the publication, keeping this
  // engine's state.
  void _closeNative() {
    final id = _id;
    final unpublish = _unpublish;
    _id = null;
    _unpublish = null;
    if (id != null) _backend._unregister(id);
    unawaited(() async {
      if (id != null) await _backend._send(_backend._host.dispose(id));
      if (unpublish != null) await _backend._send(unpublish());
    }());
  }

  void _emit() {
    if (_disposed) return;
    final last = _last;
    final holds =
        _phase == PlayerPhase.ready ||
        _phase == PlayerPhase.buffering ||
        _phase == PlayerPhase.ended;
    final failed = _phase == PlayerPhase.failed;
    final width = last?.width;
    final height = last?.height;
    final next = PlayerState(
      phase: _phase,
      playing: _playing,
      duration: _duration,
      buffered: [
        if (last != null && !failed)
          for (var i = 0; i + 1 < last.buffered.length; i += 2)
            PlayerTimeRange(
              Duration(microseconds: last.buffered[i]),
              Duration(
                microseconds: last.buffered[i + 1] < last.buffered[i]
                    ? last.buffered[i]
                    : last.buffered[i + 1],
              ),
            ),
      ],
      videoSize: width != null && height != null && !failed
          ? Size(width.toDouble(), height.toDouble())
          : null,
      quarterTurns: last?.quarterTurns ?? 0,
      textureId: holds ? last?.textureId : null,
      firstFrameRendered: holds && (last?.firstFrameRendered ?? false),
      speed: _speed,
      looping: _looping,
      volume: _volume,
      error: failed ? _error : null,
    );
    if (_state.value != next) _state.value = next;
  }

  // Re-anchors the extrapolated playhead at its value now, before a change
  // to how it moves.
  void _reanchor() {
    if (_seekTarget != null) return;
    _anchor = position;
    _since
      ..reset()
      ..start();
  }

  @override
  void play() {
    if (_disposed) return;
    _playing = true;
    _emit();
    final id = _id;
    if (id != null) unawaited(_backend._send(_backend._host.play(id)));
  }

  @override
  void pause() {
    if (_disposed) return;
    _reanchor();
    _advancing = false;
    _playing = false;
    _emit();
    final id = _id;
    if (id != null) unawaited(_backend._send(_backend._host.pause(id)));
  }

  @override
  void seekTo(Duration position) {
    if (_disposed) return;
    var target = position.isNegative ? Duration.zero : position;
    final duration = _duration;
    if (duration != null && target > duration) target = duration;
    _seekTarget = target;
    _seekId++;
    final id = _id;
    if (id != null) {
      unawaited(
        _backend._send(
          _backend._host.seekTo(id, target.inMicroseconds, _seekId),
        ),
      );
    }
  }

  @override
  void setSpeed(double speed) {
    if (_disposed) return;
    _reanchor();
    _speed = speed;
    _emit();
    final id = _id;
    if (id != null) {
      unawaited(_backend._send(_backend._host.setSpeed(id, speed)));
    }
  }

  @override
  void setLooping({required bool looping}) {
    if (_disposed) return;
    _looping = looping;
    _emit();
    final id = _id;
    if (id != null) {
      unawaited(_backend._send(_backend._host.setLooping(id, looping)));
    }
  }

  @override
  void setVolume(double volume) {
    if (_disposed) return;
    _volume = volume.clamp(0, 1).toDouble();
    _emit();
    final id = _id;
    if (id != null) {
      unawaited(_backend._send(_backend._host.setVolume(id, _volume)));
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _closeNative();
    _disposed = true;
    _since.stop();
  }
}
