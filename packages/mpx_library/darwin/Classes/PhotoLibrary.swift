import Foundation

#if os(iOS)
  import Flutter
  import UIKit
#endif

#if MPX_LIBRARY_PHOTOS && os(iOS)
  import AVFoundation
  import Photos
  import PhotosUI
  import UniformTypeIdentifiers

  /// The device library over PhotoKit (the Dart `PlatformMediaLibrary`, the
  /// wire of `LibraryWire`). Compiled only under the host's
  /// `MPX_LIBRARY_PHOTOS` condition.
  ///
  /// Album ids: `recents` (newest first), else the collection's local
  /// identifier (oldest first, `startsAtEnd`). Fetch results are kept per
  /// album so changes come out as PhotoKit's change details. The change
  /// observer is registered only once access allows reading.
  final class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    var emit: ([String: Any]) -> Void = { _ in }

    private let queue = DispatchQueue(label: "dev.mpx.library.photos", attributes: .concurrent)
    private let lock = NSLock()
    private var fetches: [String: PHFetchResult<PHAsset>] = [:]
    private var observing = false
    private var downloads: [Int: PHAssetResourceDataRequestID] = [:]

    // MARK: - Access

    static func status() -> String {
      switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
      case .notDetermined: return "notDetermined"
      case .denied: return "denied"
      case .limited: return "limited"
      case .authorized: return "authorized"
      default: return "restricted"
      }
    }

    func access() -> [String: Any] {
      let map: [String: Any] = ["platform": "apple", "status": Self.status()]
      observeWhenReadable()
      return map
    }

    func requestAccess(_ done: @escaping ([String: Any]) -> Void) {
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
        done(self.access())
      }
    }

    func manageSelected(_ done: @escaping () -> Void) {
      guard let controller = topController() else { return done() }
      PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in done() }
    }

    private func observeWhenReadable() {
      let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
      guard status == .authorized || status == .limited else { return }
      lock.lock()
      defer { lock.unlock() }
      guard !observing else { return }
      observing = true
      PHPhotoLibrary.shared().register(self)
    }

    func stopObserving() {
      lock.lock()
      defer { lock.unlock() }
      guard observing else { return }
      observing = false
      PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - Albums

    private static let smartAlbums: [PHAssetCollectionSubtype] = [
      .smartAlbumBursts, .smartAlbumPanoramas, .smartAlbumScreenshots, .smartAlbumSelfPortraits,
      .smartAlbumSlomoVideos, .smartAlbumTimelapses, .smartAlbumVideos, .smartAlbumAnimated,
      .smartAlbumDepthEffect, .smartAlbumLivePhotos,
    ]

    private static var assetOptions: PHFetchOptions {
      let options = PHFetchOptions()
      options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
      options.predicate = NSPredicate(
        format: "mediaType == %d || mediaType == %d", PHAssetMediaType.image.rawValue,
        PHAssetMediaType.video.rawValue)
      return options
    }

    func albums() -> [[String: Any]] {
      var result: [[String: Any]] = []
      func add(_ collection: PHAssetCollection?, id: String, kind: String, keepEmpty: Bool) {
        guard let collection else { return }
        let assets = PHAsset.fetchAssets(in: collection, options: Self.assetOptions)
        guard keepEmpty || assets.count > 0 else { return }
        store(assets, for: id)
        var album: [String: Any] = [
          "id": id, "kind": kind, "title": collection.localizedTitle ?? "",
          "count": assets.count, "startsAtEnd": id != "recents",
        ]
        if let cover = assets.lastObject { album["cover"] = Self.map(cover) }
        result.append(album)
      }
      func smart(_ subtype: PHAssetCollectionSubtype) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil)
          .firstObject
      }
      add(smart(.smartAlbumUserLibrary), id: "recents", kind: "allMedia", keepEmpty: true)
      if let favourites = smart(.smartAlbumFavorites) {
        add(favourites, id: favourites.localIdentifier, kind: "favourites", keepEmpty: false)
      }
      for subtype in Self.smartAlbums {
        if let collection = smart(subtype) {
          add(collection, id: collection.localIdentifier, kind: "system", keepEmpty: false)
        }
      }
      let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
      var users: [PHAssetCollection] = []
      user.enumerateObjects { collection, _, _ in users.append(collection) }
      for collection in users.reversed() {
        add(collection, id: collection.localIdentifier, kind: "user", keepEmpty: false)
      }
      return result
    }

    // MARK: - Pages

    func page(album: String, offset: Int, limit: Int) -> [String: Any] {
      guard let assets = fetch(album) else { return ["total": 0, "assets": [] as [Any]] }
      let total = assets.count
      var page: [[String: Any]] = []
      if offset < total {
        let end = min(total, offset + limit)
        for index in offset..<end {
          // Recents runs newest first; other albums keep PhotoKit's order.
          let asset = assets.object(at: album == "recents" ? total - 1 - index : index)
          page.append(Self.map(asset))
        }
      }
      return ["total": total, "assets": page]
    }

    private func fetch(_ album: String) -> PHFetchResult<PHAsset>? {
      lock.lock()
      if let cached = fetches[album] {
        lock.unlock()
        return cached
      }
      lock.unlock()
      let collection: PHAssetCollection?
      if album == "recents" {
        collection = PHAssetCollection.fetchAssetCollections(
          with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil
        ).firstObject
      } else {
        collection = PHAssetCollection.fetchAssetCollections(
          withLocalIdentifiers: [album], options: nil
        ).firstObject
      }
      guard let collection else { return nil }
      let assets = PHAsset.fetchAssets(in: collection, options: Self.assetOptions)
      store(assets, for: album)
      return assets
    }

    private func store(_ assets: PHFetchResult<PHAsset>, for album: String) {
      lock.lock()
      fetches[album] = assets
      lock.unlock()
    }

    static func map(_ asset: PHAsset) -> [String: Any] {
      var subtypes: [String] = []
      if asset.mediaSubtypes.contains(.photoLive) { subtypes.append("live") }
      if asset.mediaSubtypes.contains(.videoHighFrameRate) { subtypes.append("slowMotion") }
      if asset.mediaSubtypes.contains(.videoTimelapse) { subtypes.append("timeLapse") }
      if asset.mediaSubtypes.contains(.photoScreenshot) { subtypes.append("screenshot") }
      if asset.isFavorite { subtypes.append("favourite") }
      if asset.playbackStyle == .imageAnimated { subtypes.append("animated") }
      var map: [String: Any] = [
        "id": asset.localIdentifier,
        "kind": asset.mediaType == .video ? "video" : "photo",
        "subtypes": subtypes,
        "width": asset.pixelWidth,
        "height": asset.pixelHeight,
        "cloud": false,
      ]
      if asset.mediaType == .video { map["durationMs"] = Int(asset.duration * 1000) }
      if let created = asset.creationDate {
        map["createdMs"] = Int(created.timeIntervalSince1970 * 1000)
      }
      if let modified = asset.modificationDate {
        map["modifiedMs"] = Int(modified.timeIntervalSince1970 * 1000)
      }
      return map
    }

    // MARK: - Reads

    private func asset(_ id: String) -> PHAsset? {
      PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    /// The thumbnail fitted into `pixels`, opportunistic with network on
    /// demand; the final (not degraded) image is answered, as a JPEG.
    func thumbnail(id: String, pixels: Int, _ done: @escaping (Result<Data, LibraryError>) -> Void) {
      guard let asset = asset(id) else { return done(.failure(.unavailable("no asset \(id)"))) }
      let options = PHImageRequestOptions()
      options.deliveryMode = .opportunistic
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = true
      var answered = false
      PHImageManager.default().requestImage(
        for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFit,
        options: options
      ) { image, info in
        let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
        guard !answered, !degraded || image == nil else { return }
        answered = true
        guard let data = image?.jpegData(compressionQuality: 0.85) else {
          return done(.failure(.unavailable("no thumbnail for \(id)")))
        }
        done(.success(data))
      }
    }

    /// Writes the asset's original resource into a temporary file, reporting
    /// an iCloud download through `progress` (thousandths).
    func original(
      id: String, request: Int, progress: @escaping (Int) -> Void,
      _ done: @escaping (Result<[String: Any], LibraryError>) -> Void
    ) {
      guard let asset = asset(id) else { return done(.failure(.unavailable("no asset \(id)"))) }
      let resources = PHAssetResource.assetResources(for: asset)
      let preferred: [PHAssetResourceType] =
        asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
      guard
        let resource = preferred.lazy.compactMap({ type in resources.first { $0.type == type } })
          .first ?? resources.first
      else { return done(.failure(.unavailable("no resource for \(id)"))) }
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mpx_library_originals", isDirectory: true)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appendingPathComponent("\(UUID().uuidString)-\(resource.originalFilename)")
      FileManager.default.createFile(atPath: url.path, contents: nil)
      guard let handle = try? FileHandle(forWritingTo: url) else {
        return done(.failure(.unavailable("cannot write \(url.path)")))
      }
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = true
      options.progressHandler = { fraction in progress(Int(fraction * 1000)) }
      let requestId = PHAssetResourceManager.default().requestData(
        for: resource, options: options,
        dataReceivedHandler: { data in handle.write(data) },
        completionHandler: { error in
          try? handle.close()
          self.lock.lock()
          self.downloads.removeValue(forKey: request)
          self.lock.unlock()
          if let error {
            try? FileManager.default.removeItem(at: url)
            let cancelled = (error as NSError).code == NSUserCancelledError
            return done(
              .failure(cancelled ? .unavailable("cancelled") : .download(error.localizedDescription)))
          }
          done(.success(["path": url.path, "mime": Self.mime(of: resource) as Any]))
        })
      lock.lock()
      downloads[request] = requestId
      lock.unlock()
    }

    /// The file URL of video `id`'s original, which a player reads in
    /// place (a cloud-held one downloads first); nil for a photo, or a
    /// video PhotoKit hands over as a composition and not as a file.
    func playable(id: String, _ done: @escaping (String?) -> Void) {
      guard let asset = asset(id), asset.mediaType == .video else { return done(nil) }
      let options = PHVideoRequestOptions()
      options.isNetworkAccessAllowed = true
      options.version = .original
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { video, _, _ in
        done((video as? AVURLAsset)?.url.absoluteString)
      }
    }

    func cancelOriginal(request: Int) {
      lock.lock()
      let id = downloads.removeValue(forKey: request)
      lock.unlock()
      if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    private static func mime(of resource: PHAssetResource) -> String? {
      UTType(resource.uniformTypeIdentifier)?.preferredMIMEType
    }

    // MARK: - Changes

    func photoLibraryDidChange(_ change: PHChange) {
      lock.lock()
      let current = fetches
      lock.unlock()
      for (album, assets) in current {
        guard let details = change.changeDetails(for: assets) else { continue }
        store(details.fetchResultAfterChanges, for: album)
        guard details.hasIncrementalChanges else {
          emit(["type": "changed", "album": album])
          continue
        }
        emit([
          "type": "changed", "album": album,
          "inserted": details.insertedObjects.map(\.localIdentifier),
          "removed": details.removedObjects.map(\.localIdentifier),
          "changed": details.changedObjects.map(\.localIdentifier),
        ])
      }
    }

    private func topController() -> UIViewController? {
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }
      var controller = window?.rootViewController
      while let presented = controller?.presentedViewController { controller = presented }
      return controller
    }
  }
#endif

/// Errors that cross the channel; the code picks the Dart exception.
enum LibraryError: Error {
  case unavailable(String)
  case download(String)

  var code: String {
    switch self {
    case .unavailable: return "unavailable"
    case .download: return "download"
    }
  }

  var message: String {
    switch self {
    case .unavailable(let message), .download(let message): return message
    }
  }

  #if os(iOS)
    var flutter: FlutterError { FlutterError(code: code, message: message, details: nil) }
  #endif
}
