#if os(iOS)
import Flutter
#elseif os(macOS)
import FlutterMacOS
#endif

/// Registers the native side of mpx: the device signals event channel.
public class MpxPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterEventChannel(name: "dev.mpx.device_signals", binaryMessenger: messenger)
    channel.setStreamHandler(DeviceSignalsStream())
  }
}
