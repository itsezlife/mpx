#if os(iOS)
  import Foundation
  import UIKit

  /// Downloads and the save dialog on iOS: the app's Documents, which the
  /// system's file browser shows, and the system's export picker. Neither
  /// needs Photos or any access.
  enum FilesSave {
    /// Whether the system's file browser shows the app's Documents: the
    /// host declares both keys in its Info.plist.
    static var sharesDocuments: Bool {
      let info = Bundle.main
      return info.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool == true
        && info.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace") as? Bool == true
    }

    /// Copies (or, when allowed, moves) the batch into Documents, in the
    /// host's [subfolder]; a taken name becomes `name (1)`. Atomic as the
    /// gallery is: a failure takes back every file the batch placed, so a
    /// failed batch leaves nothing behind. Without file sharing the batch
    /// goes to the export picker.
    static func downloads(
      _ entries: [SaveEntry], subfolder: String?, done: @escaping ([String: Any]) -> Void
    ) {
      guard sharesDocuments else { return export(entries, fallback: "noFileSharing", done: done) }
      DispatchQueue.global(qos: .userInitiated).async {
        let files = FileManager.default
        var placed: [(target: URL, movedFrom: URL?)] = []
        do {
          var folder = try files.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
          if let subfolder, case let name = safeName(subfolder, fallback: ""), !name.isEmpty {
            folder.appendPathComponent(name, isDirectory: true)
          }
          try files.createDirectory(at: folder, withIntermediateDirectories: true)
          var items: [[String: Any]] = []
          for entry in entries {
            let (target, renamed) = freeName(in: folder, for: entry.name)
            if entry.move {
              try files.moveItem(at: entry.url, to: target)
              placed.append((target, entry.url))
            } else {
              try files.copyItem(at: entry.url, to: target)
              placed.append((target, nil))
            }
            if let date = entry.created {
              try? files.setAttributes(
                [.creationDate: date, .modificationDate: date], ofItemAtPath: target.path)
            }
            items.append(["ref": target.path, "renamed": renamed])
          }
          done(SaveAnswer.saved(items))
        } catch {
          for file in placed {
            if let source = file.movedFrom {
              try? files.moveItem(at: file.target, to: source)
            } else {
              try? files.removeItem(at: file.target)
            }
          }
          done(SaveAnswer.failed(error))
        }
      }
    }

    /// Shows the export picker over the whole batch. The files are first
    /// copied under the items' names into a temporary folder, because the
    /// picker names each export after its file and a cache file's name is
    /// not the item's; the picker exports copies and the folder is removed
    /// after. The source is never consumed here. A dismissed picker
    /// cancels every item.
    static func export(
      _ entries: [SaveEntry], fallback: String? = nil, done: @escaping ([String: Any]) -> Void
    ) {
      DispatchQueue.global(qos: .userInitiated).async {
        let files = FileManager.default
        let folder = files.temporaryDirectory
          .appendingPathComponent("mpx_library_save", isDirectory: true)
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cleanUp = { try? files.removeItem(at: folder) }
        var urls: [URL] = []
        do {
          try files.createDirectory(at: folder, withIntermediateDirectories: true)
          for entry in entries {
            let (target, _) = freeName(in: folder, for: entry.name)
            try files.copyItem(at: entry.url, to: target)
            urls.append(target)
          }
        } catch {
          cleanUp()
          return done(SaveAnswer.failed(error, fallback: fallback))
        }
        DispatchQueue.main.async {
          guard let presenter = MpxLibraryPlugin.topController() else {
            cleanUp()
            return done(SaveAnswer.failed("mpx", "noPresenter", fallback: fallback))
          }
          let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
          let delegate = ExportDelegate { picked in
            cleanUp()
            guard let picked else { return done(SaveAnswer.cancelled(fallback: fallback)) }
            done(
              SaveAnswer.saved(
                picked.map { ["ref": $0.path, "renamed": false] }, fallback: fallback))
          }
          picker.delegate = delegate
          delegate.retain(by: picker)
          presenter.present(picker, animated: true)
        }
      }
    }

    /// [name] made safe as one path component: no separators, never empty.
    static func safeName(_ name: String, fallback: String = "file") -> String {
      let cleaned = name.replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
    }

    /// A name in [folder] no file has yet: [name] itself, else
    /// `name (1).ext`, `name (2).ext`, and on; true when renamed.
    static func freeName(in folder: URL, for name: String) -> (URL, Bool) {
      let files = FileManager.default
      let safe = safeName(name)
      let first = folder.appendingPathComponent(safe)
      if !files.fileExists(atPath: first.path) { return (first, false) }
      let ext = (safe as NSString).pathExtension
      let base = (safe as NSString).deletingPathExtension
      var n = 1
      while true {
        let candidate = folder.appendingPathComponent(
          ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
        if !files.fileExists(atPath: candidate.path) { return (candidate, true) }
        n += 1
      }
    }
  }

  /// The export picker's delegate, kept alive by the picker it serves and
  /// answering once.
  private final class ExportDelegate: NSObject, UIDocumentPickerDelegate {
    private static var key = 0
    private var finish: (([URL]?) -> Void)?

    init(_ finish: @escaping ([URL]?) -> Void) { self.finish = finish }

    /// The picker holds its delegate weakly; it keeps this one instead.
    func retain(by picker: UIDocumentPickerViewController) {
      objc_setAssociatedObject(picker, &Self.key, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
    {
      answer(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { answer(nil) }

    private func answer(_ urls: [URL]?) {
      let finish = self.finish
      self.finish = nil
      finish?(urls)
    }
  }
#endif
