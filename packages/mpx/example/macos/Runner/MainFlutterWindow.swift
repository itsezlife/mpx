import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The viewer asks the host to put its window into fullscreen; the
    // example answers on this channel rather than through a window plugin.
    let window = FlutterMethodChannel(
      name: "mpx_example/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    window.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setFullscreen", let self,
        let fullscreen = call.arguments as? Bool
      else {
        result(FlutterMethodNotImplemented)
        return
      }
      if self.styleMask.contains(.fullScreen) != fullscreen {
        self.toggleFullScreen(nil)
      }
      result(nil)
    }

    super.awakeFromNib()
  }
}
