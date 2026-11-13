import AVFoundation
import CoreMedia
import CoreVideo

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Records one round video message: AVCaptureSession frames and microphone
/// audio into an AVAssetWriter that crops the centre square, while the latest
/// frame backs a Flutter texture for the preview.
///
/// Capture callbacks, the writer and every control run on one serial queue.
/// Paused time is cut out by shifting later samples back by the pause.
final class RoundVideoRecorder: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate
{
  struct Config {
    let job: Int
    let output: URL
    let side: Int
    let videoBitrate: Int
    let frameRate: Int
    let audioBitrate: Int
    let maxDuration: CMTime
    let camera: String

    init(_ args: [String: Any]) throws {
      guard let job = args["job"] as? Int,
        let output = args["output"] as? String,
        let side = args["side"] as? Int,
        let videoBitrate = args["videoBitrate"] as? Int,
        let frameRate = args["frameRate"] as? Int,
        let audioBitrate = args["audioBitrate"] as? Int,
        let maxDurationUs = (args["maxDurationUs"] as? NSNumber)?.int64Value
      else { throw CaptureError.failed("roundStart: missing arguments") }
      self.job = job
      self.output = URL(fileURLWithPath: output)
      self.side = side
      self.videoBitrate = videoBitrate
      self.frameRate = max(1, frameRate)
      self.audioBitrate = audioBitrate
      self.maxDuration = CMTime(value: maxDurationUs, timescale: 1_000_000)
      self.camera = args["camera"] as? String ?? "front"
    }
  }

  var emit: ([String: Any]) -> Void = { _ in }
  var onFinish: () -> Void = {}

  private let config: Config
  private let textures: FlutterTextureRegistry
  private var textureId: Int64?
  private let queue = DispatchQueue(label: "dev.mpx.capture.round")
  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private var cameraInput: AVCaptureDeviceInput?
  private var facing: String
  private var writer: AVAssetWriter?
  private var writerVideo: AVAssetWriterInput?
  private var writerAudio: AVAssetWriterInput?

  private let frameLock = NSLock()
  private var latestFrame: CVPixelBuffer?

  private var started: ((Result<[String: Any], Error>) -> Void)?
  private var startPts: CMTime?
  private var lastVideoPts = CMTime.invalid
  private var offset = CMTime.zero
  private var paused = false
  private var resumePending = false
  private var position = CMTime.zero
  private var lastReport = CFAbsoluteTime(0)
  private var stopping = false
  private var finished = false
  private var cancelled = false

  init(config: Config, textures: FlutterTextureRegistry) {
    self.config = config
    self.textures = textures
    self.facing = config.camera
    super.init()
  }

  // MARK: - Permissions

  static var authorized: Bool {
    AVCaptureDevice.authorizationStatus(for: .video) == .authorized
      && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  static func requestPermissions(_ done: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .video) { video in
      guard video else { return done(false) }
      AVCaptureDevice.requestAccess(for: .audio) { audio in done(audio) }
    }
  }

  // MARK: - Controls

  /// Opens the camera and the writer; `done` gets the preview texture once
  /// the first frame arrived.
  func start(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
    queue.async {
      guard Self.authorized else {
        return done(.failure(CaptureError.permission("camera or microphone not allowed")))
      }
      do {
        try self.configureSession()
        try self.makeWriter()
        self.textureId = DispatchQueue.main.sync { self.textures.register(self) }
        self.started = done
        self.session.startRunning()
        self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
          guard let self, let started = self.started else { return }
          self.started = nil
          self.writer?.cancelWriting()
          self.teardown()
          try? FileManager.default.removeItemIfExists(self.config.output)
          started(.failure(CaptureError.failed("the camera sent no frames")))
        }
      } catch {
        self.teardown()
        done(.failure(error))
      }
    }
  }

  func pause() {
    queue.async { if !self.finished { self.paused = true } }
  }

  func resume() {
    queue.async {
      guard !self.finished, self.paused else { return }
      self.paused = false
      self.resumePending = self.startPts != nil
    }
  }

  func stop() {
    queue.async { self.finish() }
  }

  func cancel() {
    queue.async {
      guard !self.finished else { return }
      self.cancelled = true
      self.writer?.cancelWriting()
      self.teardown()
      try? FileManager.default.removeItemIfExists(self.config.output)
    }
  }

  func switchCamera(_ done: @escaping (String) -> Void) {
    queue.async {
      let next = self.facing == "front" ? "back" : "front"
      guard !self.finished, let device = Self.camera(next, exact: true),
        let input = try? AVCaptureDeviceInput(device: device)
      else { return done(self.facing) }
      self.session.beginConfiguration()
      if let old = self.cameraInput { self.session.removeInput(old) }
      if self.session.canAddInput(input) {
        self.session.addInput(input)
        self.cameraInput = input
        self.facing = next
      } else if let old = self.cameraInput {
        self.session.addInput(old)
      }
      self.configureConnection()
      self.session.commitConfiguration()
      self.setFrameRate(self.cameraInput?.device)
      done(self.facing)
    }
  }

  // MARK: - Setup

  private func configureSession() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    if session.canSetSessionPreset(.vga640x480) {
      session.sessionPreset = .vga640x480
    }
    guard let device = Self.camera(facing, exact: false) else {
      throw CaptureError.failed("no camera")
    }
    if device.position == .back { facing = "back" } else if device.position == .front {
      facing = "front"
    }
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw CaptureError.failed("cannot open the camera") }
    session.addInput(input)
    cameraInput = input
    if let mic = AVCaptureDevice.default(for: .audio),
      let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput)
    {
      session.addInput(micInput)
    }
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    audioOutput.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(videoOutput) else { throw CaptureError.failed("cannot read frames") }
    session.addOutput(videoOutput)
    if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
    configureConnection()
    setFrameRate(device)
  }

  private func configureConnection() {
    guard let connection = videoOutput.connection(with: .video) else { return }
    #if os(iOS)
      if #available(iOS 17.0, *) {
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
      } else if connection.isVideoOrientationSupported {
        connection.videoOrientation = .portrait
      }
    #endif
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = facing == "front"
    }
  }

  private func setFrameRate(_ device: AVCaptureDevice?) {
    guard let device else { return }
    let fps = Double(config.frameRate)
    let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
      $0.minFrameRate <= fps && fps <= $0.maxFrameRate
    }
    guard supported, (try? device.lockForConfiguration()) != nil else { return }
    let duration = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
    device.activeVideoMinFrameDuration = duration
    device.activeVideoMaxFrameDuration = duration
    device.unlockForConfiguration()
  }

  private func makeWriter() throws {
    try FileManager.default.removeItemIfExists(config.output)
    let writer = try AVAssetWriter(outputURL: config.output, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    let video = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: config.side,
        AVVideoHeightKey: config.side,
        // The writer scales the camera frame to cover the square and crops
        // the rest: the round crop needs no own pixel work.
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: config.videoBitrate,
          AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
          AVVideoMaxKeyFrameIntervalKey: config.frameRate,
          AVVideoExpectedSourceFrameRateKey: config.frameRate,
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
          AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
        ],
      ])
    video.expectsMediaDataInRealTime = true
    guard writer.canAdd(video) else { throw CaptureError.failed("cannot write video") }
    writer.add(video)
    writerVideo = video

    if session.outputs.contains(audioOutput) {
      let recommended =
        audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) ?? [:]
      let sampleRate = recommended[AVSampleRateKey] as? Double ?? 48_000
      let audio = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: sampleRate,
          AVNumberOfChannelsKey: 1,
          AVChannelLayoutKey: channelLayout(1),
          AVEncoderBitRateKey: config.audioBitrate,
        ])
      audio.expectsMediaDataInRealTime = true
      if writer.canAdd(audio) {
        writer.add(audio)
        writerAudio = audio
      }
    }
    self.writer = writer
  }

  static func camera(_ facing: String, exact: Bool) -> AVCaptureDevice? {
    #if os(iOS)
      let position: AVCaptureDevice.Position = facing == "front" ? .front : .back
      if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
      {
        return device
      }
      return exact ? nil : AVCaptureDevice.default(for: .video)
    #else
      // A Mac's cameras face the user or are external: the first counts as
      // front, a second as back.
      let types: [AVCaptureDevice.DeviceType]
      if #available(macOS 14.0, *) {
        types = [.builtInWideAngleCamera, .external]
      } else {
        types = [.builtInWideAngleCamera, .externalUnknown]
      }
      let devices = AVCaptureDevice.DiscoverySession(
        deviceTypes: types, mediaType: .video, position: .unspecified
      ).devices
      let index = facing == "front" ? 0 : 1
      if index < devices.count { return devices[index] }
      return exact ? nil : devices.first
    #endif
  }

  // MARK: - Samples

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output === videoOutput {
      video(sampleBuffer)
    } else {
      audio(sampleBuffer)
    }
  }

  private func video(_ sample: CMSampleBuffer) {
    guard !finished, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
    frameLock.lock()
    latestFrame = pixels
    frameLock.unlock()
    guard let id = textureId else { return }
    DispatchQueue.main.async { [textures] in textures.textureFrameAvailable(id) }
    if let started {
      self.started = nil
      started(
        .success([
          "textureId": Int(id),
          "previewWidth": CVPixelBufferGetWidth(pixels),
          "previewHeight": CVPixelBufferGetHeight(pixels),
          "camera": facing,
        ]))
    }

    guard !paused, !stopping, let writer, let input = writerVideo else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if startPts == nil {
      guard writer.startWriting() else {
        return fail(
          CaptureError.failed(writer.error?.localizedDescription ?? "cannot start writing"))
      }
      writer.startSession(atSourceTime: pts)
      startPts = pts
    }
    if resumePending {
      // The pause lasted from one frame after the last written one to now.
      let frame = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
      offset = offset + (pts - (lastVideoPts + frame))
      resumePending = false
    }
    lastVideoPts = pts
    if input.isReadyForMoreMediaData, let shifted = retimed(sample) {
      input.append(shifted)
    }
    position = pts - offset - (startPts ?? pts)
    report()
    if CMTimeCompare(position, config.maxDuration) >= 0 { finish() }
  }

  private func audio(_ sample: CMSampleBuffer) {
    guard !finished, !paused, !resumePending, !stopping, let startPts,
      let input = writerAudio, input.isReadyForMoreMediaData
    else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample) - offset
    guard CMTimeCompare(pts, startPts) >= 0, let shifted = retimed(sample) else { return }
    input.append(shifted)
  }

  private func retimed(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
    if CMTimeCompare(offset, .zero) == 0 { return sample }
    var count: CMItemCount = 0
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
    var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
    CMSampleBufferGetSampleTimingInfoArray(
      sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
    for i in timing.indices {
      timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - offset
      if timing[i].decodeTimeStamp.isValid {
        timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - offset
      }
    }
    var shifted: CMSampleBuffer?
    CMSampleBufferCreateCopyWithNewTiming(
      allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
      sampleTimingArray: &timing, sampleBufferOut: &shifted)
    return shifted
  }

  private func report() {
    let now = CFAbsoluteTimeGetCurrent()
    guard now - lastReport >= 0.1 else { return }
    lastReport = now
    emit([
      "job": config.job, "type": "progress", "bytes": fileSize(config.output),
      "positionUs": Int(CMTimeGetSeconds(position) * 1_000_000),
      "fraction": fraction,
    ])
  }

  private var fraction: Double {
    let max = CMTimeGetSeconds(config.maxDuration)
    return max > 0 ? min(1, CMTimeGetSeconds(position) / max) : 0
  }

  // MARK: - End

  private func finish() {
    guard !stopping, !finished, !cancelled else { return }
    stopping = true
    guard let writer, startPts != nil, writer.status == .writing else {
      return fail(CaptureError.failed("nothing was recorded"))
    }
    writerVideo?.markAsFinished()
    writerAudio?.markAsFinished()
    writer.finishWriting { [weak self] in
      guard let self else { return }
      self.queue.async {
        guard !self.cancelled else { return }
        if writer.status == .completed {
          self.teardown()
          self.emit([
            "job": self.config.job, "type": "done", "path": self.config.output.path,
            "size": fileSize(self.config.output),
            "durationUs": Int(CMTimeGetSeconds(self.position) * 1_000_000),
            "width": self.config.side, "height": self.config.side,
            "headerRewritten": true, "reencoded": true, "fraction": self.fraction,
          ])
        } else {
          self.fail(
            CaptureError.failed(writer.error?.localizedDescription ?? "cannot finish writing"))
        }
      }
    }
  }

  private func fail(_ error: Error) {
    guard !finished else { return }
    writer?.cancelWriting()
    teardown()
    try? FileManager.default.removeItemIfExists(config.output)
    emit(CaptureError.wrap(error).event(job: config.job))
  }

  private func teardown() {
    guard !finished else { return }
    finished = true
    if session.isRunning { session.stopRunning() }
    if let id = textureId {
      textureId = nil
      DispatchQueue.main.async { [textures] in textures.unregisterTexture(id) }
    }
    onFinish()
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    frameLock.lock()
    defer { frameLock.unlock() }
    guard let frame = latestFrame else { return nil }
    return Unmanaged.passRetained(frame)
  }
}
