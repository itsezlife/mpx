import AVFoundation
import CoreMedia

/// One compression as the Dart side planned it.
struct CompressionRequest {
  let job: Int
  let source: URL
  let output: URL
  /// Output frame as displayed (after the track's rotation).
  let width: Int
  let height: Int
  let videoBitrate: Int
  let audioBitrate: Int
  let audioChannels: Int
  let passthrough: Bool
  let durationUs: Int64

  init(_ args: [String: Any]) throws {
    guard let job = args["job"] as? Int,
      let source = args["source"] as? String,
      let output = args["output"] as? String,
      let width = args["width"] as? Int,
      let height = args["height"] as? Int,
      let videoBitrate = args["videoBitrate"] as? Int,
      let audioBitrate = args["audioBitrate"] as? Int,
      let audioChannels = args["audioChannels"] as? Int
    else { throw CaptureError.failed("compress: missing arguments") }
    self.job = job
    self.source = URL(fileURLWithPath: source)
    self.output = URL(fileURLWithPath: output)
    self.width = width
    self.height = height
    self.videoBitrate = videoBitrate
    self.audioBitrate = audioBitrate
    self.audioChannels = audioChannels
    self.passthrough = args["passthrough"] as? Bool ?? false
    self.durationUs = (args["durationUs"] as? NSNumber)?.int64Value ?? 0
  }
}

/// Runs compressions one at a time, in the order they were asked for. Its
/// state is touched on the main thread only.
final class CaptureTranscoder {
  var emit: ([String: Any]) -> Void = { _ in }
  private var pending: [CompressionJob] = []
  private var running: CompressionJob?

  func enqueue(_ request: CompressionRequest) throws {
    let job = CompressionJob(request: request)
    job.emit = { [weak self] event in self?.emit(event) }
    job.onFinish = { [weak self] in
      DispatchQueue.main.async { self?.finished(job) }
    }
    pending.append(job)
    startNext()
  }

  func cancel(job id: Int) {
    if let index = pending.firstIndex(where: { $0.request.job == id }) {
      pending.remove(at: index)
    } else if running?.request.job == id {
      running?.cancel()
    }
  }

  private func finished(_ job: CompressionJob) {
    if running === job { running = nil }
    startNext()
  }

  private func startNext() {
    guard running == nil, !pending.isEmpty else { return }
    let job = pending.removeFirst()
    running = job
    job.start()
  }

  // MARK: - Probe

  /// An asset over the file at `path`. A file without an extension (a
  /// payload in the bytes store) is read as MP4 where the OS lets us say so;
  /// AVFoundation picks the container by extension otherwise.
  static func asset(_ path: String) -> AVURLAsset {
    let url = URL(fileURLWithPath: path)
    if url.pathExtension.isEmpty, #available(iOS 17.0, macOS 14.0, *) {
      return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
    }
    return AVURLAsset(url: url)
  }

  /// What the Dart `SourceVideo` reads: display size, duration, codec,
  /// video bitrate and whether there is audio.
  static func probe(path: String) async throws -> [String: Any] {
    let asset = asset(path)
    let video: AVAssetTrack
    do {
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw CaptureError.failed("no video track: \(path)")
      }
      video = track
    } catch let error as CaptureError {
      throw error
    } catch {
      throw CaptureError.failed("not a video: \(path) (\(error.localizedDescription))")
    }
    let (natural, transform, rate, formats) = try await video.load(
      .naturalSize, .preferredTransform, .estimatedDataRate, .formatDescriptions)
    let duration = try await asset.load(.duration)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    let display = CGRect(origin: .zero, size: natural).applying(transform)
    let codec: String
    switch formats.first.map(CMFormatDescriptionGetMediaSubType) {
    case kCMVideoCodecType_H264: codec = "h264"
    case kCMVideoCodecType_HEVC: codec = "hevc"
    default: codec = "other"
    }
    var info: [String: Any] = [
      "width": Int(abs(display.width).rounded()),
      "height": Int(abs(display.height).rounded()),
      "durationUs": Int(CMTimeGetSeconds(duration) * 1_000_000),
      "codec": codec,
      "hasAudio": !audio.isEmpty,
    ]
    if rate > 0 { info["videoBitrate"] = Int(rate) }
    return info
  }
}

/// One compression: AVAssetReader into AVAssetWriter with explicit H.264 and
/// AAC settings, or an export session for a passthrough. Work runs on its own
/// serial queue; the job reports progress every 100 ms.
final class CompressionJob {
  let request: CompressionRequest
  var emit: ([String: Any]) -> Void = { _ in }
  var onFinish: () -> Void = {}

  private let queue = DispatchQueue(label: "dev.mpx.capture.compress")
  private var reader: AVAssetReader?
  private var writer: AVAssetWriter?
  private var export: AVAssetExportSession?
  private var timer: DispatchSourceTimer?
  private var cancelled = false
  private var finished = false
  private var position = CMTime.zero

  init(request: CompressionRequest) {
    self.request = request
  }

  func start() {
    Task {
      do {
        let asset = CaptureTranscoder.asset(request.source.path)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        guard let video else { throw CaptureError.failed("no video track") }
        let (transform, frameRate) = try await video.load(.preferredTransform, .nominalFrameRate)
        queue.async {
          do {
            try FileManager.default.removeItemIfExists(self.request.output)
            if self.request.passthrough {
              try self.startExport(asset)
            } else {
              try self.startTranscode(
                asset, video: video, audio: audio, transform: transform, frameRate: frameRate)
            }
          } catch {
            self.fail(error)
          }
        }
      } catch {
        queue.async { self.fail(error) }
      }
    }
  }

  func cancel() {
    queue.async {
      guard !self.finished else { return }
      self.cancelled = true
      self.reader?.cancelReading()
      self.writer?.cancelWriting()
      self.export?.cancelExport()
      self.end()
      try? FileManager.default.removeItemIfExists(self.request.output)
    }
  }

  // MARK: - Re-encode

  private func startTranscode(
    _ asset: AVAsset, video: AVAssetTrack, audio: AVAssetTrack?,
    transform: CGAffineTransform, frameRate: Float
  ) throws {
    if cancelled { return }
    let reader = try AVAssetReader(asset: asset)
    let writer = try AVAssetWriter(outputURL: request.output, fileType: .mp4)
    // Moves the index to the front at finish: the head of the file is
    // rewritten, which the done event reports.
    writer.shouldOptimizeForNetworkUse = true
    self.reader = reader
    self.writer = writer

    let videoOutput = AVAssetReaderTrackOutput(
      track: video,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      ])
    videoOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(videoOutput) else { throw CaptureError.failed("cannot read video") }
    reader.add(videoOutput)

    // The plan's size is as displayed; the encoder works on the stored frame,
    // which a quarter turn swaps.
    let quarterTurn = abs(transform.b) == 1 && abs(transform.c) == 1
    let encodedWidth = quarterTurn ? request.height : request.width
    let encodedHeight = quarterTurn ? request.width : request.height
    let fps = frameRate > 0 ? frameRate : 30
    let compression: [String: Any] = [
      AVVideoAverageBitRateKey: request.videoBitrate,
      AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
      AVVideoMaxKeyFrameIntervalKey: max(1, Int(fps.rounded())),
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
    ]
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: encodedWidth,
        AVVideoHeightKey: encodedHeight,
        AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        AVVideoCompressionPropertiesKey: compression,
      ])
    videoInput.transform = transform
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else { throw CaptureError.failed("cannot write video") }
    writer.add(videoInput)

    var audioPair: (AVAssetReaderOutput, AVAssetWriterInput)?
    if let audio {
      let layout = channelLayout(request.audioChannels)
      let audioOutput = AVAssetReaderAudioMixOutput(
        audioTracks: [audio],
        audioSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: 44_100,
          AVNumberOfChannelsKey: request.audioChannels,
          AVChannelLayoutKey: layout,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ])
      let audioInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: 44_100,
          AVNumberOfChannelsKey: request.audioChannels,
          AVChannelLayoutKey: layout,
          AVEncoderBitRateKey: request.audioBitrate,
        ])
      audioInput.expectsMediaDataInRealTime = false
      if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
        reader.add(audioOutput)
        writer.add(audioInput)
        audioPair = (audioOutput, audioInput)
      }
    }

    guard reader.startReading() else {
      throw CaptureError.failed(reader.error?.localizedDescription ?? "cannot start reading")
    }
    guard writer.startWriting() else {
      throw CaptureError.failed(writer.error?.localizedDescription ?? "cannot start writing")
    }
    writer.startSession(atSourceTime: .zero)
    startTimer()

    let group = DispatchGroup()
    pump(videoOutput, into: videoInput, group: group, tracksPosition: true)
    if let (output, input) = audioPair {
      pump(output, into: input, group: group, tracksPosition: false)
    }
    group.notify(queue: queue) { [weak self] in self?.finishWriting() }
  }

  private func pump(
    _ output: AVAssetReaderOutput, into input: AVAssetWriterInput, group: DispatchGroup,
    tracksPosition: Bool
  ) {
    group.enter()
    var done = false
    input.requestMediaDataWhenReady(on: queue) { [weak self] in
      guard let self, !done else { return }
      while input.isReadyForMoreMediaData {
        if self.cancelled || self.reader?.status != .reading {
          done = true
          input.markAsFinished()
          group.leave()
          return
        }
        guard let sample = output.copyNextSampleBuffer() else {
          done = true
          input.markAsFinished()
          group.leave()
          return
        }
        if tracksPosition {
          self.position = CMSampleBufferGetPresentationTimeStamp(sample)
        }
        if !input.append(sample) {
          done = true
          self.reader?.cancelReading()
          input.markAsFinished()
          group.leave()
          return
        }
      }
    }
  }

  private func finishWriting() {
    guard !cancelled, let writer, let reader else { return }
    if reader.status == .failed || writer.status == .failed {
      writer.cancelWriting()
      fail(
        CaptureError.failed(
          (reader.error ?? writer.error)?.localizedDescription ?? "transcode failed"))
      return
    }
    writer.finishWriting { [weak self] in
      guard let self else { return }
      self.queue.async {
        guard !self.cancelled else { return }
        if writer.status == .completed {
          self.complete(reencoded: true)
        } else {
          self.fail(
            CaptureError.failed(writer.error?.localizedDescription ?? "cannot finish writing"))
        }
      }
    }
  }

  // MARK: - Passthrough

  private func startExport(_ asset: AVAsset) throws {
    if cancelled { return }
    guard
      let export = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetPassthrough)
    else { throw CaptureError.failed("cannot remux") }
    export.outputURL = request.output
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    self.export = export
    startTimer()
    export.exportAsynchronously { [weak self] in
      guard let self else { return }
      self.queue.async {
        guard !self.cancelled else { return }
        if export.status == .completed {
          self.complete(reencoded: false)
        } else {
          self.fail(
            CaptureError.failed(export.error?.localizedDescription ?? "remux failed"))
        }
      }
    }
  }

  // MARK: - Reports

  private func startTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
    timer.setEventHandler { [weak self] in self?.reportProgress() }
    self.timer = timer
    timer.resume()
  }

  private func reportProgress() {
    guard !finished else { return }
    let bytes = fileSize(request.output)
    let duration = Double(request.durationUs) / 1_000_000
    let seconds: Double
    if let export {
      seconds = Double(export.progress) * duration
    } else {
      seconds = max(0, CMTimeGetSeconds(position))
    }
    let positionUs = Int(seconds * 1_000_000)
    emit([
      "job": request.job, "type": "progress", "bytes": bytes,
      "positionUs": positionUs,
      "fraction": duration > 0 ? min(1, seconds / duration) : 0,
    ])
  }

  private func complete(reencoded: Bool) {
    let size = fileSize(request.output)
    end()
    emit([
      "job": request.job, "type": "done", "path": request.output.path, "size": size,
      "durationUs": Int(request.durationUs), "width": request.width,
      "height": request.height, "headerRewritten": true, "reencoded": reencoded,
    ])
  }

  private func fail(_ error: Error) {
    guard !finished else { return }
    reader?.cancelReading()
    writer?.cancelWriting()
    export?.cancelExport()
    end()
    try? FileManager.default.removeItemIfExists(request.output)
    emit(CaptureError.wrap(error).event(job: request.job))
  }

  private func end() {
    guard !finished else { return }
    finished = true
    timer?.cancel()
    timer = nil
    onFinish()
  }
}

/// An `AudioChannelLayout` for mono or stereo, as writer settings take it.
func channelLayout(_ channels: Int) -> Data {
  var layout = AudioChannelLayout()
  layout.mChannelLayoutTag =
    channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
  return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
}

extension FileManager {
  func removeItemIfExists(_ url: URL) throws {
    if fileExists(atPath: url.path) { try removeItem(at: url) }
  }
}
