import 'package:flutter/services.dart';
import 'package:mpx_library/src/platform/apple_save_writer.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of macOS, which writes its destinations in two shapes:
///
/// - `gallery`: one Photos change block per batch through [photos] (an
///   [AppleSaveWriter] over the plugin's channel), as on iOS.
/// - `downloads` and `ask`: files the Dart side writes item by item through
///   [files] (a [DesktopSaveWriter] of [DesktopPlatform.macos]), with
///   progress and a cancel inside a copy, which a block has neither of:
///   `~/Downloads/<subfolder>` (a taken name becomes `name (1)`,
///   `createdAt` the modification time), and the system save panel, one per
///   item.
final class MacosSaveWriter extends SaveWriter$ByDestination {
  /// The writer over [methods]. [folders] defaults to the home's
  /// (`MacosHomeFolders`), [pickLocation] to the system save panel.
  MacosSaveWriter(
    MethodChannel methods, {
    DesktopFolders? folders,
    Future<String?> Function(String suggestedName)? pickLocation,
  }) : photos = AppleSaveWriter(methods, platform: 'macos'),
       files = DesktopSaveWriter(
         DesktopPlatform.macos,
         folders: folders,
         pickLocation: pickLocation,
       );

  /// The gallery's writer.
  final AppleSaveWriter photos;

  /// The writer of Downloads and the save panel.
  final DesktopSaveWriter files;

  @override
  String get platform => 'macos';

  @override
  SaveWriter writerFor(SaveDestination destination) => switch (destination) {
    SaveDestination$Gallery() => photos,
    SaveDestination$Downloads() || SaveDestination$Ask() => files,
  };
}
