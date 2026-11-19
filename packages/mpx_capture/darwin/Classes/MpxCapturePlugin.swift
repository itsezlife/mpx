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
  private let textures: FlutterTextureRegistry
  private var recorders: [Int: RoundVideoRecorder] = [:]

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
    transcoder.emit = { [weak self] event in self?.emit(event) }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
      let textures = registrar.textures()
    #else
      let messenger = registrar.messenger
      let textures = registrar.textures
    #endif
    let instance = MpxCapturePlugin(textures: textures)
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
    case "stillProbe":
      prepare(result) { try StillCodec.probe(path: try Self.need(args, "path")) }
    case "stillEncode":
      prepare(result) {
        try StillCodec.encode(
          path: try Self.need(args, "path"), maxSide: try Self.need(args, "maxSide"),
          quality: try Self.need(args, "quality"),
          progressive: args["progressive"] as? Bool ?? false,
          output: args["output"] as? String)
      }
    case "videoThumbnail":
      prepare(result) {
        try StillCodec.videoThumbnail(
          path: try Self.need(args, "path"), maxSide: try Self.need(args, "maxSide"),
          quality: try Self.need(args, "quality"))
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
        recorders.removeValue(forKey: job)?.cancel()
      }
      result(nil)
    case "permissions":
      RoundVideoRecorder.requestPermissions { granted in
        DispatchQueue.main.async { result(granted) }
      }
    case "roundStart":
      startRound(args, result: result)
    case "roundPause":
      recorder(args)?.pause()
      result(nil)
    case "roundResume":
      recorder(args)?.resume()
      result(nil)
    case "roundSwitchCamera":
      guard let recorder = recorder(args) else { return result(nil) }
      recorder.switchCamera { facing in DispatchQueue.main.async { result(facing) } }
    case "roundStop":
      recorder(args)?.stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Media preparation runs two items at a time (ADR 0011), off the main
  /// thread; the answer goes back on the main thread.
  private let preparation: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "dev.mpx.capture.prepare"
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    return queue
  }()

  private func prepare(_ result: @escaping FlutterResult, _ work: @escaping () throws -> [String: Any]) {
    preparation.addOperation {
      let answer: Any
      do {
        answer = try work()
      } catch {
        answer = CaptureError.wrap(error).flutter
      }
      DispatchQueue.main.async { result(answer) }
    }
  }

  private static func need<T>(_ args: [String: Any], _ key: String) throws -> T {
    guard let value = args[key] as? T else { throw CaptureError.failed("missing \(key)") }
    return value
  }

  private func recorder(_ args: [String: Any]) -> RoundVideoRecorder? {
    guard let job = args["job"] as? Int else { return nil }
    return recorders[job]
  }

  private func startRound(_ args: [String: Any], result: @escaping FlutterResult) {
    let config: RoundVideoRecorder.Config
    do {
      config = try RoundVideoRecorder.Config(args)
    } catch {
      return result(CaptureError.wrap(error).flutter)
    }
    let recorder = RoundVideoRecorder(config: config, textures: textures)
    recorder.emit = { [weak self] event in self?.emit(event) }
    recorder.onFinish = { [weak self] in
      DispatchQueue.main.async { self?.recorders.removeValue(forKey: config.job) }
    }
    recorders[config.job] = recorder
    recorder.start { outcome in
      DispatchQueue.main.async {
        switch outcome {
        case .success(let info):
          result(info)
        case .failure(let error):
          result(CaptureError.wrap(error).flutter)
        }
      }
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
