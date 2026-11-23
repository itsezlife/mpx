import Foundation
import Network

#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import FlutterMacOS
#endif

/// Streams device signals to Dart: one full reading (network class, power
/// saving, thermal status, battery level) on listen and another whenever any of them changes.
///
/// Readings are sent on the main queue. Apple platforms do not report
/// roaming, so the network class is one of none, unmetered and metered.
final class DeviceSignalsStream: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var monitor: NWPathMonitor?
  // Nil until the monitor reports its first path, which it does right after
  // start; the first reading waits for it rather than guessing.
  private var network: String?
  private var lastSent: [String: NSObject]?
  private var observers: [NSObjectProtocol] = []

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let next = Self.classify(path)
      DispatchQueue.main.async {
        guard let self, self.monitor === monitor else { return }
        self.network = next
        self.send()
      }
    }
    monitor.start(queue: DispatchQueue.global(qos: .utility))
    self.monitor = monitor

    let center = NotificationCenter.default
    #if os(iOS)
    UIDevice.current.isBatteryMonitoringEnabled = true
    let names: [Notification.Name] = [
      .NSProcessInfoPowerStateDidChange,
      ProcessInfo.thermalStateDidChangeNotification,
      UIDevice.batteryLevelDidChangeNotification,
    ]
    #else
    let names: [Notification.Name] = [
      .NSProcessInfoPowerStateDidChange,
      ProcessInfo.thermalStateDidChangeNotification,
    ]
    #endif
    for name in names {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.send()
      })
    }
    send()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    monitor?.cancel()
    monitor = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    #if os(iOS)
    UIDevice.current.isBatteryMonitoringEnabled = false
    #endif
    sink = nil
    network = nil
    lastSent = nil
    return nil
  }

  private func send() {
    guard let sink, let network else { return }
    let info = ProcessInfo.processInfo
    let reading: [String: NSObject] = [
      "network": network as NSString,
      "powerSaving": NSNumber(value: info.isLowPowerModeEnabled),
      "thermal": Self.name(of: info.thermalState) as NSString,
      "batteryLevel": NSNumber(value: Self.batteryLevel()),
    ]
    if reading == lastSent { return }
    lastSent = reading
    sink(reading)
  }

  // The percentage, or -1 where the system cannot say (macOS, a simulator).
  private static func batteryLevel() -> Int {
    #if os(iOS)
    let level = UIDevice.current.batteryLevel
    return level < 0 ? -1 : Int((level * 100).rounded())
    #else
    return -1
    #endif
  }

  // Low Data Mode (a constrained path) reads as metered: the user asked to
  // spare data, which is what a metered class tells a policy.
  private static func classify(_ path: NWPath) -> String {
    guard path.status == .satisfied else { return "none" }
    return path.isExpensive || path.isConstrained ? "metered" : "unmetered"
  }

  private static func name(of state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    // A state added later sits past critical.
    @unknown default: return "critical"
    }
  }
}
