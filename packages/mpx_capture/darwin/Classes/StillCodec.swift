import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// The still and poster work of media preparation (the Dart
/// `PlatformPreparationCodec`): read a still's facts, encode a JPEG through an
/// ImageIO thumbnail and destination (progressive where asked), and draw a
/// video's first frame. Sizes are as displayed: the stored orientation is
/// applied. Every call blocks; the plugin runs them off the main thread.
enum StillCodec {
  static func probe(path: String) throws -> [String: Any] {
    let (source, info) = try open(path)
    return [
      "width": info.width, "height": info.height,
      "size": fileSize(URL(fileURLWithPath: path)),
      "mime": mimeType(of: source) as Any,
      "animated": CGImageSourceGetCount(source) > 1,
    ]
  }

  static func encode(
    path: String, maxSide: Int, quality: Int, progressive: Bool, output: String?
  ) throws -> [String: Any] {
    let (source, info) = try open(path)
    let target = min(maxSide, max(info.width, info.height))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: target,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { throw CaptureError.failed("cannot decode \(path)") }
    return try write(image, quality: quality, progressive: progressive, output: output)
  }

  static func videoThumbnail(path: String, maxSide: Int, quality: Int) throws -> [String: Any] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxSide, height: maxSide)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .positiveInfinity
    var frame: CGImage?
    var failure: Error?
    let done = DispatchSemaphore(value: 0)
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) {
      _, image, _, _, error in
      frame = image
      failure = error
      done.signal()
    }
    done.wait()
    guard let frame else {
      throw CaptureError.failed(
        "not a video: \(path) (\(failure?.localizedDescription ?? "no frame"))")
    }
    return try write(frame, quality: quality, progressive: false, output: nil)
  }

  // MARK: - Helpers

  private struct Info {
    let width: Int
    let height: Int
  }

  private static func open(_ path: String) throws -> (CGImageSource, Info) {
    let url = URL(fileURLWithPath: path)
    guard
      let source = CGImageSourceCreateWithURL(
        url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetType(source) != nil,
      CGImageSourceGetCount(source) > 0,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0
    else { throw CaptureError.failed("not a still: \(path)") }
    // Orientations 5 to 8 turn the picture a quarter: the displayed sides swap.
    let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
    let turned = orientation >= 5
    return (source, Info(width: turned ? height : width, height: turned ? width : height))
  }

  private static func mimeType(of source: CGImageSource) -> String? {
    guard let type = CGImageSourceGetType(source) else { return nil }
    return UTType(type as String)?.preferredMIMEType
  }

  private static func write(
    _ image: CGImage, quality: Int, progressive: Bool, output: String?
  ) throws -> [String: Any] {
    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: Double(min(max(quality, 1), 100)) / 100,
      kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: progressive],
    ]
    let jpeg = UTType.jpeg.identifier as CFString
    if let output {
      let url = URL(fileURLWithPath: output)
      try FileManager.default.removeItemIfExists(url)
      guard let destination = CGImageDestinationCreateWithURL(url as CFURL, jpeg, 1, nil)
      else { throw CaptureError.failed("cannot write \(output)") }
      CGImageDestinationAddImage(destination, image, properties as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw CaptureError.failed("cannot write \(output)")
      }
      return ["width": image.width, "height": image.height, "size": fileSize(url)]
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, jpeg, 1, nil)
    else { throw CaptureError.failed("cannot encode a JPEG") }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw CaptureError.failed("cannot encode a JPEG")
    }
    return [
      "width": image.width, "height": image.height, "size": data.length,
      "bytes": FlutterStandardTypedData(bytes: data as Data),
    ]
  }
}
