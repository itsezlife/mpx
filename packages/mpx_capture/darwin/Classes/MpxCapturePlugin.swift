import AVFoundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Native side of mpx_capture: one method channel for commands, one event
/// channel for job progress. Every job event is a map with `job` and `type`
/// (see the Dart `CaptureChannel`). Events are sent on the main thread.
public class MpxCapturePlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private let transcoder = CaptureTranscoder()

  override init() {
    super.init()
    transcoder.emit = { [weak self] event in self?.emit(event) }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let instance = MpxCapturePlugin()
    let methods = FlutterMethodChannel(
      name: "dev.mpx.capture/methods", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(
      name: "dev.mpx.capture/events", binaryMessenger: messenger)
    events.setStreamHandler(instance)
  }

  // MARK: - Events

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ event: [String: Any]) {
    if Thread.isMainThread {
      eventSink?(event)
    } else {
      DispatchQueue.main.async { [weak self] in self?.eventSink?(event) }
    }
  }

  // MARK: - Methods

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "probe":
      guard let path = args["path"] as? String else {
        return result(CaptureError.failed("probe needs a path").flutter)
      }
      Task {
        do {
          let info = try await CaptureTranscoder.probe(path: path)
          DispatchQueue.main.async { result(info) }
        } catch {
          DispatchQueue.main.async { result(CaptureError.wrap(error).flutter) }
        }
      }
    case "compress":
      do {
        try transcoder.enqueue(CompressionRequest(args))
        result(nil)
      } catch {
        result(CaptureError.wrap(error).flutter)
      }
    case "cancel":
      if let job = args["job"] as? Int {
        transcoder.cancel(job: job)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Errors that cross the channel; the code picks the Dart exception.
enum CaptureError: Error {
  case failed(String)
  case permission(String)

  static func wrap(_ error: Error) -> CaptureError {
    if let error = error as? CaptureError { return error }
    return .failed(error.localizedDescription)
  }

  var code: String {
    switch self {
    case .failed: return "failed"
    case .permission: return "permission"
    }
  }

  var message: String {
    switch self {
    case .failed(let message), .permission(let message): return message
    }
  }

  var flutter: FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  func event(job: Int) -> [String: Any] {
    ["job": job, "type": "error", "code": code, "message": message]
  }
}

/// Size of the file at `url`, or 0 when it does not exist yet.
func fileSize(_ url: URL) -> Int {
  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
  return (attributes?[.size] as? NSNumber)?.intValue ?? 0
}
