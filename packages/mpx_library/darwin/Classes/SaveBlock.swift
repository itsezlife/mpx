import Foundation

#if MPX_LIBRARY_SAVE
  import Photos
  import UniformTypeIdentifiers
#endif

/// One item of a `saveBlock` call, as the Dart writer sends it (the save
/// block wire in `save_block_codec.dart`).
struct SaveEntry {
  let path: String
  let name: String
  let mime: String
  /// `photo`, `video`, `animation` or `file`: the kind to file it as.
  let kind: String
  let created: Date?
  /// Whether the source may be consumed; the Dart side never sets it for a
  /// cache file.
  let move: Bool

  init?(_ map: Any) {
    guard let map = map as? [String: Any],
      let path = map["path"] as? String,
      let name = map["name"] as? String,
      let mime = map["mime"] as? String,
      let kind = map["kind"] as? String
    else { return nil }
    self.path = path
    self.name = name
    self.mime = mime
    self.kind = kind
    created = (map["createdMs"] as? NSNumber).map {
      Date(timeIntervalSince1970: $0.doubleValue / 1000)
    }
    move = map["move"] as? Bool ?? false
  }

  var url: URL { URL(fileURLWithPath: path) }

  /// Whether Photos keeps it as a video: a video, or an animation that is
  /// a silent loop rather than a GIF.
  var isVideo: Bool {
    kind == "video" || (kind != "photo" && mime.lowercased().hasPrefix("video/"))
  }
}

/// The answer maps of a `saveBlock` call: the whole batch at once, since
/// the block is atomic.
enum SaveAnswer {
  static func saved(_ items: [[String: Any]], album: String? = nil, fallback: String? = nil)
    -> [String: Any]
  {
    var map: [String: Any] = ["outcome": "saved", "items": items]
    map["album"] = album
    map["fallback"] = fallback
    return map
  }

  static func cancelled(fallback: String? = nil) -> [String: Any] {
    var map: [String: Any] = ["outcome": "cancelled"]
    map["fallback"] = fallback
    return map
  }

  /// A failure in the plugin's own terms (`mpx`), or of another domain.
  static func failed(_ domain: String, _ code: String, fallback: String? = nil) -> [String: Any] {
    var map: [String: Any] = ["outcome": "failed", "domain": domain, "code": code]
    map["fallback"] = fallback
    return map
  }

  /// A failure for the platform [error], by its domain and code only: an
  /// error's message can hold a path or a name, which never cross.
  static func failed(_ error: Error?, fallback: String? = nil) -> [String: Any] {
    guard let error = error as NSError? else { return failed("mpx", "unknown", fallback: fallback) }
    let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
    switch error.domain {
    // The Photos domain by name, so this compiles without Photos.
    case "PHPhotosErrorDomain":
      return failed("photos", "\(error.code)", fallback: fallback)
    case NSCocoaErrorDomain:
      // An unknown read or write error says more by its POSIX cause.
      if [NSFileReadUnknownError, NSFileWriteUnknownError].contains(error.code),
        let underlying, underlying.domain == NSPOSIXErrorDomain
      {
        return failed("posix", "\(underlying.code)", fallback: fallback)
      }
      return failed("cocoa", "\(error.code)", fallback: fallback)
    case NSPOSIXErrorDomain:
      return failed("posix", "\(error.code)", fallback: fallback)
    default:
      if let underlying { return failed(underlying, fallback: fallback) }
      return failed("other", "\(error.code)", fallback: fallback)
    }
  }
}

/// Apple's half of `MediaSaver`: one `saveBlock` call writes a whole batch
/// and answers once.
///
/// The gallery is Photos, in one change block ([PhotosSave]), compiled only
/// under the host's `MPX_LIBRARY_SAVE` condition and shared by iOS and
/// macOS. Downloads and the save dialog need no Photos code and are each
/// platform's own (iOS: [FilesSave]).
enum SaveBlock {
  static func run(_ args: [String: Any], done: @escaping ([String: Any]) -> Void) {
    guard let raw = args["entries"] as? [Any] else { return done(SaveAnswer.failed("mpx", "badRequest")) }
    let entries = raw.compactMap(SaveEntry.init)
    guard entries.count == raw.count, !entries.isEmpty else {
      return done(SaveAnswer.failed("mpx", "badRequest"))
    }
    // A source gone before the block begins fails it before any prompt.
    guard entries.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
      return done(SaveAnswer.failed("mpx", "missingSource"))
    }
    switch args["destination"] as? String {
    case "gallery":
      #if MPX_LIBRARY_SAVE
        PhotosSave.write(entries, album: args["album"] as? String, done: done)
      #else
        done(SaveAnswer.failed("mpx", "defineMissing"))
      #endif
    case "downloads":
      #if os(iOS)
        FilesSave.downloads(entries, subfolder: args["subfolder"] as? String, done: done)
      #else
        done(SaveAnswer.failed("mpx", "noAdapter"))
      #endif
    case "ask":
      #if os(iOS)
        FilesSave.export(entries, done: done)
      #else
        done(SaveAnswer.failed("mpx", "noAdapter"))
      #endif
    default:
      done(SaveAnswer.failed("mpx", "badRequest"))
    }
  }
}

#if MPX_LIBRARY_SAVE
  /// A batch into Photos as one change block: one prompt (asked before, by
  /// the save access), and one result for all of it, since Photos commits
  /// the block whole or not at all.
  ///
  /// Each asset is created from the item's file (`addResource(with:fileURL:)`),
  /// with the item's name, its type from the MIME type (a cache file has no
  /// telling extension), and the item's creation date. A GIF animation is a
  /// photo resource, which Photos keeps animated; a video one is a video.
  /// The source is moved only when the Dart side allows it, never for a
  /// cache file: a move consumes the source and fails for a file held open
  /// or hard-linked.
  enum PhotosSave {
    static func write(
      _ entries: [SaveEntry], album: String?, done: @escaping ([String: Any]) -> Void
    ) {
      var albumState: String?
      var albumTitle: String?
      var existingAlbum: PHAssetCollection?
      if let album {
        #if MPX_LIBRARY_PHOTOS
          // Limited access can neither fetch nor make a user album: the
          // assets still go into the library the user let the app add to.
          if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            albumState = "skipped"
          } else {
            albumState = "added"
            albumTitle = album
            existingAlbum = Self.album(titled: album)
          }
        #else
          // The save access answers unavailable first; kept for a stale call.
          return done(SaveAnswer.failed("mpx", "defineMissing"))
        #endif
      }
      let created = Created()
      PHPhotoLibrary.shared().performChanges({
        var placeholders: [PHObjectPlaceholder] = []
        for entry in entries {
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.originalFilename = entry.name
          options.uniformTypeIdentifier = UTType(mimeType: entry.mime)?.identifier
          options.shouldMoveFile = entry.move
          request.addResource(
            with: entry.isVideo ? .video : .photo, fileURL: entry.url, options: options)
          if let date = entry.created { request.creationDate = date }
          if let placeholder = request.placeholderForCreatedAsset {
            placeholders.append(placeholder)
          }
        }
        created.ids = placeholders.map(\.localIdentifier)
        #if MPX_LIBRARY_PHOTOS
          if let albumTitle {
            let change =
              existingAlbum.flatMap { PHAssetCollectionChangeRequest(for: $0) }
              ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(
                withTitle: albumTitle)
            change.addAssets(placeholders as NSArray)
          }
        #endif
      }) { success, error in
        guard success, created.ids.count == entries.count else {
          return done(SaveAnswer.failed(error))
        }
        done(
          SaveAnswer.saved(
            created.ids.map { ["ref": $0, "renamed": false] }, album: albumState))
      }
    }

    /// The ids of the assets a change block made, read after it commits.
    private final class Created { var ids: [String] = [] }

    #if MPX_LIBRARY_PHOTOS
      private static func album(titled title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        options.fetchLimit = 1
        return PHAssetCollection.fetchAssetCollections(
          with: .album, subtype: .albumRegular, options: options
        ).firstObject
      }
    #endif
  }
#endif
