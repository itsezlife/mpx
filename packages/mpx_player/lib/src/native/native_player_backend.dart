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

/// Resolves one HLS playlist's bytes through the bytes cache.
typedef PlayerPlaylistLoader = Future<Uint8List> Function(BytesRequest request);

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
/// The platform reports each player's state when it changes and every 100 ms
/// while it plays, with the time it read the position; [PlayerEngine.position]
/// extrapolates between reports, so reading it per frame costs no platform
/// call. It moves at the rate measured from the reports, not at the speed
/// asked for: a player takes a new speed when it can, a while late with
/// time-stretched audio, and the playhead follows what it really does. While
/// it plays it moves only forward: a report that disagrees (placed by the
/// time it was read) is made up at up to a quarter above or below the
/// measured rate, and only a seek, a pause, a start, a loop's wrap or a
/// disagreement over half a second moves it at once.
///
/// An HLS source ([PlayerSourceKind.hls], Android only) publishes nothing up
/// front: the platform player asks for each part as it needs it. A
/// playlist is resolved through [playlists] (the whole-resource ladder,
/// revalidated by HTTP rules, served stale when the network fails) and its
/// bytes handed over; a segment is published to the native reader under its
/// own key ([BytesCacheKey.within] the stream's key) and withdrawn when the
/// player closes it. Disposing the engine withdraws what is still open.
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
  ///
  /// [playlists] resolves HLS playlists; it should read the store [readers]
  /// serves. Defaults to [BytesResolver.shared].
  NativePlayerBackend({
    required NativeRangedReaders readers,
    required PlayerSourcesOf sourcesOf,
    IBytesResolver? playlists,
    bool backgroundAudio = false,
  }) : this.over(
         host: PlayerHostApi(),
         publish: (request) async {
           final publication = await readers.publish(request);
           return publication.close;
         },
         readerApi: NativeRangedReaders.apiAddress,
         sourcesOf: sourcesOf,
         loadPlaylist: (playlists ?? BytesResolver.shared()).resolve,
         backgroundAudio: backgroundAudio,
       );

  /// Creates the backend over [host], a stand-in for the platform side in
  /// tests; [publish] and [readerApi] stand in for the native reader,
  /// [loadPlaylist] for the cache's resolver.
  @visibleForTesting
  NativePlayerBackend.over({
    required PlayerHostApi host,
    required PlayerBytesPublisher publish,
    required int readerApi,
    required PlayerSourcesOf sourcesOf,
    PlayerPlaylistLoader? loadPlaylist,
    bool backgroundAudio = false,
    bool receive = true,
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start()),
       _host = host,
       _publish = publish,
       _readerApi = readerApi,
       _sourcesOf = sourcesOf,
       _loadPlaylist = loadPlaylist ?? BytesResolver.shared().resolve,
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

  // The wall clock the playheads move by between reports; a test's own.
  final Stopwatch _clock;
  final PlayerHostApi _host;
  final PlayerBytesPublisher _publish;
  final int _readerApi;
  final PlayerSourcesOf _sourcesOf;
  final PlayerPlaylistLoader _loadPlaylist;
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
  final Map<int, _Stream> _streams = {};
  // The stream of each open segment, by part id.
  final Map<int, _Stream> _partStreams = {};
  int _nextStreamId = 1;
  int _nextPartId = 1;
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

  _Stream _openStream(RangedRequest request) {
    final stream = _Stream(this, _nextStreamId++, request);
    _streams[stream.id] = stream;
    return stream;
  }

  Future<NativeStreamPart> _openPart(
    int streamId,
    String url,
    bool playlist,
  ) async {
    final stream = _streams[streamId];
    if (stream == null) {
      throw StateError('Stream $streamId is closed');
    }
    return playlist ? stream.openPlaylist(url) : stream.openSegment(url);
  }

  void _closePart(int partId) {
    final stream = _partStreams.remove(partId);
    if (stream != null) unawaited(_send(stream.closePart(partId)));
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
  Future<NativeStreamPart> openStreamPart(
    int streamId,
    String url,
    bool playlist,
  ) => _backend._openPart(streamId, url, playlist);

  @override
  void closeStreamPart(int partId) => _backend._closePart(partId);

  @override
  void onPictureInPictureChange(int playerId, bool active, bool dismissed) {
    if (_backend._disposed) return;
    final pip = _backend._pictureInPicture;
    final engine = _backend._engines[playerId];
    if (active) {
      pip._active.value = engine;
      return;
    }
    if (identical(pip._active.value, engine) || engine == null) {
      pip._active.value = null;
    }
    // Closing the window stops the video, as background sound would
    // otherwise play on with nothing to show it.
    if (dismissed) engine?.pause();
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
  _Stream? _stream;
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

  // The playhead: a position at a clock time and whether it moves from there;
  // a seek not reported yet wins over both. It moves at [_rate] (media time
  // per clock time) for [_slew] after the anchor, then at [_velocity]: a
  // report that disagrees with the playhead shown is reached over a few
  // frames, never by a step (see _apply).
  Duration _anchor = Duration.zero;
  Duration _anchoredAt = Duration.zero;
  double _rate = 1;
  Duration _slew = Duration.zero;
  bool _advancing = false;
  // The rate the platform's playhead was measured to move at, from the
  // positions and sampling times of the last two reports while it plays;
  // null until two reports after a start, a pause, a seek or a speed change
  // show it moving. Until then the speed asked for stands in: a player takes
  // a new speed at once where it can, and a measure from before the change
  // would run the playhead at the old one. One that takes it late is
  // followed from its second report on.
  double? _measured;
  // The last report's position and its sampling time, while it moves.
  ({Duration position, int at})? _sample;

  /// The fastest rate a measurement is believed up to.
  static const double _fastestRate = 8;

  // The rate the playhead moves at between reports: the measured one, or
  // the speed asked for until there is one.
  double get _velocity => _measured ?? _speed;
  Duration? _seekTarget;
  Duration? _held;
  int _seekId = 0;

  @override
  ValueListenable<PlayerState> get state => _state;

  Duration? get _duration => switch (_last?.durationUs) {
    final us? => Duration(microseconds: us),
    null => null,
  };

  // The platform reports the end a little off the duration (the last
  // sample's time, or past it): an ended pass and anything past the end
  // read as the duration.
  @override
  Duration get position {
    final target = _seekTarget;
    if (target != null) return target;
    final duration = _duration;
    if (_phase == PlayerPhase.ended && duration != null) return duration;
    if (!_advancing) {
      return duration != null && _anchor > duration ? duration : _anchor;
    }
    final moved = _movedBy(_backend._clock.elapsed);
    if (duration == null || duration <= Duration.zero || moved <= duration) {
      return moved;
    }
    return _looping
        ? Duration(microseconds: moved.inMicroseconds % duration.inMicroseconds)
        : duration;
  }

  // The unclamped playhead at clock time [now] while it advances.
  Duration _movedBy(Duration now) {
    final since = now - _anchoredAt;
    if (since <= _slew) return _anchor + since * _rate;
    return _anchor + _slew * _rate + (since - _slew) * _velocity;
  }

  // Moves the playhead to [position] at once, at the speed from now.
  void _anchorAt(Duration position) {
    _anchor = position;
    _anchoredAt = _backend._clock.elapsed;
    _rate = _velocity;
    _slew = Duration.zero;
  }

  /// A disagreement past which a report is taken at once, a jump: a seek
  /// the platform made by itself, a stall, a clock gone wrong.
  static const Duration _jumpOver = Duration(milliseconds: 500);

  /// How far from the measured rate the playhead moves while it makes up a
  /// disagreement: a quarter, so a tenth of a second is absorbed over about
  /// four tenths at 1x, never as a burst or a stall.
  static const double _slewShare = 0.25;

  // Takes a report of [reported] (on the course now) while the playhead
  // advances and went on advancing: the playhead keeps its place and moves
  // up to a quarter faster or slower than the measured rate until it is on
  // the reported course, so a platform a little behind or ahead never shows
  // as a step, a burst or a stall. A wrap, or a disagreement over
  // [_jumpOver], is taken at once.
  void _slewTo(Duration reported, Duration shown) {
    final now = _backend._clock.elapsed;
    final speed = _velocity;
    final duration = _duration;
    final apart = reported - shown;
    final wrapped =
        _looping &&
        duration != null &&
        apart.isNegative &&
        -apart > duration ~/ 2;
    if (wrapped || speed <= 0 || apart.abs() > _jumpOver) {
      return _anchorAt(reported);
    }
    // The course is met when the deviation has made up the distance.
    final deviation = speed * _slewShare;
    _anchor = shown;
    _anchoredAt = now;
    _rate = apart.isNegative ? speed - deviation : speed + deviation;
    _slew = Duration(
      microseconds: (apart.inMicroseconds.abs() / deviation).round(),
    );
  }

  // The least difference seen between this clock and the platform's, in
  // microseconds: the platform's sampling time plus it is when a report
  // read with no delay would have arrived.
  int? _clockOffset;

  // Where [position], read at [at] on the platform's clock, is by [now]:
  // moved on at the measured rate for the time the report spent on its way
  // beyond the quickest one seen. Without it each report's own delay read as
  // the playhead running ahead of the player, a disagreement made up by
  // every report in turn.
  Duration _reportedNow(Duration position, int at, Duration now) {
    final seen = now.inMicroseconds - at;
    final offset = _clockOffset = switch (_clockOffset) {
      final least? when least <= seen => least,
      _ => seen,
    };
    final late = seen - offset;
    if (late <= 0) return position;
    return position + Duration(microseconds: (late * _velocity).round());
  }

  // Takes the rate between the last report and this one, [position] read at
  // [at] on the platform's clock. A wrap (it went back) measures nothing.
  void _measure(Duration position, int at) {
    final last = _sample;
    if (last == null) return;
    final elapsed = at - last.at;
    final moved = position - last.position;
    if (elapsed <= 0 || moved.isNegative) return;
    // The latest measure as it is: positions read with their own times
    // jitter little, and a smoothed one lagged a speed change by reports.
    _measured = (moved.inMicroseconds / elapsed).clamp(0.0, _fastestRate);
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
        final failed = backend._failedCodecs;
        return _fail(
          'No source of $key plays on this device'
          '${failed.isEmpty ? '' : ' (decoders that failed: ${failed.join(', ')})'}',
        );
      }
      _codec = source.codec;
      final hls = source.kind == PlayerSourceKind.hls;
      if (hls) {
        _stream = backend._openStream(source.request);
      } else {
        final unpublish = await backend._publish(source.request);
        if (_disposed) return unawaited(unpublish());
        _unpublish = unpublish;
      }
      final stream = _stream;
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
          playlistUrl: hls ? source.request.url.toString() : null,
          streamId: stream?.id,
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
      if (!_disposed)
        _fail('Opening $key on the platform player failed: $error');
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
    if (snapshot.seekId >= _seekId) {
      // A held playhead stays where it was sent until it moves: the
      // platform lands on the nearest sample, a millisecond short at the end.
      _held = _seekTarget ?? _held;
      _seekTarget = null;
    }
    final sought = _held != null;
    if (snapshot.advancing) _held = null;
    final reported = _held ?? Duration(microseconds: snapshot.positionUs);
    final phase = switch (snapshot.phase) {
      NativePlayerPhase.preparing => PlayerPhase.preparing,
      NativePlayerPhase.ready => PlayerPhase.ready,
      NativePlayerPhase.buffering => PlayerPhase.buffering,
      NativePlayerPhase.ended => PlayerPhase.ended,
      NativePlayerPhase.failed => PlayerPhase.failed,
    };
    // A periodic report while it went on playing is measured and slewed to;
    // a seek, a pause, a start and a change of phase are taken as they are,
    // and the rate is measured again from the next two reports.
    final continuous =
        _advancing &&
        snapshot.advancing &&
        !sought &&
        phase == _phase &&
        _seekTarget == null;
    if (continuous) {
      // Where the playhead shows now, before the rate it moved at changes.
      final now = _backend._clock.elapsed;
      final shown = _movedBy(now);
      _measure(reported, snapshot.sampledAtUs);
      _slewTo(_reportedNow(reported, snapshot.sampledAtUs, now), shown);
    } else {
      _measured = null;
      _anchorAt(reported);
    }
    _sample = snapshot.advancing
        ? (position: reported, at: snapshot.sampledAtUs)
        : null;
    _advancing = snapshot.advancing;
    _phase = phase;
    if (_phase == PlayerPhase.failed) {
      _error =
          'The platform player failed playing $key: '
          '${snapshot.error ?? 'it gave no reason'}';
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
    final stream = _stream;
    _id = null;
    _unpublish = null;
    _stream = null;
    if (id != null) _backend._unregister(id);
    unawaited(() async {
      if (id != null) await _backend._send(_backend._host.dispose(id));
      if (unpublish != null) await _backend._send(unpublish());
      if (stream != null) await _backend._send(stream.close());
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
    _anchorAt(position);
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
    // The new speed stands in until two reports measure the rate again.
    _measured = null;
    _sample = null;
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
  }
}

// --- HLS streams ------------------------------------------------------------

/// One engine's HLS stream: the parts its platform player opened, keyed by
/// URL under the stream's key.
final class _Stream {
  _Stream(this._backend, this.id, this._request);

  final NativePlayerBackend _backend;
  final int id;
  final RangedRequest _request;
  final CancelToken _cancel = CancelToken();
  final Map<int, Future<void> Function()> _segments = {};
  bool _closed = false;

  BytesCacheKey _keyOf(String url) =>
      BytesCacheKey.within(_request.cacheKey, url);

  Future<NativeStreamPart> openPlaylist(String url) async {
    final bytes = await _backend._loadPlaylist(
      BytesRequest(
        url: url,
        headers: _request.headers,
        cacheKey: _keyOf(url),
        quota: _request.quota,
        cancelToken: _cancel,
      ),
    );
    _ensureOpen();
    // A playlist holds nothing open: its id only answers the close.
    return NativeStreamPart(partId: _backend._nextPartId++, bytes: bytes);
  }

  Future<NativeStreamPart> openSegment(String url) async {
    final key = _keyOf(url);
    final unpublish = await _backend._publish(
      RangedRequest(
        url: Uri.parse(url),
        cacheKey: key,
        headers: _request.headers,
        quota: _request.quota,
      ),
    );
    if (_closed) {
      await unpublish();
      _ensureOpen();
    }
    final partId = _backend._nextPartId++;
    _segments[partId] = unpublish;
    _backend._partStreams[partId] = this;
    return NativeStreamPart(partId: partId, cacheKey: key.value);
  }

  Future<void> closePart(int partId) async {
    await _segments.remove(partId)?.call();
  }

  /// Withdraws every segment still open and refuses new parts.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _cancel.cancel();
    _backend._streams.remove(id);
    final open = _segments.entries.toList();
    _segments.clear();
    for (final MapEntry(key: partId, value: unpublish) in open) {
      _backend._partStreams.remove(partId);
      await unpublish();
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Stream $id is closed');
  }
}
