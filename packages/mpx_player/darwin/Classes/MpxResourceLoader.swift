import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Serves one asset's bytes to AVFoundation from the bytes cache's native
/// reader: AVPlayer asks for byte ranges on a custom URL scheme, and each
/// request is answered from the cached sparse file, blocking (on a reader
/// queue, never the delegate's) only while bytes are missing.
///
/// Progressive containers only: AVPlayer refuses HLS segment bytes a
/// resource loader serves itself, so HLS is not routed here.
final class MpxResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
  /// The custom scheme AVFoundation sends to this delegate.
  static let scheme = "mpx-hbc"

  /// The URL an asset of cache key [key] opens.
  static func url(forKey key: String) -> URL? {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#")
    guard let path = key.addingPercentEncoding(withAllowedCharacters: allowed) else {
      return nil
    }
    return URL(string: "\(scheme)://media/\(path)")
  }

  /// The queue AVFoundation calls the delegate on; every answer to a request
  /// goes through it too, in order.
  let queue = DispatchQueue(label: "dev.mpx.player.loader")

  private let api: HbcReaderApi
  private let key: String
  private let contentType: String
  // The player whose marks the requests make (MpxPlayerTrace).
  private let traceId: Int64
  // Blocking reads, one per open request; concurrent so a seek's request
  // does not wait behind a read blocked on bytes that are still coming.
  private let readQueue = DispatchQueue(
    label: "dev.mpx.player.reader", attributes: .concurrent)
  private let lock = NSLock()
  private var readers: [ObjectIdentifier: HbcReaderApi.Reader] = [:]
  private var cancelled: Set<ObjectIdentifier> = []
  private var closed = false

  init(api: HbcReaderApi, key: String, mimeType: String, traceId: Int64) {
    self.api = api
    self.key = key
    self.traceId = traceId
    contentType = UTType(mimeType: mimeType)?.identifier ?? UTType.mpeg4Movie.identifier
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
  ) -> Bool {
    let id = ObjectIdentifier(loadingRequest)
    MpxPlayerTrace.mark(
      "source-open", traceId, "at=\(loadingRequest.dataRequest?.requestedOffset ?? -1)")
    lock.lock()
    let reader = closed ? nil : api.open(key)
    if let reader { readers[id] = reader }
    lock.unlock()
    guard let reader else {
      loadingRequest.finishLoading(with: MpxResourceLoader.error("not published: \(key)"))
      return true
    }
    readQueue.async { [weak self] in self?.serve(loadingRequest, id: id, reader: reader) }
    return true
  }

  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    didCancel loadingRequest: AVAssetResourceLoadingRequest
  ) {
    cancel(ObjectIdentifier(loadingRequest))
  }

  /// Wakes every blocked read and refuses new requests: the player goes.
  func close() {
    lock.lock()
    closed = true
    for (id, reader) in readers {
      cancelled.insert(id)
      api.cancel(reader)
    }
    lock.unlock()
  }

  private func cancel(_ id: ObjectIdentifier) {
    lock.lock()
    if let reader = readers[id] {
      cancelled.insert(id)
      api.cancel(reader)
    }
    lock.unlock()
  }

  private func isCancelled(_ id: ObjectIdentifier) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled.contains(id)
  }

  private func serve(
    _ request: AVAssetResourceLoadingRequest, id: ObjectIdentifier,
    reader: HbcReaderApi.Reader
  ) {
    let failure = answer(request, id: id, reader: reader)
    lock.lock()
    readers[id] = nil
    let wasCancelled = cancelled.remove(id) != nil
    // Unregistered under the lock, so no cancel can reach the reader while
    // it closes.
    api.close(reader)
    lock.unlock()
    if wasCancelled { return }
    queue.async {
      if let failure {
        request.finishLoading(with: failure)
      } else {
        request.finishLoading()
      }
    }
  }

  // Fills the content information and the data the request asks for;
  // returns the error to finish with, or nil.
  private func answer(
    _ request: AVAssetResourceLoadingRequest, id: ObjectIdentifier,
    reader: HbcReaderApi.Reader
  ) -> Error? {
    var length: Int64 = -1
    if let info = request.contentInformationRequest {
      length = api.length(reader)
      if length < 0 { return MpxResourceLoader.error("no length (\(length))") }
      let type = contentType
      queue.sync {
        info.contentType = type
        info.contentLength = length
        info.isByteRangeAccessSupported = true
      }
    }
    guard let data = request.dataRequest else { return nil }
    var offset = data.requestedOffset
    let end: Int64
    if data.requestsAllDataToEndOfResource {
      if length < 0 { length = api.length(reader) }
      if length < 0 { return MpxResourceLoader.error("no length (\(length))") }
      end = length
    } else {
      end = data.requestedOffset + Int64(data.requestedLength)
    }
    let chunk = 256 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
    defer { buffer.deallocate() }
    var first = true
    while offset < end {
      if isCancelled(id) { return nil }
      let count = api.read(reader, at: offset, into: buffer, count: min(Int64(chunk), end - offset))
      if count == 0 { break }
      if count < 0 {
        return count == HbcReaderApi.errCancelled
          ? nil : MpxResourceLoader.error("read failed (\(count)) at \(offset)")
      }
      if first {
        first = false
        MpxPlayerTrace.mark("source-first-read", traceId, "at=\(offset)")
      }
      let bytes = Data(bytes: buffer, count: Int(count))
      queue.async { data.respond(with: bytes) }
      offset += count
    }
    return nil
  }

  private static func error(_ message: String) -> NSError {
    NSError(
      domain: "dev.mpx.player", code: -1,
      userInfo: [NSLocalizedDescriptionKey: "Bytes cache reader: \(message)"])
  }
}
