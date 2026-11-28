import 'dart:convert';
import 'dart:io';

import 'package:mpx_library/src/platform/desktop_save_writer.dart';

/// The user's folders on Linux: the XDG user directories, read from
/// `user-dirs.dirs`.
///
/// ## Where
///
/// `$XDG_CONFIG_HOME/user-dirs.dirs`; `XDG_CONFIG_HOME` is `~/.config` when
/// unset, empty or not absolute (the XDG Base Directory specification).
///
/// ## Format
///
/// Written by `xdg-user-dirs-update`, one assignment per line, `#` lines
/// are comments:
///
/// ```text
/// XDG_DOWNLOAD_DIR="$HOME/Downloads"
/// XDG_PICTURES_DIR="/media/data/Pictures"
/// ```
///
/// A value is `$HOME/<relative path>` or an absolute path, shell-quoted
/// (`\"`, `\$`, `\\` inside the quotes); the format allows nothing else, so
/// any other value is skipped. A value of `$HOME` alone names the home.
///
/// ## Fallback
///
/// A missing file, or a folder without its key, is the home itself, as
/// `xdg-user-dir` answers. Without `HOME` there is no folder.
///
/// No package reads this for us: the system's `xdg-user-dir` would cost a
/// process per lookup, and the parse is a few lines.
final class XdgUserDirs implements DesktopFolders {
  /// The directories of [environment] (the process's by default).
  XdgUserDirs({Map<String, String>? environment})
    : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;

  static const Map<DesktopFolder, String> _keys = {
    DesktopFolder.pictures: 'XDG_PICTURES_DIR',
    DesktopFolder.videos: 'XDG_VIDEOS_DIR',
    DesktopFolder.downloads: 'XDG_DOWNLOAD_DIR',
  };

  @override
  Future<String?> pathOf(DesktopFolder folder) async {
    final home = _environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final configHome = switch (_environment['XDG_CONFIG_HOME']) {
      final String path when path.startsWith('/') => path,
      _ => '$home/.config',
    };
    final String contents;
    try {
      contents = utf8.decode(
        await File('$configHome/user-dirs.dirs').readAsBytes(),
        allowMalformed: true,
      );
    } on FileSystemException {
      // No file (or none readable) is the documented case of no user
      // directories: the home stands in, as below for a missing key.
      return home;
    }
    return parse(contents, home: home)[_keys[folder]] ?? home;
  }

  /// The assignments of a `user-dirs.dirs` file's [contents], each value a
  /// path with `$HOME` replaced by [home] and no trailing slash. A later
  /// line wins over an earlier one with the same key.
  static Map<String, String> parse(String contents, {required String home}) {
    final dirs = <String, String>{};
    for (final raw in const LineSplitter().convert(contents)) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final match = _line.firstMatch(line);
      if (match == null) continue;
      final value = match[2] != null ? _unescape(match[2]!) : match[3]!;
      final path = switch (value) {
        r'$HOME' => home,
        _ when value.startsWith(r'$HOME/') => '$home${value.substring(5)}',
        _ when value.startsWith('/') => value,
        _ => null,
      };
      if (path == null) continue;
      dirs[match[1]!] = _trimSlash(path);
    }
    return dirs;
  }

  static final RegExp _line = RegExp(
    r'^(XDG_[A-Z0-9_]+_DIR)\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^\s"]+))\s*$',
  );

  /// Undoes the backslash escapes of a double-quoted shell string.
  static String _unescape(String quoted) =>
      quoted.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);

  static String _trimSlash(String path) {
    var end = path.length;
    while (end > 1 && path[end - 1] == '/') {
      end--;
    }
    return path.substring(0, end);
  }
}
