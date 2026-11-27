#if os(iOS)
import BackgroundTasks
import Flutter
import UIKit

/// The OS envelope on iOS: what holds the process while `system` transfers
/// run with the app in the background.
///
/// The Dart side (`IosTransferEnvelope`) owns the policy: when to ask for a
/// continued-processing task, what progress to show, when to let go. This
/// side does what must not wait for a round trip and what only it can:
///
/// - a background task begun the moment the app enters the background while
///   an envelope is armed, on every version (about 30 s);
/// - on iOS 26 and later, the continued-processing task: its launch handler,
///   registered under a new identifier per submission below the host's
///   permitted `<prefix>.mpx.transfer.*` entry, its submission (failing when
///   the system cannot run it now), its progress and title, its expiry;
/// - each event to `os_log`, and into the ring while no Dart side listens.
///
/// Everything runs on the main queue.
final class MpxTransferEnvelope {
  /// The suffix of the host's entry in `BGTaskSchedulerPermittedIdentifiers`.
  static let identifierSuffix = ".mpx.transfer.*"

  private let channel: FlutterMethodChannel
  private let log = MpxTransferEnvelopeLog()

  /// The permitted identifier's prefix, read at launch; nil without one.
  private let taskPrefix: String?

  /// Whether a Dart side is attached to hear events.
  private var attached = false

  /// The armed envelope; nil while none is.
  private var handle: String?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  /// The identifier of the continued-processing task asked for, until it
  /// ends or is let go; a launch or an expiry under another one is stale.
  private var continuedId: String?

  /// The running continued-processing task (a `BGContinuedProcessingTask`).
  private var continuedTask: BGTask?
  private var subtitle: String?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    let permitted =
      Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
      as? [String] ?? []
    taskPrefix = permitted.first { $0.hasSuffix(MpxTransferEnvelope.identifierSuffix) }
      .map { String($0.dropLast()) }
    if MpxTransferEnvelope.continuedSupported && taskPrefix == nil {
      log.record(
        "refused", level: "warning",
        fields: ["kind": "continuedProcessing", "code": "noIdentifier"], keep: false)
    }
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(willResignActive),
      name: UIApplication.willResignActiveNotification, object: nil)
    center.addObserver(
      self, selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    center.addObserver(
      self, selector: #selector(didBecomeActive),
      name: UIApplication.didBecomeActiveNotification, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  static var continuedSupported: Bool {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) { return true }
    #endif
    return false
  }

  private var inBackground: Bool {
    UIApplication.shared.applicationState == .background
  }

  // MARK: - Calls from Dart

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "attach":
      attached = true
      if let limit = args["nativeLogBytes"] as? Int, limit > 0 { log.limit = limit }
      result([
        "handle": handle as Any,
        "kind": heldKind as Any,
        "foreground": !inBackground,
        "continued": MpxTransferEnvelope.continuedSupported,
        "records": log.drain(),
      ])
    case "arm":
      letGo()
      let armed = "ios-\(UUID().uuidString)"
      handle = armed
      if inBackground { beginBackgroundTask() }
      result(["handle": armed, "foreground": !inBackground, "kind": heldKind as Any])
    case "submit":
      result(submit(args))
    case "progress":
      push(args)
      result(nil)
    case "withdraw":
      if let kind = heldKind {
        log.record(
          "withdrawn", level: "info", fields: ["kind": kind, "why": "foreground"],
          keep: !attached)
      }
      letGo()
      result(nil)
    case "disarm":
      letGo()
      handle = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The engine is gone: nothing moves the bytes any more, so nothing is
  /// held for them.
  func detach() {
    attached = false
    if handle != nil {
      log.record(
        "withdrawn", level: "info", fields: ["kind": heldKind ?? "none", "why": "detached"],
        keep: true)
    }
    letGo()
    handle = nil
  }

  // MARK: - Lifecycle

  @objc private func willResignActive() {
    send("lifecycle", ["state": "resignActive"])
  }

  @objc private func didEnterBackground() {
    var args: [String: Any] = ["state": "background"]
    if handle != nil {
      beginBackgroundTask()
      if backgroundTask != .invalid {
        args["kind"] = "bgTask"
      } else {
        args["refused"] = "invalid"
      }
    }
    send("lifecycle", args)
  }

  @objc private func didBecomeActive() {
    send("lifecycle", ["state": "active"])
  }

  // MARK: - Background task

  private func beginBackgroundTask() {
    guard backgroundTask == .invalid, let armed = handle else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "mpx_transfer.envelope") {
      [weak self] in self?.backgroundTaskExpired(armed)
    }
    if backgroundTask == .invalid {
      log.record(
        "refused", level: "warning", fields: ["kind": "bgTask", "code": "invalid"],
        keep: !attached)
    } else {
      log.record(
        "started", level: "info", fields: ["kind": "bgTask", "handle": armed], keep: !attached)
    }
  }

  /// The system's time for the background task ran out. It must end here,
  /// synchronously, or the system ends the app. A continued-processing task
  /// still holding the process makes this nothing more.
  private func backgroundTaskExpired(_ armed: String) {
    endBackgroundTask()
    guard handle == armed, continuedTask == nil else { return }
    ended(cause: "expiry", kind: "bgTask")
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  // MARK: - Continued-processing task

  private func submit(_ args: [String: Any]) -> [String: Any] {
    guard let armed = handle, args["handle"] as? String == armed else {
      return ["submitted": false, "code": "stale"]
    }
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      guard let prefix = taskPrefix else { return refused("noIdentifier") }
      let id = prefix + UUID().uuidString
      // One identifier per submission: registering an identifier twice
      // ends the app, and the wildcard entry itself cannot be registered.
      let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: nil) {
        [weak self] task in
        DispatchQueue.main.async { self?.launched(task, id: id) }
      }
      guard registered else { return refused("notPermitted") }
      let title = args["title"] as? String ?? ""
      let subtitle = args["subtitle"] as? String ?? ""
      let request = BGContinuedProcessingTaskRequest(
        identifier: id, title: title, subtitle: subtitle)
      request.strategy = .fail
      do {
        try BGTaskScheduler.shared.submit(request)
      } catch {
        return refused(MpxTransferEnvelope.code(of: error))
      }
      continuedId = id
      self.subtitle = subtitle
      log.record("submitted", level: "debug", fields: ["handle": armed], keep: false)
      return ["submitted": true]
    }
    #endif
    return refused("unsupported")
  }

  private func refused(_ code: String) -> [String: Any] {
    log.record(
      "refused", level: "warning", fields: ["kind": "continuedProcessing", "code": code],
      keep: !attached)
    return ["submitted": false, "code": code]
  }

  #if compiler(>=6.2)
  @available(iOS 26.0, *)
  private static func code(of error: Error) -> String {
    guard let error = error as? BGTaskScheduler.Error else { return "error" }
    switch error.code {
    case .unavailable: return "unavailable"
    case .tooManyPendingTaskRequests: return "tooManyPending"
    case .notPermitted: return "notPermitted"
    case .immediateRunIneligible: return "immediateRunIneligible"
    @unknown default: return "error"
    }
  }
  #endif

  /// The system ran the task asked for: it holds the process from now on,
  /// unless it is stale (let go since). It may run before the app reaches
  /// the background (a submission at resign-active); the Dart side lets it
  /// go if the app becomes active instead.
  private func launched(_ task: BGTask, id: String) {
    guard id == continuedId, let armed = handle else {
      task.setTaskCompleted(success: true)
      return
    }
    continuedTask = task
    // `BGContinuedProcessingTask` reports through `ProgressReporting`.
    (task as? ProgressReporting)?.progress.totalUnitCount = MpxTransferEnvelope.progressUnits
    // Runs both when the system ends the task and when the user cancels it
    // from the Live Activity: the two are not told apart.
    task.expirationHandler = { [weak self] in
      task.setTaskCompleted(success: false)
      DispatchQueue.main.async { self?.continuedExpired(id) }
    }
    log.record(
      "started", level: "info", fields: ["kind": "continuedProcessing", "handle": armed],
      keep: !attached)
    send("held", ["handle": armed, "kind": "continuedProcessing"])
  }

  private func continuedExpired(_ id: String) {
    guard id == continuedId else { return }
    continuedTask = nil
    continuedId = nil
    guard handle != nil else { return }
    endBackgroundTask()
    ended(cause: "stop", kind: "continuedProcessing")
  }

  private static let progressUnits: Int64 = 1000

  /// The engine's progress, mirrored: the fraction when the total is
  /// known, and the subtitle when it changed.
  private func push(_ args: [String: Any]) {
    guard let task = continuedTask, args["handle"] as? String == handle else { return }
    if let fraction = args["fraction"] as? Double,
      let progress = (task as? ProgressReporting)?.progress
    {
      progress.completedUnitCount = Int64(
        (min(max(fraction, 0), 1) * Double(MpxTransferEnvelope.progressUnits)).rounded(.down))
    }
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask,
      let subtitle = args["subtitle"] as? String, subtitle != self.subtitle
    {
      self.subtitle = subtitle
      continued.updateTitle(continued.title, subtitle: subtitle)
    }
    #endif
    log.record(
      "progressPushed", level: "trace",
      fields: ["fraction": args["fraction"] as? Double ?? -1], keep: false)
  }

  // MARK: - Ending

  /// What holds the process now, by the Dart side's name.
  private var heldKind: String? {
    if continuedTask != nil { return "continuedProcessing" }
    if backgroundTask != .invalid { return "bgTask" }
    return nil
  }

  /// Lets go of whatever holds the process, as the app asked: a pending or
  /// running continued-processing task, and the background task.
  private func letGo() {
    if let id = continuedId {
      continuedId = nil
      if let task = continuedTask {
        task.setTaskCompleted(success: true)
      } else {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: id)
      }
    }
    continuedTask = nil
    subtitle = nil
    endBackgroundTask()
  }

  /// The system ended what held the process: the envelope is over, and the
  /// Dart side pauses its jobs.
  private func ended(cause: String, kind: String) {
    guard let armed = handle else { return }
    let remaining = UIApplication.shared.backgroundTimeRemaining
    var fields: [String: Any] = ["kind": kind, "cause": cause]
    if remaining.isFinite { fields["remainingS"] = Int(remaining) }
    log.record("systemEnded", level: "warning", fields: fields, keep: !attached)
    letGo()
    handle = nil
    send("ended", ["handle": armed, "cause": cause])
  }

  private func send(_ method: String, _ args: [String: Any]) {
    guard attached else { return }
    channel.invokeMethod(method, arguments: args)
  }
}
#endif
