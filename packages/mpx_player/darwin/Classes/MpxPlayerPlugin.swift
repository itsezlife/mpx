import AVFoundation
import Foundation

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

  init(registry: FlutterTextureRegistry, messenger: FlutterBinaryMessenger) {
    self.registry = registry
    flutter = PlayerFlutterApi(binaryMessenger: messenger)
    super.init()
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
    for player in players.values { player.dispose() }
    players = [:]
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
        message: "The bytes cache reader table is missing or of another version.",
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
    players.removeValue(forKey: playerId)?.dispose()
  }

  // --- Audio session ---------------------------------------------------------

  func requestAudioFocus() throws {}

  func abandonAudioFocus() throws {}

  // --- Probe -----------------------------------------------------------------

  func probe() throws -> NativeDeviceProbe {
    NativeDeviceProbe(
      lowRam: false,
      totalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
      cpuCount: Int64(ProcessInfo.processInfo.activeProcessorCount),
      memoryClassMb: 0,
      decoders: [],
      containers: ["video/mp4", "video/quicktime", "video/x-m4v"],
      failedCodecs: [])
  }

  // --- Picture in picture and background -------------------------------------

  func isPictureInPictureSupported() throws -> Bool { false }

  func startPictureInPicture(playerId: Int64) throws {}

  func stopPictureInPicture() throws {}

  func setBackgroundAudio(enabled: Bool) throws {}
}
