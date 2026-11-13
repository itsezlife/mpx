import Foundation

/// The reader functions of `http_bytes_cache`'s native library, reached
/// through the `hbc_api` function table whose address the Dart side hands
/// over. Nothing links that library by name or path, so this works the same
/// whether it lands as a framework or inside the app binary.
///
/// The table's layout mirrors `native/include/http_bytes_cache.h` of
/// `http_bytes_cache` (a published plugin cannot include a sibling
/// package's header): an `int32_t` version, then six function pointers. A
/// table of another version is refused rather than misread.
final class HbcReaderApi {
  typealias Reader = OpaquePointer

  private typealias OpenFn = @convention(c) (UnsafePointer<CChar>?) -> Reader?
  private typealias LengthFn = @convention(c) (Reader?, Int32) -> Int64
  private typealias ReadFn =
    @convention(c) (Reader?, Int64, UnsafeMutablePointer<UInt8>?, Int64) -> Int64
  private typealias PriorityFn = @convention(c) (Reader?, Int32) -> Void
  private typealias ReaderFn = @convention(c) (Reader?) -> Void

  /// The `HBC_ABI_VERSION` this layout matches.
  static let abiVersion: Int32 = 2

  /// `HBC_ERR_CANCELLED`: `cancel` woke the read.
  static let errCancelled: Int64 = -1

  private let openFn: OpenFn
  private let lengthFn: LengthFn
  private let readFn: ReadFn
  private let priorityFn: PriorityFn
  private let cancelFn: ReaderFn
  private let closeFn: ReaderFn

  /// The table at [address], or nil when there is none or it speaks another
  /// version.
  init?(address: Int64) {
    guard let base = UnsafeRawPointer(bitPattern: Int(address)),
      base.load(as: Int32.self) == HbcReaderApi.abiVersion
    else { return nil }
    // The pointers follow the version at pointer alignment.
    let stride = MemoryLayout<UnsafeRawPointer>.stride
    func slot(_ index: Int) -> UnsafeRawPointer {
      base.load(fromByteOffset: stride * (index + 1), as: UnsafeRawPointer.self)
    }
    openFn = unsafeBitCast(slot(0), to: OpenFn.self)
    lengthFn = unsafeBitCast(slot(1), to: LengthFn.self)
    readFn = unsafeBitCast(slot(2), to: ReadFn.self)
    priorityFn = unsafeBitCast(slot(3), to: PriorityFn.self)
    cancelFn = unsafeBitCast(slot(4), to: ReaderFn.self)
    closeFn = unsafeBitCast(slot(5), to: ReaderFn.self)
  }

  /// A reader of the published resource [key], or nil when it is not
  /// published.
  func open(_ key: String) -> Reader? { key.withCString { openFn($0) } }

  /// The resource's length; blocks until it is known. Negative on failure.
  func length(_ reader: Reader) -> Int64 { lengthFn(reader, 1) }

  /// Reads up to [count] bytes at [offset]; blocks while they are missing.
  /// The count read, 0 at the end, or a negative `HBC_ERR_*` code.
  func read(
    _ reader: Reader, at offset: Int64, into buffer: UnsafeMutablePointer<UInt8>,
    count: Int64
  ) -> Int64 {
    readFn(reader, offset, buffer, count)
  }

  /// Sets the priority the reader's fetches ask at (0 background, 1
  /// preload, 2 visible).
  func setPriority(_ reader: Reader, _ priority: Int32) { priorityFn(reader, priority) }

  /// Wakes the reads blocked on [reader] now. Any thread; not sticky.
  func cancel(_ reader: Reader) { cancelFn(reader) }

  /// Closes [reader]; no call on it may run or follow.
  func close(_ reader: Reader) { closeFn(reader) }
}
