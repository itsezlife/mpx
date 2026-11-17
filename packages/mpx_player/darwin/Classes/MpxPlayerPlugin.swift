import AVFoundation
import Foundation
import VideoToolbox

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// The Apple side of `mpx_player`: AVPlayers drawing into Flutter textures,
/// driven by `NativePlayerBackend` over the Pigeon channel.
public class MpxPlayerPlugin: NSObject, FlutterPlugin, PlayerHostApi {
  private let registry: FlutterTextureRegistry
  private let flutter: PlayerFlutterApi
  private var players: [Int64: MpxPlayer] = [:]
  private var nextId: Int64 = 1
  private var audioSession: MpxAudioSession!
  private var pictureInPicture: MpxPictureInPicture!
  // Whether the host keeps sound in the background. Nothing native follows
  // from it: frames go to a video output, not a layer, so AVFoundation does
  // not pause a backgrounded player for showing video; the host declares
  // the audio background mode, and the Dart side pauses on hide without it.
  private var backgroundAudio = false

  init(registry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
    self.registry = registry
    flutter = PlayerFlutterApi(binaryMessenger: messenger)
    super.init()
    audioSession = MpxAudioSession { [weak self] change in
      self?.flutter.onAudioFocusChange(change: change) { _ in }
    }
    pictureInPicture = MpxPictureInPicture { [weak self] id, active, dismissed in
      self?.flutter.onPictureInPictureChange(
        playerId: id, active: active, dismissed: dismissed
      ) { _ in }
    }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
      let registry = registrar.textures()
    #elseif os(macOS)
      let messenger = registrar.messenger
      let registry = registrar.textures
    #endif
    let plugin = MpxPlayerPlugin(registry: registry, messenger: messenger)
    PlayerHostApiSetup.setUp(binaryMessenger: messenger, api: plugin)
    registrar.publish(plugin)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    try? reset()
  }

  // --- Players ---------------------------------------------------------------

  func reset() throws {
    pictureInPicture.stop()
    for player in players.values { player.dispose() }
    players = [:]
    audioSession.abandon()
  }

  func create(source: NativePlayerSource, settings: NativePlayerSettings) throws -> Int64 {
    let id = nextId
    nextId += 1
    let report: (NativePlayerSnapshot) -> Void = { [weak self] snapshot in
      self?.flutter.onSnapshot(snapshot: snapshot) { _ in }
    }
    guard
      let player = MpxPlayer(
        id: id, source: source, settings: settings, registry: registry, report: report)
    else {
      throw PigeonError(
        code: "unreadable",
        message: "The bytes cache reader table is missing or of an older version.",
        details: nil)
    }
    players[id] = player
    return id
  }

  func play(playerId: Int64) throws { players[playerId]?.play() }

  func pause(playerId: Int64) throws { players[playerId]?.pause() }

  func seekTo(playerId: Int64, positionUs: Int64, seekId: Int64) throws {
    players[playerId]?.seek(toUs: positionUs, id: seekId)
  }

  func setSpeed(playerId: Int64, speed: Double) throws { players[playerId]?.setSpeed(speed) }

  func setLooping(playerId: Int64, looping: Bool) throws {
    players[playerId]?.setLooping(looping)
  }

  func setVolume(playerId: Int64, volume: Double) throws { players[playerId]?.setVolume(volume) }

  func dispose(playerId: Int64) throws {
    pictureInPicture.playerDisposed(playerId)
    players.removeValue(forKey: playerId)?.dispose()
  }

  // --- Audio session ---------------------------------------------------------

  func requestAudioFocus() throws { audioSession.request() }

  func abandonAudioFocus() throws { audioSession.abandon() }

  // --- Probe -----------------------------------------------------------------

  /// Apple names no decoder-instance limit, so the counts stay 0 (unknown)
  /// and the budget gates on the device class alone. AVPlayer opens
  /// progressive MP4 and QuickTime only here (no WebM, no HLS through the
  /// cache).
  func probe() throws -> NativeDeviceProbe {
    let codecs: [(String, CMVideoCodecType)] = [
      ("video/avc", kCMVideoCodecType_H264),
      ("video/hevc", kCMVideoCodecType_HEVC),
      ("video/av01", kCMVideoCodecType_AV1),
    ]
    let memory = ProcessInfo.processInfo.physicalMemory
    return NativeDeviceProbe(
      lowRam: memory < 2 << 30,
      totalMemoryBytes: Int64(memory),
      cpuCount: Int64(ProcessInfo.processInfo.activeProcessorCount),
      memoryClassMb: 0,
      decoders: codecs.map { mime, type in
        NativeDecoderInfo(
          mimeType: mime, hardware: VTIsHardwareDecodeSupported(type), maxInstances: 0)
      },
      containers: ["video/mp4", "video/quicktime", "video/x-m4v"],
      failedCodecs: [])
  }

  // --- Picture in picture and background -------------------------------------

  func isPictureInPictureSupported() throws -> Bool { MpxPictureInPicture.isSupported }

  func startPictureInPicture(playerId: Int64) throws {
    if let player = players[playerId] { pictureInPicture.start(player) }
  }

  func stopPictureInPicture() throws { pictureInPicture.stop() }

  func setBackgroundAudio(enabled: Bool) throws { backgroundAudio = enabled }
}
