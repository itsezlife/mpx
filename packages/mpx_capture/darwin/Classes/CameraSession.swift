import AVFoundation
import ImageIO
import CoreMedia
import CoreVideo

#if os(iOS)
  import CallKit
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// One live camera for the Dart `CameraSession`: an AVCaptureSession whose
/// video data output backs a Flutter texture, a photo output for photos, and
/// an AVAssetWriter (H.264, AAC) fed from the same outputs for videos.
///
/// Capture callbacks, the writer and every control run on one serial queue.
/// The frames are upright (portrait on iOS) and never mirrored; the Dart
/// preview mirrors a front camera. iOS records without the microphone while
/// a call is active.
final class CameraSession: NSObject, FlutterTexture,
  AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
  AVCapturePhotoCaptureDelegate
{
  let id: Int
  var emit: ([String: Any]) -> Void = { _ in }

  private let textures: FlutterTextureRegistry
  private var textureId: Int64?
  private let queue = DispatchQueue(label: "dev.mpx.capture.camera")
  private let session = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let audioOutput = AVCaptureAudioDataOutput()
  private let photoOutput = AVCapturePhotoOutput()
  private var cameraInput: AVCaptureDeviceInput?
  private var facing: String
  private var frameRateCap: Int?
  private let audio: Bool
  private var flash = "off"

  private let frameLock = NSLock()
  private var latestFrame: CVPixelBuffer?
  private var previewWidth = 0
  // Set by a switch until the new camera's first frame, which Dart hears as
  // `firstFrame`: until then the texture holds the old camera's frames.
  private var awaitingFirstFrame = false
  private var previewHeight = 0
  private var opened: (([String: Any]) -> Void)?
  private var closed = false
  private var paused = false

  private var writer: AVAssetWriter?
  private var writerVideo: AVAssetWriterInput?
  private var writerAudio: AVAssetWriterInput?
  private var recordingURL: URL?
  private var startPts: CMTime?
  private var lastPts = CMTime.zero
  private var stopping = false
  private var photoRequests: [Int64: (URL, (Result<[String: Any], Error>) -> Void)] = [:]

  init(id: Int, textures: FlutterTextureRegistry, facing: String, frameRateCap: Int?, audio: Bool) {
    self.id = id
    self.textures = textures
    self.facing = facing
    self.frameRateCap = frameRateCap
    self.audio = audio
    super.init()
  }

  // MARK: - Permissions

  /// Asks for the camera (and the microphone with `audio`) when not yet
  /// asked; `done` runs once both answered.
  static func requestAccess(audio: Bool, _ done: @escaping () -> Void) {
    func microphone() {
      guard audio, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
        return done()
      }
      AVCaptureDevice.requestAccess(for: .audio) { _ in done() }
    }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
      return microphone()
    }
    AVCaptureDevice.requestAccess(for: .video) { _ in microphone() }
  }

  // MARK: - Controls

  /// Starts the camera; `done` gets the state once the first frame arrived,
  /// or `denied` / `failed`.
  func open(_ done: @escaping ([String: Any]) -> Void) {
    queue.async {
      guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
        return done(["state": "denied"])
      }
      do {
        try self.configure()
      } catch {
        return done(["state": "failed"])
      }
      self.textureId = DispatchQueue.main.sync { self.textures.register(self) }
      self.opened = done
      self.session.startRunning()
      self.queue.asyncAfter(deadline: .now() + 5) {
        guard let opened = self.opened else { return }
        self.opened = nil
        opened(["state": "failed"])
      }
    }
  }

  func setFrameRateCap(_ fps: Int?) {
    queue.async {
      self.frameRateCap = fps
      self.applyFrameRate()
    }
  }

  /// "granted", "denied" (refused or restricted) or "notDetermined".
  static func microphoneAccess() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "granted"
    case .notDetermined: return "notDetermined"
    default: return "denied"
    }
  }

  /// Answers the microphone access, asking for it first with [request]; a
  /// grant adds the microphone to the running session.
  func microphone(request: Bool, _ done: @escaping (String) -> Void) {
    guard request, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
      return done(Self.microphoneAccess())
    }
    AVCaptureDevice.requestAccess(for: .audio) { granted in
      guard granted else { return done(Self.microphoneAccess()) }
      self.queue.async {
        if !self.closed {
          self.session.beginConfiguration()
          self.addMicrophone()
          self.session.commitConfiguration()
        }
        done(Self.microphoneAccess())
      }
    }
  }

  // Adds the microphone (when allowed, asked for, and no call holds it)
  // unless it is in already. On the session queue, in a configuration.
  private func addMicrophone() {
    guard audio, !Self.callActive, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
      !session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }),
      let mic = AVCaptureDevice.default(for: .audio),
      let micInput = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micInput)
    else { return }
    session.addInput(micInput)
    audioOutput.setSampleBufferDelegate(self, queue: queue)
    if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
  }

  func setFlash(_ mode: String) {
    queue.async { self.flash = mode }
  }

  /// The camera for [facing]: on the back of an iPhone, the virtual device
  /// that joins its lenses (triple, dual wide, dual) when there is one, so
  /// zooming moves across them; otherwise the wide camera.
  static func camera(_ facing: String, exact: Bool) -> AVCaptureDevice? {
    #if os(iOS)
      if facing == "back" {
        for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera] {
          if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
      }
    #endif
    return RoundVideoRecorder.camera(facing, exact: exact)
  }

  // The device zoom factor that shows as 1x: the first switch-over factor
  // of a virtual device that starts with the ultra wide lens, 1 otherwise.
  private func zoomBase(_ device: AVCaptureDevice) -> CGFloat {
    #if os(iOS)
      if device.isVirtualDevice,
        device.constituentDevices.first?.deviceType == .builtInUltraWideCamera,
        let first = device.virtualDeviceSwitchOverVideoZoomFactors.first
      {
        return CGFloat(truncating: first)
      }
    #endif
    return 1
  }

  /// The zoom facts as shown: 1x the main lens's own view.
  private func zoomFacts() -> [String: Any] {
    #if os(iOS)
      guard let device = cameraInput?.device else { return [:] }
      let base = zoomBase(device)
      let low = device.minAvailableVideoZoomFactor / base
      let high = min(device.maxAvailableVideoZoomFactor, 16 * base) / base
      var lenses: [Double] = []
      if base > 1 { lenses.append(Double(1 / base)) }
      lenses.append(1)
      if device.isVirtualDevice,
        device.constituentDevices.last?.deviceType == .builtInTelephotoCamera,
        let last = device.virtualDeviceSwitchOverVideoZoomFactors.last
      {
        lenses.append(Double(CGFloat(truncating: last) / base))
      }
      return [
        "minZoom": Double(low), "maxZoom": Double(high),
        "zoomFactor": Double(device.videoZoomFactor / base), "lenses": lenses,
        "hasExposure": device.maxExposureTargetBias > device.minExposureTargetBias,
      ]
    #else
      return ["minZoom": 1.0, "maxZoom": 1.0, "zoomFactor": 1.0, "lenses": [1.0], "hasExposure": false]
    #endif
  }

  /// Zooms to the shown factor [value] (1x the main lens), clamped.
  func setZoomFactor(_ value: Double) {
    #if os(iOS)
      queue.async {
        guard let device = self.cameraInput?.device,
          (try? device.lockForConfiguration()) != nil
        else { return }
        defer { device.unlockForConfiguration() }
        let factor = CGFloat(value) * self.zoomBase(device)
        device.videoZoomFactor = max(
          device.minAvailableVideoZoomFactor,
          min(min(device.maxAvailableVideoZoomFactor, 16 * self.zoomBase(device)), factor))
      }
    #endif
  }

  /// Sets the exposure from -1 (darkest) to 1 (brightest): a target bias of
  /// that share of the device's extreme, at most 85 % of it.
  func setExposure(_ value: Double) {
    #if os(iOS)
      queue.async {
        guard let device = self.cameraInput?.device,
          (try? device.lockForConfiguration()) != nil
        else { return }
        defer { device.unlockForConfiguration() }
        let v = max(-1, min(1, value))
        let extreme = v >= 0 ? device.maxExposureTargetBias : device.minExposureTargetBias
        device.setExposureTargetBias(Float(abs(v)) * extreme * 0.85, completionHandler: nil)
      }
    #endif
  }

  // A camera just put in starts at 1x.
  private func resetZoom() {
    #if os(iOS)
      guard let device = cameraInput?.device, (try? device.lockForConfiguration()) != nil else {
        return
      }
      defer { device.unlockForConfiguration() }
      device.videoZoomFactor = max(device.minAvailableVideoZoomFactor, zoomBase(device))
    #endif
  }

  /// Focuses and exposes at (x, y) of the preview as shown, 0 to 1 from its
  /// top left (the preview stands upright; the front camera's is mirrored).
  func focusAt(x: Double, y: Double) {
    queue.async {
      guard let device = self.cameraInput?.device,
        (try? device.lockForConfiguration()) != nil
      else { return }
      defer { device.unlockForConfiguration() }
      let shownX = self.facing == "front" ? 1 - x : x
      // The sensor's point of interest is in landscape: (0, 0) top left
      // with the home button on the right.
      let point = CGPoint(x: y, y: 1 - shownX)
      if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
        device.focusPointOfInterest = point
        device.focusMode = .autoFocus
      }
      if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
        device.exposurePointOfInterest = point
        device.exposureMode = .autoExpose
      }
    }
  }

  func pause() {
    queue.async {
      guard !self.closed else { return }
      self.paused = true
      if self.session.isRunning { self.session.stopRunning() }
    }
  }

  func resume() {
    queue.async {
      self.awaitingFirstFrame = true
      guard !self.closed, self.paused else { return }
      self.paused = false
      self.session.startRunning()
    }
  }

  func switchCamera(_ done: @escaping (String) -> Void) {
    queue.async {
      let next = self.facing == "front" ? "back" : "front"
      guard !self.closed, self.writer == nil, let device = Self.camera(next, exact: true),
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
      self.configureConnections()
      self.session.commitConfiguration()
      self.resetZoom()
      self.applyFrameRate()
      self.previewWidth = 0  // re-read from the next frame
      self.awaitingFirstFrame = true
      done(self.facing)
    }
  }

  func capturePhoto(
    output: String, mirrorFront: Bool = false,
    _ done: @escaping (Result<[String: Any], Error>) -> Void
  ) {
    queue.async {
      guard !self.closed, !self.paused, self.session.outputs.contains(self.photoOutput) else {
        return done(.failure(CaptureError.failed("camera not available")))
      }
      // Saved as the preview shows it, for a front camera asked to.
      if let connection = self.photoOutput.connection(with: .video),
        connection.isVideoMirroringSupported
      {
        connection.isVideoMirrored = mirrorFront && self.facing == "front"
      }
      let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
      #if os(iOS)
        let mode: AVCaptureDevice.FlashMode =
          self.flash == "on" ? .on : self.flash == "auto" ? .auto : .off
        if self.photoOutput.supportedFlashModes.contains(mode) { settings.flashMode = mode }
        if #available(iOS 16.0, *) {
          settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
        }
      #endif
      self.photoRequests[settings.uniqueID] = (URL(fileURLWithPath: output), done)
      self.photoOutput.capturePhoto(with: settings, delegate: self)
    }
  }

  func photoOutput(
    _ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
    error: Error?
  ) {
    queue.async {
      guard let (url, done) = self.photoRequests.removeValue(forKey: photo.resolvedSettings.uniqueID)
      else { return }
      guard error == nil, let data = photo.fileDataRepresentation() else {
        return done(.failure(CaptureError.failed(error?.localizedDescription ?? "photo failed")))
      }
      do {
        try FileManager.default.removeItemIfExists(url)
        try data.write(to: url)
        let facts = try StillCodec.probe(path: url.path)
        done(
          .success([
            "path": url.path, "size": fileSize(url),
            "width": facts["width"] ?? 0, "height": facts["height"] ?? 0,
          ]))
      } catch {
        try? FileManager.default.removeItemIfExists(url)
        done(.failure(CaptureError.wrap(error)))
      }
    }
  }

  func startRecording(output: String, _ done: @escaping (Error?) -> Void) {
    queue.async {
      guard !self.closed, !self.paused, self.writer == nil, self.previewWidth > 0 else {
        return done(CaptureError.failed("camera not available"))
      }
      do {
        try self.makeWriter(URL(fileURLWithPath: output))
        self.torch(self.flash == "on")
        done(nil)
      } catch {
        self.writer = nil
        done(error)
      }
    }
  }

  func stopRecording(_ done: @escaping (Result<[String: Any], Error>) -> Void) {
    queue.async {
      guard let writer = self.writer, let url = self.recordingURL, !self.stopping else {
        return done(.failure(CaptureError.failed("not recording")))
      }
      self.stopping = true
      self.torch(false)
      guard self.startPts != nil, writer.status == .writing else {
        self.resetWriter()
        try? FileManager.default.removeItemIfExists(url)
        return done(.failure(CaptureError.failed("nothing was recorded")))
      }
      let duration = self.lastPts - (self.startPts ?? self.lastPts)
      self.writerVideo?.markAsFinished()
      self.writerAudio?.markAsFinished()
      writer.finishWriting {
        self.queue.async {
          let width = self.writerWidth
          let height = self.writerHeight
          self.resetWriter()
          guard writer.status == .completed else {
            try? FileManager.default.removeItemIfExists(url)
            return done(
              .failure(
                CaptureError.failed(writer.error?.localizedDescription ?? "cannot finish writing")))
          }
          var facts: [String: Any] = [
            "path": url.path, "size": fileSize(url), "width": width, "height": height,
            "durationUs": Int(CMTimeGetSeconds(duration) * 1_000_000),
          ]
          if let poster = Self.poster(of: url) { facts["poster"] = poster }
          done(.success(facts))
        }
      }
    }
  }

  /// The first frame as a small JPEG beside the video (320 on its long
  /// side), upright; nil when it cannot be read.
  static func poster(of url: URL) -> String? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 320, height: 320)
    guard let image = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil }
    let path = url.path + ".poster.jpg"
    guard
      let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? path : nil
  }

  func close() {
    queue.async {
      guard !self.closed else { return }
      self.closed = true
      self.opened = nil
      if let writer = self.writer {
        writer.cancelWriting()
        if let url = self.recordingURL { try? FileManager.default.removeItemIfExists(url) }
        self.resetWriter()
      }
      for (_, request) in self.photoRequests {
        request.1(.failure(CaptureError.failed("camera session closed")))
      }
      self.photoRequests.removeAll()
      if self.session.isRunning { self.session.stopRunning() }
      if let id = self.textureId {
        self.textureId = nil
        DispatchQueue.main.async { [textures = self.textures] in textures.unregisterTexture(id) }
      }
    }
  }

  // MARK: - Setup

  private func configure() throws {
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
    guard let device = Self.camera(facing, exact: false) else {
      throw CaptureError.failed("no camera")
    }
    #if os(iOS)
      if device.position == .back { facing = "back" } else if device.position == .front {
        facing = "front"
      }
    #endif
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw CaptureError.failed("cannot open the camera") }
    session.addInput(input)
    cameraInput = input
    resetZoom()
    addMicrophone()
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.alwaysDiscardsLateVideoFrames = true
    videoOutput.setSampleBufferDelegate(self, queue: queue)
    guard session.canAddOutput(videoOutput) else { throw CaptureError.failed("cannot read frames") }
    session.addOutput(videoOutput)
    if session.canAddOutput(photoOutput) {
      session.addOutput(photoOutput)
      #if os(iOS)
        if #available(iOS 16.0, *) {
          if let largest = device.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = largest
          }
        } else {
          photoOutput.isHighResolutionCaptureEnabled = true
        }
      #endif
    }
    configureConnections()
    applyFrameRate()
  }

  private func configureConnections() {
    for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
      guard let connection else { continue }
      #if os(iOS)
        if #available(iOS 17.0, *) {
          if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        } else if connection.isVideoOrientationSupported {
          connection.videoOrientation = .portrait
        }
      #endif
      if connection.isVideoMirroringSupported {
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = false
      }
    }
  }

  private func applyFrameRate() {
    guard let device = cameraInput?.device, (try? device.lockForConfiguration()) != nil else {
      return
    }
    defer { device.unlockForConfiguration() }
    if let cap = frameRateCap,
      device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
        $0.minFrameRate <= Double(cap) && Double(cap) <= $0.maxFrameRate
      })
    {
      device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(cap))
    } else {
      // Invalid restores the format's own rate.
      device.activeVideoMinFrameDuration = .invalid
    }
  }

  private func torch(_ on: Bool) {
    #if os(iOS)
      guard let device = cameraInput?.device, device.hasTorch,
        (try? device.lockForConfiguration()) != nil
      else { return }
      device.torchMode = on ? .on : .off
      device.unlockForConfiguration()
    #endif
  }

  private static var callActive: Bool {
    #if os(iOS)
      return CXCallObserver().calls.contains { !$0.hasEnded }
    #else
      return false
    #endif
  }

  private var hasFlash: Bool {
    #if os(iOS)
      return cameraInput?.device.hasFlash ?? false
    #else
      return false
    #endif
  }

  private var canSwitch: Bool {
    RoundVideoRecorder.camera("front", exact: true) != nil
      && RoundVideoRecorder.camera("back", exact: true) != nil
  }

  // MARK: - Writer

  private var writerWidth = 0
  private var writerHeight = 0

  private func makeWriter(_ url: URL) throws {
    try FileManager.default.removeItemIfExists(url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true
    var settings =
      videoOutput.recommendedVideoSettings(forVideoCodecType: .h264, assetWriterOutputFileType: .mp4)
      ?? [:]
    settings[AVVideoCodecKey] = AVVideoCodecType.h264
    settings[AVVideoWidthKey] = previewWidth
    settings[AVVideoHeightKey] = previewHeight
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    video.expectsMediaDataInRealTime = true
    guard writer.canAdd(video) else { throw CaptureError.failed("cannot write video") }
    writer.add(video)
    if session.outputs.contains(audioOutput) {
      let recommended = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) ?? [:]
      let audio = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: recommended[AVSampleRateKey] as? Double ?? 48_000,
          AVNumberOfChannelsKey: 1,
          AVChannelLayoutKey: channelLayout(1),
          AVEncoderBitRateKey: 64_000,
        ])
      audio.expectsMediaDataInRealTime = true
      if writer.canAdd(audio) {
        writer.add(audio)
        writerAudio = audio
      }
    }
    self.writer = writer
    writerVideo = video
    recordingURL = url
    writerWidth = previewWidth
    writerHeight = previewHeight
    startPts = nil
    stopping = false
  }

  private func resetWriter() {
    writer = nil
    writerVideo = nil
    writerAudio = nil
    recordingURL = nil
    startPts = nil
    stopping = false
  }

  // MARK: - Samples

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    if output === videoOutput { video(sampleBuffer) } else { audioSample(sampleBuffer) }
  }

  private func video(_ sample: CMSampleBuffer) {
    guard !closed, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
    frameLock.lock()
    latestFrame = pixels
    frameLock.unlock()
    guard let id = textureId else { return }
    DispatchQueue.main.async { [textures] in textures.textureFrameAvailable(id) }
    let width = CVPixelBufferGetWidth(pixels)
    let height = CVPixelBufferGetHeight(pixels)
    let first = awaitingFirstFrame
    awaitingFirstFrame = false
    if first || width != previewWidth || height != previewHeight {
      previewWidth = width
      previewHeight = height
      if opened == nil {
        emit(
          state("available").merging(["job": self.id, "type": "camera", "firstFrame": first]) {
            $1
          })
      }
    }
    if let opened {
      self.opened = nil
      opened(state("available"))
    }

    guard let writer, let input = writerVideo, !stopping else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if startPts == nil {
      guard writer.startWriting() else { return }
      writer.startSession(atSourceTime: pts)
      startPts = pts
    }
    lastPts = pts
    if input.isReadyForMoreMediaData { input.append(sample) }
  }

  private func audioSample(_ sample: CMSampleBuffer) {
    guard !closed, !stopping, let startPts, let input = writerAudio, input.isReadyForMoreMediaData
    else { return }
    guard CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), startPts) >= 0 else { return }
    input.append(sample)
  }

  private func state(_ name: String) -> [String: Any] {
    let base: [String: Any] = [
      "state": name, "textureId": Int(textureId ?? -1), "previewWidth": previewWidth,
      "previewHeight": previewHeight, "quarterTurns": 0, "facing": facing,
      "hasFlash": hasFlash, "canSwitch": canSwitch,
      "microphone": Self.microphoneAccess(),
    ]
    return base.merging(zoomFacts()) { _, new in new }
  }

  // MARK: - FlutterTexture

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    frameLock.lock()
    defer { frameLock.unlock() }
    guard let frame = latestFrame else { return nil }
    return Unmanaged.passRetained(frame)
  }
}
