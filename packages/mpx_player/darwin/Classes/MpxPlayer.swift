import AVFoundation
import QuartzCore
import CoreVideo
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// One AVPlayer drawing into a Flutter texture.
///
/// Frames come out of an `AVPlayerItemVideoOutput` as IOSurface-backed BGRA
/// buffers with BT.709 colour properties: AVFoundation converts (and tone
/// maps HDR) on the GPU, and the engine wraps the buffer without a copy.
/// NV12 is never handed over, since the engine converts it as BT.601. The
/// track's rotation is baked in by a video composition, so the texture is
/// upright and `quarterTurns` is always 0.
///
/// Every method runs on the main thread. State goes to Dart as whole
/// snapshots through [report] on each change and every 100 ms while playing;
/// Dart extrapolates the playhead in between and slews it onto each report.
final class MpxPlayer: NSObject, FlutterTexture {
  let id: Int64
  private(set) var textureId: Int64 = 0
  let player = AVPlayer()

  private let item: AVPlayerItem
  private let output: AVPlayerItemVideoOutput
  private let loader: MpxResourceLoader
  private let registry: FlutterTextureRegistry
  private let report: (NativePlayerSnapshot) -> Void
  private var link: MpxDisplayLink!

  // Settings the host asked for.
  private var playing: Bool
  private var speed: Double
  private var looping: Bool

  // Where the player stands.
  private var prepared = false
  private var ended = false
  private var failure: String?
  private var firstFrame = false
  private var startAtUs: Int64
  private var seekId: Int64
  private var latestSeek: Int64 = 0
  private var disposed = false

  // The newest frame, handed to the engine's raster thread.
  private let frameLock = NSLock()
  private var frame: CVPixelBuffer?
  // Display-link ticks left before an idle (paused) player stops looking
  // for frames: a seek or a pause still has a frame to show.
  private var idleTicks = 0

  private var observations: [NSKeyValueObservation] = []
  private var timeObserver: Any?
  private var endObserver: NSObjectProtocol?

  init?(
    id: Int64, source: NativePlayerSource, settings: NativePlayerSettings,
    registry: FlutterTextureRegistry, report: @escaping (NativePlayerSnapshot) -> Void
  ) {
    guard let api = HbcReaderApi(address: source.readerApi),
      let url = MpxResourceLoader.url(forKey: source.cacheKey)
    else { return nil }
    self.id = id
    self.registry = registry
    self.report = report
    playing = settings.playing
    speed = settings.speed
    looping = settings.looping
    startAtUs = max(0, settings.startAtUs)
    seekId = settings.seekId
    loader = MpxResourceLoader(api: api, key: source.cacheKey, mimeType: source.mimeType)
    let asset = AVURLAsset(url: url)
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    item = AVPlayerItem(asset: asset)
    output = AVPlayerItemVideoOutput(outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ])
    super.init()
    link = MpxDisplayLink { [weak self] in self?.tick() }
    textureId = registry.register(self)
    item.add(output)
    player.volume = Float(settings.volume)
    player.actionAtItemEnd = .pause
    observe()
    applyRotation(of: asset)
    player.replaceCurrentItem(with: item)
    report(snapshot())
  }

  // --- Commands --------------------------------------------------------------

  func play() {
    playing = true
    guard prepared, failure == nil else { return report(snapshot()) }
    if ended {
      ended = false
      performSeek(toUs: 0, id: nil)
    }
    player.rate = Float(speed)
    wake()
    report(snapshot())
  }

  func pause() {
    playing = false
    player.pause()
    wake()
    report(snapshot())
  }

  func seek(toUs us: Int64, id: Int64) {
    guard prepared else {
      // Not ready yet: the start seek takes it.
      startAtUs = max(0, us)
      seekId = id
      return
    }
    performSeek(toUs: us, id: id)
  }

  func setSpeed(_ value: Double) {
    speed = value
    if prepared && playing && failure == nil { player.rate = Float(value) }
    report(snapshot())
  }

  func setLooping(_ value: Bool) {
    looping = value
    report(snapshot())
  }

  func setVolume(_ value: Double) {
    player.volume = Float(value)
  }

  func dispose() {
    if disposed { return }
    disposed = true
    link.stop()
    loader.close()
    observations.forEach { $0.invalidate() }
    observations = []
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    player.pause()
    player.replaceCurrentItem(with: nil)
    registry.unregisterTexture(textureId)
    frameLock.lock()
    frame = nil
    frameLock.unlock()
  }

  // --- FlutterTexture --------------------------------------------------------

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    frameLock.lock()
    defer { frameLock.unlock() }
    guard let frame else { return nil }
    return Unmanaged.passRetained(frame)
  }

  // --- Internals -------------------------------------------------------------

  private func performSeek(toUs us: Int64, id: Int64?) {
    let duration = durationUs ?? Int64.max
    let target = min(max(0, us), duration)
    if target < duration { ended = false }
    latestSeek += 1
    let mine = latestSeek
    player.seek(
      to: CMTime(value: target, timescale: 1_000_000), toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self, !self.disposed else { return }
        // A newer seek replaced this one; its own completion reports.
        guard finished, mine == self.latestSeek else { return }
        if let id { self.seekId = max(self.seekId, id) }
        if self.playing && !self.ended { self.player.rate = Float(self.speed) }
        self.wake()
        self.report(self.snapshot())
      }
    }
  }

  private func observe() {
    observations = [
      item.observe(\.status, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.statusChanged() }
      },
      item.observe(\.presentationSize, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.changed() }
      },
      item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.changed() }
      },
      player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.changed() }
      },
    ]
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 10), queue: .main
    ) { [weak self] _ in
      guard let self, self.player.timeControlStatus == .playing else { return }
      self.report(self.snapshot())
    }
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
    ) { [weak self] _ in self?.reachedEnd() }
  }

  private func statusChanged() {
    guard !disposed else { return }
    switch item.status {
    case .readyToPlay where !prepared:
      startPlaying()
    case .failed:
      failure = item.error?.localizedDescription ?? "The player item failed"
      // The whole error and its underlying one go to the log: the snapshot
      // carries one line to Dart, and a failure seen only on a device needs
      // its cause.
      let error = item.error as NSError?
      let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
      NSLog(
        "mpx_player: player %lld failed: %@ (underlying: %@)",
        id, String(describing: error), String(describing: underlying)
      )
      link.stop()
      report(snapshot())
    default:
      changed()
    }
  }

  // Ready: seek to the start, then report ready and follow the play wish.
  private func startPlaying() {
    let finish = { [weak self] in
      guard let self, !self.disposed, self.failure == nil else { return }
      self.prepared = true
      if self.playing { self.player.rate = Float(self.speed) }
      self.wake()
      self.report(self.snapshot())
    }
    guard startAtUs > 0 else { return finish() }
    let duration = durationUs ?? Int64.max
    player.seek(
      to: CMTime(value: min(startAtUs, duration), timescale: 1_000_000),
      toleranceBefore: .zero, toleranceAfter: .zero
    ) { _ in DispatchQueue.main.async(execute: finish) }
  }

  private func reachedEnd() {
    guard !disposed else { return }
    if looping {
      performSeek(toUs: 0, id: nil)
      return
    }
    ended = true
    report(snapshot())
  }

  private func changed() {
    guard !disposed else { return }
    report(snapshot())
  }

  private func wake() {
    idleTicks = 30
    link.start()
  }

  private func tick() {
    guard !disposed else { return }
    let now = output.itemTime(forHostTime: CACurrentMediaTime())
    if output.hasNewPixelBuffer(forItemTime: now),
      let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil)
    {
      frameLock.lock()
      frame = buffer
      frameLock.unlock()
      registry.textureFrameAvailable(textureId)
      if !firstFrame {
        firstFrame = true
        report(snapshot())
      }
    }
    if player.timeControlStatus == .paused {
      idleTicks -= 1
      if idleTicks <= 0 { link.stop() }
    }
  }

  // Bakes the track's rotation into the frames through a video composition,
  // so the texture comes out upright.
  private func applyRotation(of asset: AVURLAsset) {
    asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) { [weak self] in
      DispatchQueue.main.async {
        guard let self, !self.disposed,
          asset.statusOfValue(forKey: "tracks", error: nil) == .loaded,
          let track = asset.tracks(withMediaType: .video).first
        else { return }
        let transform = track.preferredTransform
        if transform.isIdentity { return }
        let natural = CGRect(origin: .zero, size: track.naturalSize)
        let turned = natural.applying(transform)
        let upright = transform.concatenating(
          CGAffineTransform(translationX: -turned.minX, y: -turned.minY))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(upright, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = turned.size
        let fps = track.nominalFrameRate > 0 ? track.nominalFrameRate : 30
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        self.item.videoComposition = composition
      }
    }
  }

  private var durationUs: Int64? {
    let duration = item.duration
    guard duration.isNumeric, duration.seconds > 0 else { return nil }
    return CMTimeConvertScale(duration, timescale: 1_000_000, method: .roundHalfAwayFromZero)
      .value
  }

  private func snapshot() -> NativePlayerSnapshot {
    let phase: NativePlayerPhase
    if failure != nil {
      phase = .failed
    } else if !prepared {
      phase = .preparing
    } else if ended {
      phase = .ended
    } else if playing && player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
      phase = .buffering
    } else {
      phase = .ready
    }
    let positionUs: Int64
    if !prepared {
      positionUs = startAtUs
    } else if ended, let durationUs {
      positionUs = durationUs
    } else {
      let time = player.currentTime()
      positionUs =
        time.isNumeric
        ? max(0, CMTimeConvertScale(time, timescale: 1_000_000, method: .roundHalfAwayFromZero).value)
        : 0
    }
    var buffered: [Int64] = []
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      guard range.start.isNumeric, range.duration.isNumeric else { continue }
      buffered.append(Int64(range.start.seconds * 1_000_000))
      buffered.append(Int64(range.end.seconds * 1_000_000))
    }
    let size = item.presentationSize
    let failed = failure != nil
    return NativePlayerSnapshot(
      playerId: id,
      phase: phase,
      positionUs: positionUs,
      sampledAtUs: Int64(CACurrentMediaTime() * 1_000_000),
      advancing: prepared && !failed && player.timeControlStatus == .playing,
      quarterTurns: 0,
      firstFrameRendered: firstFrame && !failed,
      buffered: failed ? [] : buffered,
      seekId: seekId,
      durationUs: failed ? nil : durationUs,
      width: size.width > 0 && !failed ? Int64(size.width) : nil,
      height: size.height > 0 && !failed ? Int64(size.height) : nil,
      textureId: failed ? nil : textureId,
      error: failure,
      failedCodec: nil
    )
  }
}

