import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of the native platform the app runs on: Windows and
/// Linux write files ([DesktopSaveWriter]); every other platform stands in
/// with [NoAdapterSaveWriter] until its adapter lands.
///
/// Picked by the OS the process runs on, not by `defaultTargetPlatform`: a
/// test or a host that overrides the target platform must not bind
/// another OS's system calls.
SaveWriter $createSaveWriter() {
  if (Platform.isWindows) return DesktopSaveWriter(DesktopPlatform.windows);
  if (Platform.isLinux) return DesktopSaveWriter(DesktopPlatform.linux);
  return NoAdapterSaveWriter(defaultTargetPlatform.name);
}
