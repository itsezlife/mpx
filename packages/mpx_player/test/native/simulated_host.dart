// The generated host API's own fields carry the generator's names.
// ignore_for_file: non_constant_identifier_names
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:mpx_player/src/native/player_messages.g.dart';

/// The platform side of the native backend, simulated: each player prepares
/// a 20 s, 640x360 clip a microtask after it is created, unless its cache
/// key is in [unplayable] (fails) or its codec is in [brokenCodecs] (fails
/// with that codec's decoder).
final class SimulatedHost implements PlayerHostApi {
  SimulatedHost({
    this.unplayable = const {},
    this.brokenCodecs = const {},
    this.codecOf = const {},
    this.probeResult,
  });

  final Set<String> unplayable;
  final Set<String> brokenCodecs;

  /// The codec each cache key's bytes are in, as the platform would find.
  final Map<String, String> codecOf;
  final NativeDeviceProbe? probeResult;

  late PlayerFlutterApi receiver;

  static const int durationUs = 20 * 1000 * 1000;

  final Map<int, SimulatedPlayer> players = {};
  final List<String> calls = [];
  final Completer<void> _hold = Completer<void>()..complete();
  Completer<void>? createGate;
  int _nextId = 1;
  bool pictureInPictureSupported = true;
  bool? backgroundAudio;

  /// Players created and not disposed.
  Iterable<SimulatedPlayer> get live =>
      players.values.where((player) => !player.disposed);

  @override
  BinaryMessenger? get pigeonVar_binaryMessenger => null;

  @override
  String get pigeonVar_messageChannelSuffix => '';

  @override
  Future<void> reset() async => calls.add('reset');

  @override
  Future<int> create(
    NativePlayerSource source,
    NativePlayerSettings settings,
  ) async {
    await (createGate?.future ?? _hold.future);
    final id = _nextId++;
    final player = SimulatedPlayer(this, id, source, settings);
    players[id] = player;
    calls.add('create ${source.cacheKey}');
    scheduleMicrotask(player.prepared);
    return id;
  }

  @override
  Future<void> play(int playerId) async => players[playerId]?.play();

  @override
  Future<void> pause(int playerId) async => players[playerId]?.pause();

  @override
  Future<void> seekTo(int playerId, int positionUs, int seekId) async =>
      players[playerId]?.seek(positionUs, seekId);

  @override
  Future<void> setSpeed(int playerId, double speed) async =>
      players[playerId]?.speed = speed;

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      players[playerId]?.looping = looping;

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      players[playerId]?.volume = volume;

  @override
  Future<void> dispose(int playerId) async {
    players[playerId]?.disposed = true;
    calls.add('dispose $playerId');
  }

  @override
  Future<void> requestAudioFocus() async => calls.add('requestAudioFocus');

  @override
  Future<void> abandonAudioFocus() async => calls.add('abandonAudioFocus');

  @override
  Future<NativeDeviceProbe> probe() async =>
      probeResult ??
      NativeDeviceProbe(
        lowRam: false,
        totalMemoryBytes: 8 << 30,
        cpuCount: 8,
        memoryClassMb: 256,
        decoders: [],
        containers: [],
        failedCodecs: [],
      );

  @override
  Future<bool> isPictureInPictureSupported() async => pictureInPictureSupported;

  @override
  Future<void> startPictureInPicture(int playerId) async =>
      receiver.onPictureInPictureChange(playerId, true, false);

  @override
  Future<void> stopPictureInPicture() async {
    for (final player in live) {
      receiver.onPictureInPictureChange(player.id, false, false);
    }
  }

  /// The user closes the window of [playerId].
  void dismissPictureInPicture(int playerId) =>
      receiver.onPictureInPictureChange(playerId, false, true);

  @override
  Future<void> setBackgroundAudio(bool enabled) async =>
      backgroundAudio = enabled;
}

/// One simulated platform player.
final class SimulatedPlayer {
  SimulatedPlayer(this.host, this.id, this.source, NativePlayerSettings start)
    : positionUs = start.startAtUs,
      seekId = start.seekId,
      playing = start.playing,
      speed = start.speed,
      looping = start.looping,
      volume = start.volume;

  final SimulatedHost host;
  final int id;
  final NativePlayerSource source;
  int positionUs;
  int seekId;
  bool playing;
  double speed;
  bool looping;
  double volume;
  bool disposed = false;
  NativePlayerPhase phase = NativePlayerPhase.preparing;

  void prepared() {
    if (disposed) return;
    final codec = host.codecOf[source.cacheKey];
    if (host.unplayable.contains(source.cacheKey)) {
      phase = NativePlayerPhase.failed;
      return report(error: 'cannot open');
    }
    if (codec != null && host.brokenCodecs.contains(codec)) {
      phase = NativePlayerPhase.failed;
      return report(error: 'decoder failed', failedCodec: codec);
    }
    positionUs = positionUs.clamp(0, SimulatedHost.durationUs);
    phase = NativePlayerPhase.ready;
    report();
  }

  void play() {
    playing = true;
    if (phase == NativePlayerPhase.ended) {
      positionUs = 0;
      phase = NativePlayerPhase.ready;
    }
    report();
  }

  void pause() {
    playing = false;
    report();
  }

  void seek(int us, int id) {
    positionUs = us.clamp(0, SimulatedHost.durationUs);
    seekId = id;
    if (phase == NativePlayerPhase.preparing) return;
    report();
  }

  void report({String? error, String? failedCodec}) {
    if (disposed) return;
    final failed = phase == NativePlayerPhase.failed;
    host.receiver.onSnapshot(
      NativePlayerSnapshot(
        playerId: id,
        phase: phase,
        positionUs: positionUs,
        advancing: playing && phase == NativePlayerPhase.ready,
        quarterTurns: 0,
        firstFrameRendered: !failed,
        buffered: failed ? [] : [0, SimulatedHost.durationUs],
        seekId: seekId,
        durationUs: failed ? null : SimulatedHost.durationUs,
        width: failed ? null : 640,
        height: failed ? null : 360,
        textureId: failed ? null : 100 + id,
        error: error,
        failedCodec: failedCodec,
      ),
    );
  }
}
