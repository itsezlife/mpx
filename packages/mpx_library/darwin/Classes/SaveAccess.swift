import Foundation

#if MPX_LIBRARY_SAVE
  import Photos
#endif

/// The access saving needs on Apple, answered as the Dart side's save
/// access map (`scope`, `status`, `missing`).
///
/// Only the gallery asks for anything: add-only access to Photos, a grant
/// that reads nothing, or read and write access for a named album (an
/// album is found or made by fetching, which add-only access cannot do,
/// and limited access can neither fetch nor make user albums). Downloads
/// and the save dialog need no Photos access.
///
/// The Photos calls compile only under the host's `MPX_LIBRARY_SAVE`
/// condition, and the album's read and write access only beside
/// `MPX_LIBRARY_PHOTOS` (README); without them the gallery answers
/// `unavailable` with the missing define, so a host that saves nothing links
/// no Photos code, and one that only saves links no library reading.
enum SaveAccess {
  static func answer(destination: String, album: Bool) -> [String: Any] {
    guard destination == "gallery" else { return ["scope": "none", "status": "authorized"] }
    let scope = album ? "readWrite" : "addOnly"
    #if MPX_LIBRARY_SAVE
      if album && !libraryBuilt {
        return ["scope": scope, "status": "unavailable", "missing": "MPX_LIBRARY_PHOTOS"]
      }
      return [
        "scope": scope,
        "status": status(PHPhotoLibrary.authorizationStatus(for: level(album: album))),
      ]
    #else
      return ["scope": scope, "status": "unavailable", "missing": "MPX_LIBRARY_SAVE"]
    #endif
  }

  /// Shows the system prompt when not asked yet; answers the access after,
  /// on any thread.
  static func request(
    destination: String, album: Bool, _ done: @escaping ([String: Any]) -> Void
  ) {
    let now = answer(destination: destination, album: album)
    guard now["status"] as? String == "notDetermined" else { return done(now) }
    #if MPX_LIBRARY_SAVE
      PHPhotoLibrary.requestAuthorization(for: level(album: album)) { _ in
        done(answer(destination: destination, album: album))
      }
    #else
      done(now)
    #endif
  }

  /// Whether the host compiled the library's read code, which a named
  /// album needs.
  private static var libraryBuilt: Bool {
    #if MPX_LIBRARY_PHOTOS
      return true
    #else
      return false
    #endif
  }

  #if MPX_LIBRARY_SAVE
    private static func level(album: Bool) -> PHAccessLevel {
      album ? .readWrite : .addOnly
    }

    private static func status(_ status: PHAuthorizationStatus) -> String {
      switch status {
      case .notDetermined: return "notDetermined"
      case .denied: return "denied"
      case .limited: return "limited"
      case .authorized: return "authorized"
      case .restricted: return "restricted"
      @unknown default: return "restricted"
      }
    }
  #endif
}
