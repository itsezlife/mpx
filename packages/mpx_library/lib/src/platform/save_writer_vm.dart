import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/platform/apple_save_writer.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of the native platform the app runs on, admitting a batch
/// through [access] first: Windows and Linux write files
/// ([DesktopSaveWriter]), iOS writes over the plugin's channel
/// ([AppleSaveWriter]); every other platform stands in with
/// [NoAdapterSaveWriter] until its adapter lands.
///
/// Picked by the OS the process runs on, not by `defaultTargetPlatform`: a
/// test or a host that overrides the target platform must not bind
/// another OS's system calls. iOS is the exception, picked as its access is:
/// its writer binds no system call, only the plugin's channel, so a test
/// that overrides the target platform drives it over a fake channel.
SaveWriter $createSaveWriter({required PlatformSaveAccess access}) {
  // First, so a test on any host that overrides the platform to iOS gets it.
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return AppleSaveWriter(access.methods, access: access);
  }
  if (Platform.isWindows) {
    return DesktopSaveWriter(DesktopPlatform.windows, access: access);
  }
  if (Platform.isLinux) {
    return DesktopSaveWriter(DesktopPlatform.linux, access: access);
  }
  return NoAdapterSaveWriter(defaultTargetPlatform.name, access: access);
}
