// The channel between `NativePlayerBackend` (Dart) and the platform players
// (Kotlin over Media3, Swift over AVPlayer). Regenerate after a change, from
// the package directory:
//
//   dart run pigeon --input pigeons/player_messages.dart
//
// Commands go down as typed calls, state comes up as whole snapshots: a
// snapshot is sent when something changes (a phase, a size, a seek, the first
// frame) and every 100 ms while playing, never per frame. The Dart side
// extrapolates the playhead between snapshots, at the rate it measures from
// them.
//
// Positional booleans: a schema mirrors the native signatures, where Kotlin and
// Swift take them positionally.
// ignore_for_file: avoid_positional_boolean_parameters
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/native/player_messages.g.dart',
    dartPackageName: 'mpx_player',
    kotlinOut: 'android/src/main/kotlin/dev/mpx/player/PlayerMessages.g.kt',
    kotlinOptions: KotlinOptions(package: 'dev.mpx.player'),
    swiftOut: 'darwin/Classes/PlayerMessages.g.swift',
  ),
)
/// Where a native player stands; `idle` never crosses the channel.
enum NativePlayerPhase { preparing, ready, buffering, ended, failed }

/// What a native player reads: a ranged resource published to the bytes
/// cache's native reader under [cacheKey], read through the function table at
/// [readerApi] (the address of `hbc_api`); with [playlistUrl], an HLS
/// stream whose parts the player asks for one by one ([PlayerFlutterApi]
/// `openStreamPart`); or, with [fileUrl], a file on the device the player
/// opens in place.
class NativePlayerSource {
  NativePlayerSource({
    required this.cacheKey,
    required this.readerApi,
    required this.mimeType,
    this.playlistUrl,
    this.streamId,
    this.fileUrl,
  });

  String cacheKey;
  int readerApi;

  /// The container's MIME type (`video/mp4`); Apple's resource loader needs
  /// it, Android sniffs the container itself.
  String mimeType;

  /// The HLS playlist the player opens first; null for a progressive file.
  /// Relative part URLs resolve against it.
  String? playlistUrl;

  /// The stream this player's part requests name; set with [playlistUrl].
  int? streamId;

  /// A file on the device (a `file:` URL, or an Android `content:` URI) the
  /// player reads directly, past the bytes cache; null for the cache's
  /// sources.
  String? fileUrl;
}

/// One part of an HLS stream, as the cache serves it: a playlist's [bytes],
/// or the [cacheKey] of a segment published to the native reader. Close it
/// with `closeStreamPart` when done.
class NativeStreamPart {
  NativeStreamPart({required this.partId, this.cacheKey, this.bytes});

  int partId;
  String? cacheKey;
  Uint8List? bytes;
}

/// The settings a native player starts with.
class NativePlayerSettings {
  NativePlayerSettings({
    required this.startAtUs,
    required this.seekId,
    required this.playing,
    required this.speed,
    required this.looping,
    required this.volume,
    required this.preparedBufferMs,
    required this.preparedBufferBytes,
  });

  int startAtUs;

  /// The seek [startAtUs] stands for: the player's snapshots report it as
  /// applied once the start position is reached.
  int seekId;
  bool playing;
  double speed;
  bool looping;
  double volume;

  /// How far ahead a player that has not played yet buffers: at most this
  /// much media and [preparedBufferBytes] of it, enough for its first frame
  /// and a short start. Lifted at the first play. 0 lifts it from the start.
  int preparedBufferMs;
  int preparedBufferBytes;
}

/// One native player's state at the moment it was sent.
class NativePlayerSnapshot {
  NativePlayerSnapshot({
    required this.playerId,
    required this.phase,
    required this.positionUs,
    required this.sampledAtUs,
    required this.advancing,
    required this.quarterTurns,
    required this.firstFrameRendered,
    required this.buffered,
    required this.seekId,
    this.durationUs,
    this.width,
    this.height,
    this.textureId,
    this.error,
    this.failedCodec,
  });

  int playerId;
  NativePlayerPhase phase;

  /// The playhead when the snapshot was taken.
  int positionUs;

  /// When [positionUs] was read, on the platform's monotonic clock in
  /// microseconds: only differences between snapshots mean anything, which
  /// gives the rate the playhead really moves at, whatever the channel's
  /// latency.
  int sampledAtUs;

  /// Whether the playhead moves now (playing, not buffering, not ended).
  bool advancing;
  int quarterTurns;
  bool firstFrameRendered;

  /// Buffered stretches as flat microsecond pairs: start, end, start, end.
  List<int> buffered;

  /// The id of the last seek [positionUs] already reflects.
  int seekId;
  int? durationUs;
  int? width;
  int? height;
  int? textureId;

  /// Why the player failed; set exactly in `failed`.
  String? error;

  /// The video MIME type whose decoder failed, when that was the cause.
  String? failedCodec;
}

/// How a request takes the platform's sound; see `PlayerAudioFocus`.
enum NativeAudioFocusMode { exclusive, duck, mix }

/// What the platform's audio session says; see `AudioFocusChange`.
enum NativeAudioFocusChange { gained, lost, interrupted, outputRemoved }

/// One video decoder the device has.
class NativeDecoderInfo {
  NativeDecoderInfo({
    required this.mimeType,
    required this.hardware,
    required this.maxInstances,
  });

  String mimeType;
  bool hardware;

  /// How many instances the platform says can run at once; 0 when it does
  /// not say.
  int maxInstances;
}

/// What the device can decode, for the prepared-player budget.
class NativeDeviceProbe {
  NativeDeviceProbe({
    required this.lowRam,
    required this.totalMemoryBytes,
    required this.cpuCount,
    required this.memoryClassMb,
    required this.decoders,
    required this.containers,
    required this.failedCodecs,
    this.performanceClass,
  });

  bool lowRam;
  int totalMemoryBytes;
  int cpuCount;

  /// Android's per-app memory class in MB; 0 elsewhere.
  int memoryClassMb;

  /// Android's media performance class (API 31+); null elsewhere or when the
  /// device declares none.
  int? performanceClass;
  List<NativeDecoderInfo> decoders;

  /// Container MIME types the platform player opens; empty when it opens
  /// every container it can sniff.
  List<String> containers;

  /// Video MIME types whose decoder failed on this device before
  /// (persisted).
  List<String> failedCodecs;
}

@HostApi()
abstract class PlayerHostApi {
  /// Disposes every player a previous Dart isolate left (hot restart).
  void reset();

  /// Creates a player, starts preparing it and returns its id.
  int create(NativePlayerSource source, NativePlayerSettings settings);

  void play(int playerId);
  void pause(int playerId);
  void seekTo(int playerId, int positionUs, int seekId);
  void setSpeed(int playerId, double speed);
  void setLooping(int playerId, bool looping);
  void setVolume(int playerId, double volume);
  void dispose(int playerId);

  void requestAudioFocus(NativeAudioFocusMode mode);
  void abandonAudioFocus();

  NativeDeviceProbe probe();

  bool isPictureInPictureSupported();

  /// Moves [playerId]'s picture into picture in picture (Apple: its hidden
  /// layer; Android: the activity).
  void startPictureInPicture(int playerId);
  void stopPictureInPicture();

  /// Whether the sound owner keeps playing while the app is in the
  /// background.
  void setBackgroundAudio(bool enabled);
}

/// What a platform still extractor reads and draws: the ranged resource
/// [cacheKey] of the native reader at [readerApi], or the file at [path];
/// its first frame drawn within [maxWidth] x [maxHeight], aspect kept,
/// rotation applied.
class NativeStillRequest {
  NativeStillRequest({
    required this.requestId,
    required this.maxWidth,
    required this.maxHeight,
    this.cacheKey,
    this.readerApi,
    this.path,
  });

  /// Names the request for `cancelStill`, unique across the app's decoders.
  int requestId;
  int maxWidth;
  int maxHeight;
  String? cacheKey;
  int? readerApi;
  String? path;
}

/// A still the platform drew: [width] x [height] pixels as premultiplied
/// RGBA, four bytes each, rows packed.
class NativeStill {
  NativeStill({required this.width, required this.height, required this.rgba});

  int width;
  int height;
  Uint8List rgba;
}

/// The platform's still extractor: the first frame of a video whose codec
/// the software decoder cannot read, drawn by the platform's own decoders.
@HostApi()
abstract class PlayerStillHostApi {
  /// Draws the first frame of [request]'s video; null when the platform
  /// cannot either. Reads block on bytes still downloading, off the main
  /// thread.
  @async
  NativeStill? extractStill(NativeStillRequest request);

  /// Wakes the reads of request [requestId], which then ends; its answer
  /// no longer matters.
  void cancelStill(int requestId);
}

@FlutterApi()
abstract class PlayerFlutterApi {
  void onSnapshot(NativePlayerSnapshot snapshot);
  void onAudioFocusChange(NativeAudioFocusChange change);

  /// Picture in picture started ([active]) or ended for [playerId];
  /// [dismissed] when the user closed the window rather than returning to
  /// the app.
  void onPictureInPictureChange(int playerId, bool active, bool dismissed);

  /// Opens the part at [url] of stream [streamId]: a [playlist] (resolved
  /// through the cache, revalidated by HTTP rules) or a segment (published
  /// to the native reader under a key of its own). Fails once the stream is
  /// closed.
  @async
  NativeStreamPart openStreamPart(int streamId, String url, bool playlist);

  /// The player is done with [partId]; a segment's publication is withdrawn.
  void closeStreamPart(int partId);
}
