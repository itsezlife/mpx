import 'package:mpx_library/src/intake/drop_intake.dart';
import 'package:mpx_library/src/intake/file_intake.dart';
import 'package:mpx_library/src/intake/platform_intake_io.dart'
    if (dart.library.js_interop) 'package:mpx_library/src/intake/platform_intake_web.dart'
    as environment_specific;

/// The platform's intake routes.
///
/// | Route | Android, iOS, macOS and the other desktops | Web |
/// | --- | --- | --- |
/// | [fileIntake] | the system dialog (`file_selector`), the system camera (Android, iOS) | a hidden file input |
/// | [dropSource] | `super_drag_and_drop`'s drop region | DOM drag events |
/// | [clipboardReader] | `super_clipboard` | the async clipboard |
///
/// Which file the build picks decides it, so `dart:io` never reaches a web
/// build and `package:web` never a native one.
abstract final class PlatformIntake {
  /// The file intake of this platform.
  static Future<FileIntake> fileIntake() =>
      environment_specific.$createFileIntake();

  /// The drop source of this platform.
  static DropSource? dropSource() => environment_specific.$createDropSource();

  /// The clipboard reader of this platform.
  static ClipboardReader? clipboardReader() =>
      environment_specific.$createClipboardReader();
}
