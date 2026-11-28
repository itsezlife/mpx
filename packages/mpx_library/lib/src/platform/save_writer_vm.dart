import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/platform/android_save_writer.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of the native platform the app runs on, admitting a batch
/// through [access] first: Android writes through the plugin's native saver
/// ([AndroidSaveWriter]), Windows and Linux write files
/// ([DesktopSaveWriter]); every other platform stands in with
/// [NoAdapterSaveWriter] until its adapter lands.
///
/// Picked by the OS the process runs on, not by `defaultTargetPlatform`: a
/// test or a host that overrides the target platform must not bind
/// another OS's system calls.
SaveWriter $createSaveWriter({required PlatformSaveAccess access}) {
  if (Platform.isAndroid) {
    return AndroidSaveWriter(access.methods, access: access);
  }
  if (Platform.isWindows) {
    return DesktopSaveWriter(DesktopPlatform.windows, access: access);
  }
  if (Platform.isLinux) {
    return DesktopSaveWriter(DesktopPlatform.linux, access: access);
  }
  return NoAdapterSaveWriter(defaultTargetPlatform.name, access: access);
}
