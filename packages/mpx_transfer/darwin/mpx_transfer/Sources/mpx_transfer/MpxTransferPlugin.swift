#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// The native part of mpx_transfer on iOS and macOS.
///
/// The transfer engine runs in Dart. On iOS this part holds the OS envelope
/// that keeps a `system` transfer going in the background
/// (`MpxTransferEnvelope`), over the channel `dev.mpx.transfer/envelope`.
/// macOS has no envelope, so it registers nothing.
public class MpxTransferPlugin: NSObject, FlutterPlugin {
  #if os(iOS)
  private let envelope: MpxTransferEnvelope

  init(envelope: MpxTransferEnvelope) {
    self.envelope = envelope
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "dev.mpx.transfer/envelope",
      binaryMessenger: registrar.messenger()
    )
    let instance = MpxTransferPlugin(envelope: MpxTransferEnvelope(channel: channel))
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    envelope.handle(call, result: result)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    envelope.detach()
  }
  #else
  public static func register(with registrar: FlutterPluginRegistrar) {}
  #endif
}
