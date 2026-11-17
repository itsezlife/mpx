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
/// request then answers nil.
final class MpxStillExtractor: PlayerStillHostApi {
  private struct Running {
    let generator: AVAssetImageGenerator
    let loader: MpxResourceLoader?
  }

  private let lock = NSLock()
  private var running: [Int64: Running] = [:]
  private var cancelled: Set<Int64> = []

  func extractStill(
    request: NativeStillRequest,
    completion: @escaping (Result<NativeStill?, Error>) -> Void
  ) {
    let id = request.requestId
    let answer: (NativeStill?) -> Void = { [weak self] still in
      self?.finish(id)
      DispatchQueue.main.async { completion(.success(still)) }
    }
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
    let isCancelled = cancelled.contains(id)
    if !isCancelled { running[id] = Running(generator: generator, loader: loader) }
    lock.unlock()
    if isCancelled {
      loader?.close()
      answer(nil)
      return
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
    cancelled.insert(requestId)
    let job = running[requestId]
    lock.unlock()
    job?.loader?.close()
    job?.generator.cancelAllCGImageGeneration()
  }

  private func finish(_ id: Int64) {
    lock.lock()
    running[id] = nil
    cancelled.remove(id)
    lock.unlock()
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
    let loader = MpxResourceLoader(
      api: api, key: key, mimeType: request.mimeType ?? "video/mp4", traceId: 0)
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
