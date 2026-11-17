import AVFoundation
import CoreGraphics
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// The platform's still extractor (`PlayerStillHostApi`): the first frame of
/// a video drawn by an asset image generator, which uses the system's
/// decoders (hardware ones included), for codecs the software decoder was
/// built without.
///
/// A ranged resource is read through the bytes cache's native reader by the
/// player's resource loader; a file is opened in place. The track's
/// transform is applied, and the frame is scaled into the request's box. A
/// cancel wakes the loader's blocked reads and cancels the generation; the
/// request then answers nil. A request that runs past its deadline is
/// cancelled the same way, so bytes that never arrive do not hold it for
/// good.
///
/// Every call is answered exactly once: a request still running at
/// `dispose`, and a call after it, answer nil.
final class MpxStillExtractor: PlayerStillHostApi {
  private struct Running {
    let generator: AVAssetImageGenerator
    let loader: MpxResourceLoader?
  }

  private final class Pending {
    let completion: (Result<NativeStill?, Error>) -> Void
    var cancelled = false
    var running: Running?

    init(completion: @escaping (Result<NativeStill?, Error>) -> Void) {
      self.completion = completion
    }
  }

  // How long a still may take before it is cancelled.
  private static let deadline: TimeInterval = 20

  private let lock = NSLock()
  // Every request from its call until its answer, by id. A cancel of an id
  // not here (finished, or never asked) is a no-op, so nothing outlives it.
  private var pending: [Int64: Pending] = [:]
  private var disposed = false

  func extractStill(
    request: NativeStillRequest,
    completion: @escaping (Result<NativeStill?, Error>) -> Void
  ) {
    let id = request.requestId
    lock.lock()
    let taken = !disposed && pending[id] == nil
    let job = Pending(completion: completion)
    if taken { pending[id] = job }
    lock.unlock()
    guard taken else {
      DispatchQueue.main.async { completion(.success(nil)) }
      return
    }
    let answer: (NativeStill?) -> Void = { still in self.answer(id, still) }
    guard let (asset, loader) = MpxStillExtractor.asset(of: request) else {
      answer(nil)
      return
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(
      width: CGFloat(max(1, request.maxWidth)), height: CGFloat(max(1, request.maxHeight)))
    // The nearest sync frame: decoding up to an exact time costs more.
    generator.requestedTimeToleranceBefore = .positiveInfinity
    generator.requestedTimeToleranceAfter = .positiveInfinity
    lock.lock()
    let isCancelled = job.cancelled
    if !isCancelled { job.running = Running(generator: generator, loader: loader) }
    lock.unlock()
    if isCancelled {
      loader?.close()
      answer(nil)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + MpxStillExtractor.deadline) {
      [weak self] in
      try? self?.cancelStill(requestId: id)
    }
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) {
      _, image, _, result, _ in
      loader?.close()
      guard result == .succeeded, let image else {
        answer(nil)
        return
      }
      answer(MpxStillExtractor.still(of: image, request: request))
    }
  }

  func cancelStill(requestId: Int64) throws {
    lock.lock()
    let job = pending[requestId]
    job?.cancelled = true
    let running = job?.running
    lock.unlock()
    running?.loader?.close()
    running?.generator.cancelAllCGImageGeneration()
  }

  /// Stops taking requests: the running ones are cancelled and answer nil
  /// now, and later calls answer nil.
  func dispose() {
    lock.lock()
    disposed = true
    let ids = Array(pending.keys)
    lock.unlock()
    for id in ids {
      try? cancelStill(requestId: id)
      answer(id, nil)
    }
  }

  // Answers request [id] once; a later answer (a dispose raced a finish)
  // finds it gone.
  private func answer(_ id: Int64, _ still: NativeStill?) {
    lock.lock()
    let job = pending.removeValue(forKey: id)
    lock.unlock()
    guard let job else { return }
    DispatchQueue.main.async { job.completion(.success(still)) }
  }

  // The asset of the request's source, and the loader serving it when it is
  // read through the native reader.
  private static func asset(of request: NativeStillRequest) -> (AVURLAsset, MpxResourceLoader?)? {
    if let path = request.path {
      return (AVURLAsset(url: URL(fileURLWithPath: path)), nil)
    }
    guard let key = request.cacheKey, let address = request.readerApi,
      let api = HbcReaderApi(address: address),
      let url = MpxResourceLoader.url(forKey: key)
    else { return nil }
    // A still's request names no container: the MP4 family the asset image
    // generator draws from.
    let loader = MpxResourceLoader(api: api, key: key, mimeType: "video/mp4", traceId: 0)
    let asset = AVURLAsset(url: url)
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    return (asset, loader)
  }

  // Draws [image] into premultiplied RGBA bytes, scaled into the box (the
  // generator's maximum size is a bound it may not meet exactly).
  private static func still(of image: CGImage, request: NativeStillRequest) -> NativeStill? {
    let scale = min(
      1, min(
        Double(request.maxWidth) / Double(image.width),
        Double(request.maxHeight) / Double(image.height)))
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    let rowBytes = width * 4
    var pixels = Data(count: rowBytes * height)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: rowBytes, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.interpolationQuality = .medium
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drawn else { return nil }
    return NativeStill(
      width: Int64(width), height: Int64(height), rgba: FlutterStandardTypedData(bytes: pixels))
  }
}
