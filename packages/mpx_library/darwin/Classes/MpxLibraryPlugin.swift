#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

/// Native side of mpx_library: one method channel. The PhotoKit adapter and
/// the intake routes answer on it as they land; until then every call is not
/// implemented.
///
/// PhotoKit and the system camera are to compile only under the host's
/// opt-in conditions `MPX_LIBRARY_PHOTOS` and `MPX_LIBRARY_CAMERA` (README),
/// so a host that never reads the library links no photo-library code.
public class MpxLibraryPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let methods = FlutterMethodChannel(
      name: "dev.mpx.library/methods", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(MpxLibraryPlugin(), channel: methods)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    result(FlutterMethodNotImplemented)
  }
}
