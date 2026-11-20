#if os(iOS)
  import Flutter
  import UIKit
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Native side of mpx_library on iOS: the PhotoKit library on one method
/// channel, its events (access, changes, downloads) on one event channel,
/// and the system camera.
///
/// PhotoKit compiles only under the host's `MPX_LIBRARY_PHOTOS` condition
/// and the system camera under `MPX_LIBRARY_CAMERA` (README), so a host that
/// never reads the library links no photo-library code: without the first,
/// access answers `restricted`; without the second, the system camera is
/// unavailable.
public class MpxLibraryPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  #if MPX_LIBRARY_PHOTOS && os(iOS)
    private let photos = PhotoLibrary()
  #endif
  #if MPX_LIBRARY_CAMERA && os(iOS)
    private let camera = SystemCamera()
  #endif

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let instance = MpxLibraryPlugin()
    let methods = FlutterMethodChannel(
      name: "dev.mpx.library/methods", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "dev.mpx.library/events", binaryMessenger: messenger)
    events.setStreamHandler(instance)
    #if MPX_LIBRARY_PHOTOS && os(iOS)
      instance.photos.emit = { [weak instance] event in instance?.send(event) }
    #endif
  }

  // MARK: - Events

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    #if MPX_LIBRARY_PHOTOS && os(iOS)
      photos.stopObserving()
    #endif
    return nil
  }

  private func send(_ event: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.sink?(event) }
  }

  // MARK: - Methods

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "systemCamera":
      return systemCamera(args, result: result)
    case "systemCameraAvailable":
      #if MPX_LIBRARY_CAMERA && os(iOS)
        return result(SystemCamera.available)
      #else
        return result(false)
      #endif
    case "openSettings":
      #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      #endif
      return result(nil)
    default:
      break
    }
    #if MPX_LIBRARY_PHOTOS && os(iOS)
      library(call.method, args, result: result)
    #else
      switch call.method {
      case "access", "requestAccess":
        result(["platform": "apple", "status": "unavailable"])
      case "albums":
        result([] as [Any])
      case "page":
        result(["total": 0, "assets": [] as [Any]])
      case "thumbnail", "original":
        result(FlutterError(code: "unavailable", message: "photo library not built in", details: nil))
      case "manageSelected", "cancelOriginal", "releaseOriginal", "playable", "present":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    #endif
  }

  private func systemCamera(_ args: [String: Any], result: @escaping FlutterResult) {
    #if MPX_LIBRARY_CAMERA && os(iOS)
      guard let controller = Self.topController() else { return result(nil) }
      camera.capture(kind: args["kind"] as? String ?? "photo", from: controller) { facts in
        result(facts)
      }
    #else
      result(FlutterError(code: "unavailable", message: "system camera not built in", details: nil))
    #endif
  }

  #if os(iOS)
    static func topController() -> UIViewController? {
      let window = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first { $0.isKeyWindow }
      var controller = window?.rootViewController
      while let presented = controller?.presentedViewController { controller = presented }
      return controller
    }
  #endif

  #if MPX_LIBRARY_PHOTOS && os(iOS)
    private func library(_ method: String, _ args: [String: Any], result: @escaping FlutterResult) {
      func main(_ value: Any?) { DispatchQueue.main.async { result(value) } }
      switch method {
      case "access":
        result(photos.access())
      case "requestAccess":
        photos.requestAccess { access in main(access) }
      case "manageSelected":
        photos.manageSelected { main(nil) }
      case "albums":
        DispatchQueue.global(qos: .userInitiated).async { main(self.photos.albums()) }
      case "page":
        let album = args["album"] as? String ?? "recents"
        let offset = args["offset"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? 0
        DispatchQueue.global(qos: .userInitiated).async {
          main(self.photos.page(album: album, offset: offset, limit: limit))
        }
      case "thumbnail":
        photos.thumbnail(id: args["id"] as? String ?? "", pixels: args["pixels"] as? Int ?? 256) {
          outcome in
          switch outcome {
          case .success(let data): main(FlutterStandardTypedData(bytes: data))
          case .failure(let error): main(error.flutter)
          }
        }
      case "original":
        let request = args["request"] as? Int ?? 0
        photos.original(
          id: args["id"] as? String ?? "", request: request,
          progress: { [weak self] thousandths in
            self?.send([
              "type": "progress", "request": request, "received": thousandths, "total": 1000,
            ])
          }
        ) { outcome in
          switch outcome {
          case .success(let map): main(map)
          case .failure(let error): main(error.flutter)
          }
        }
      case "present":
        main(photos.present(ids: args["ids"] as? [String] ?? []))
      case "playable":
        photos.playable(id: args["id"] as? String ?? "") { url in main(url) }
      case "cancelOriginal":
        photos.cancelOriginal(request: args["request"] as? Int ?? 0)
        result(nil)
      case "releaseOriginal":
        if let path = args["path"] as? String,
          path.hasPrefix(FileManager.default.temporaryDirectory.appendingPathComponent(
            "mpx_library_originals"
          ).path)
        {
          try? FileManager.default.removeItem(atPath: path)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  #endif
}
