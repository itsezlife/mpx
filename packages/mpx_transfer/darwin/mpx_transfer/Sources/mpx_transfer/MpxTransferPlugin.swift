#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// The native part of mpx_transfer on iOS and macOS.
///
/// Empty for now: the transfer engine runs in Dart, and the OS envelope that
/// keeps a `system` transfer going in the background (iOS) is added here
/// later. macOS has no envelope.
public class MpxTransferPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
