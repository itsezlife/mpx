import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mpx_library/src/platform/android_save_writer.dart';
import 'package:mpx_library/src/platform/apple_save_writer.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/macos_save_writer.dart';
import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';
import 'package:mpx_library/src/platform/save_platform.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The [SavePlatform] of the native process: the target platform's, a
/// desktop only on its own OS.
SavePlatform $savePlatform() => switch (defaultTargetPlatform) {
  TargetPlatform.android => SavePlatform.android,
  TargetPlatform.iOS => SavePlatform.ios,
  TargetPlatform.macOS when Platform.isMacOS => SavePlatform.macos,
  TargetPlatform.windows when Platform.isWindows => SavePlatform.windows,
  TargetPlatform.linux when Platform.isLinux => SavePlatform.linux,
  _ => SavePlatform.other,
};

/// The save writer of [platform], over the plugin's [methods] channel:
/// Android writes through the native saver ([AndroidSaveWriter]), iOS in
/// one native block ([AppleSaveWriter]), macOS Photos as a block and files
/// from Dart ([MacosSaveWriter]), Windows and Linux files
/// ([DesktopSaveWriter]); any other stands in with [NoAdapterSaveWriter].
SaveWriter $createSaveWriter(SavePlatform platform, MethodChannel methods) =>
    switch (platform) {
      SavePlatform.android => AndroidSaveWriter(methods),
      SavePlatform.ios => AppleSaveWriter(methods),
      SavePlatform.macos => MacosSaveWriter(methods),
      SavePlatform.windows => DesktopSaveWriter(DesktopPlatform.windows),
      SavePlatform.linux => DesktopSaveWriter(DesktopPlatform.linux),
      SavePlatform.web ||
      SavePlatform.other => NoAdapterSaveWriter(defaultTargetPlatform.name),
    };
