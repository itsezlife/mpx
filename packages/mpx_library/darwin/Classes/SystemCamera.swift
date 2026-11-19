import Foundation

#if MPX_LIBRARY_CAMERA && os(iOS)
  import UIKit
  import UniformTypeIdentifiers

  /// The system camera intake on iOS: a `UIImagePickerController` camera
  /// writing the photo (a JPEG) or the video into a temporary file.
  /// Compiled only under the host's `MPX_LIBRARY_CAMERA` condition; the host
  /// then adds the camera usage string.
  final class SystemCamera: NSObject, UIImagePickerControllerDelegate,
    UINavigationControllerDelegate
  {
    private var done: (([String: Any]?) -> Void)?

    static var available: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func capture(kind: String, from controller: UIViewController, _ done: @escaping ([String: Any]?) -> Void) {
      guard self.done == nil, Self.available else { return done(nil) }
      self.done = done
      let picker = UIImagePickerController()
      picker.sourceType = .camera
      picker.mediaTypes = [kind == "video" ? UTType.movie.identifier : UTType.image.identifier]
      picker.delegate = self
      controller.present(picker, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      picker.dismiss(animated: true)
      finish(nil)
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      picker.dismiss(animated: true)
      let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "mpx_library_camera", isDirectory: true)
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let stamp = Int(Date().timeIntervalSince1970 * 1000)
      if let movie = info[.mediaURL] as? URL {
        let url = folder.appendingPathComponent("camera-\(stamp).\(movie.pathExtension)")
        do {
          try FileManager.default.copyItem(at: movie, to: url)
          return finish(Self.facts(url, mime: "video/quicktime"))
        } catch {
          return finish(nil)
        }
      }
      guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9)
      else { return finish(nil) }
      let url = folder.appendingPathComponent("camera-\(stamp).jpg")
      do {
        try data.write(to: url)
        finish(Self.facts(url, mime: "image/jpeg"))
      } catch {
        finish(nil)
      }
    }

    private func finish(_ facts: [String: Any]?) {
      let answer = done
      done = nil
      answer?(facts)
    }

    private static func facts(_ url: URL, mime: String) -> [String: Any] {
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
      let modified = (attributes?[.modificationDate] as? Date) ?? Date()
      return [
        "path": url.path, "name": url.lastPathComponent, "size": size, "mime": mime,
        "modifiedMs": Int(modified.timeIntervalSince1970 * 1000),
      ]
    }
  }
#endif
