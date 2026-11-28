import 'dart:io';

import 'package:mpx_library/src/platform/desktop_save_writer.dart';

/// The user's folders on macOS: fixed names under the home, `Downloads`,
/// `Pictures` and `Movies`, which the system neither moves nor localizes
/// on disk (the Finder shows a localized name over the same path).
///
/// A sandboxed app's home is its container, whose entries of the same names
/// lead to the user's own folders; writing through them needs the host's
/// entitlement for that folder (`com.apple.security.files.downloads.read-write`
/// for Downloads). The system's own lookup answers the same container path,
/// so the home is read here rather than over the plugin's channel. Without
/// `HOME` there is no folder.
final class MacosHomeFolders implements DesktopFolders {
  /// The folders of [environment] (the process's by default).
  const MacosHomeFolders({Map<String, String>? environment})
    : _environment = environment;

  final Map<String, String>? _environment;

  @override
  Future<String?> pathOf(DesktopFolder folder) async {
    final home = (_environment ?? Platform.environment)['HOME'];
    if (home == null || home.isEmpty) return null;
    final base = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
    return switch (folder) {
      DesktopFolder.downloads => '$base/Downloads',
      DesktopFolder.pictures => '$base/Pictures',
      DesktopFolder.videos => '$base/Movies',
    };
  }
}
