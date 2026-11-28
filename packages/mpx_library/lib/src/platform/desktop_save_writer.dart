import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/src/platform/save_file_copy.dart';
import 'package:mpx_library/src/platform/windows_known_folders.dart';
import 'package:mpx_library/src/platform/xdg_user_dirs.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// A desktop with no gallery, where a save is a file in a folder: where its
/// folders come from and what its file system's error codes mean.
enum DesktopPlatform {
  /// Windows: known folders, Win32 error codes.
  windows,

  /// Linux: XDG user directories, `errno`.
  linux;

  /// What the OS error [code] of a file operation means for a save.
  SaveFailure failureOf(int code) => switch (this) {
    // ERROR_ACCESS_DENIED; ERROR_HANDLE_DISK_FULL, ERROR_DISK_FULL.
    windows => switch (code) {
      5 => SaveFailure.accessDenied,
      39 || 112 => SaveFailure.noSpace,
      _ => SaveFailure.unavailable,
    },
    // EPERM, EACCES, EROFS; ENOSPC, EDQUOT.
    linux => switch (code) {
      1 || 13 || 30 => SaveFailure.accessDenied,
      28 || 122 => SaveFailure.noSpace,
      _ => SaveFailure.unavailable,
    },
  };

  /// The failed result of [error]: its reason by [failureOf], its code
  /// `os<code>` (`io` when the OS gave none).
  SaveResult$Failed resultOf(FileSystemException error) {
    final code = error.osError?.errorCode;
    return code == null
        ? const SaveResult$Failed(SaveFailure.unavailable, code: 'io')
        : SaveResult$Failed(failureOf(code), code: 'os$code');
  }

  /// Whether the OS error [code] says a file is already there, where `dart:io`
  /// does not raise [PathExistsException] for it.
  bool _isExists(int code) => switch (this) {
    // ERROR_FILE_EXISTS, ERROR_ALREADY_EXISTS.
    windows => code == 80 || code == 183,
    // EEXIST.
    linux => code == 17,
  };
}

/// A folder of the user's that a desktop save goes into.
enum DesktopFolder {
  /// Pictures: photos and still or GIF animations sent to the gallery.
  pictures,

  /// Videos: videos and video animations sent to the gallery.
  videos,

  /// Downloads.
  downloads,
}

/// Where the user's folders are: [WindowsKnownFolders], [XdgUserDirs], or a
/// test's own.
abstract interface class DesktopFolders {
  /// The path of [folder], or null when the system names none.
  Future<String?> pathOf(DesktopFolder folder);
}

/// The file names of a desktop save: what the item's name becomes on disk,
/// and the next free one beside a taken name.
abstract final class DesktopSaveNames {
  /// [name] as one file name both desktops take: a path separator or a
  /// character Windows refuses (`\ / : * ? " < > |`, controls) becomes `_`,
  /// trailing dots and spaces go, a Windows device name (`CON`, `NUL`,
  /// `COM1`, …) gets a leading `_`, and nothing left (or `.` / `..`) is
  /// `file`. The name and the sub-folder are the caller's, so this also
  /// keeps a save inside its folder.
  static String sanitize(String name) {
    var safe = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    safe = safe.replaceFirst(RegExp(r'[. ]+$'), '');
    if (safe.isEmpty) return 'file';
    final stem = safe.split('.').first.toUpperCase();
    if (_deviceNames.hasMatch(stem)) safe = '_$safe';
    return safe;
  }

  static final RegExp _deviceNames = RegExp(
    r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$',
  );

  /// [name] numbered [n] before its extension: `photo (1).jpg`, `README
  /// (1)`; a leading dot starts no extension (`.profile (1)`).
  static String numbered(String name, int n) {
    final dot = name.lastIndexOf('.');
    return dot <= 0
        ? '$name ($n)'
        : '${name.substring(0, dot)} ($n)${name.substring(dot)}';
  }
}

/// The save writer of Windows and Linux: a save is a file in a folder.
///
/// | Destination | Where |
/// | --- | --- |
/// | `gallery(album?)` | Pictures (photos, GIFs) or Videos (videos, video animations), in the album's sub-folder |
/// | `downloads(subfolder?)` | Downloads, in the host's sub-folder |
/// | `ask` | where the user picks in the system save dialog, one per item |
///
/// In a folder a taken name gets ` (1)`, ` (2)`, … before its extension,
/// and the result says it was renamed; the name is claimed by creating the
/// file, so two items of a batch never take the same one. In the dialog the
/// user chose the file, a file already there included, so it is replaced.
/// A dismissed dialog cancels the batch: its item and every one after it.
///
/// The copy streams on a worker isolate ([SaveFileCopy]); a cancel stops it
/// between chunks and the partial file is removed, as on any failure. A
/// host file given with `move` is renamed into place when the volume
/// allows, else copied and then removed. `createdAt` becomes the file's
/// modification time. There is no access to ask for: [access], the
/// platform's, admits every batch, and is checked all the same so a desktop
/// reads like every other platform.
final class DesktopSaveWriter extends SaveWriter$PerItem {
  /// The writer of [os]. [folders] defaults to the system's for [os],
  /// [pickLocation] (the path for a suggested name, null when dismissed) to
  /// the system save dialog through `file_selector`. [access] is the
  /// platform's save access; null admits every batch.
  DesktopSaveWriter(
    this.os, {
    this.access,
    DesktopFolders? folders,
    Future<String?> Function(String suggestedName)? pickLocation,
    int chunkSize = SaveFileCopy.defaultChunkSize,
  }) : _folders =
           folders ??
           switch (os) {
             DesktopPlatform.windows => const WindowsKnownFolders(),
             DesktopPlatform.linux => XdgUserDirs(),
           },
       _pickLocation = pickLocation ?? _pickWithDialog,
       _chunkSize = chunkSize;

  /// The desktop this writer saves on.
  final DesktopPlatform os;

  /// The platform's save access; null admits every batch.
  final PlatformSaveAccess? access;

  final DesktopFolders _folders;
  final Future<String?> Function(String suggestedName) _pickLocation;
  final int _chunkSize;

  static Future<String?> _pickWithDialog(String suggestedName) async =>
      (await getSaveLocation(suggestedName: suggestedName))?.path;

  /// After this many taken names in a row the item fails: a folder holding
  /// `name (1)` to `name (9999)` is not one to keep counting in.
  static const int _maxNumber = 9999;

  @override
  String get platform => os.name;

  @override
  Future<SaveResult$Failed?> admit(
    String jobId,
    SaveDestination destination,
    List<SaveItem> items,
  ) async => access?.admit(jobId, destination);

  @override
  Future<SaveResult> write(
    SaveWrite write, {
    required FetchProgress onProgress,
    required CancellationToken cancellation,
  }) async {
    if (cancellation.isCancelled) return const SaveResult.cancelled();
    final _Place place;
    try {
      place = await _placeOf(write, cancellation);
    } on _Ended catch (ended) {
      return ended.result;
    } on FileSystemException catch (error) {
      return os.resultOf(error);
    }
    try {
      if (!await _fill(write, place.path, onProgress, cancellation)) {
        await _discard(place.path);
        return const SaveResult.cancelled();
      }
    } on FileSystemException catch (error) {
      await _discard(place.path);
      return os.resultOf(error);
    }
    if (write.item.createdAt case final createdAt?) {
      await _stamp(place.path, createdAt);
    }
    return SaveResult.saved(place.path, renamed: place.renamed);
  }

  // --- Where ---

  /// The file [write] goes to, claimed in its folder, or the user's pick.
  Future<_Place> _placeOf(
    SaveWrite write,
    CancellationToken cancellation,
  ) async {
    final name = DesktopSaveNames.sanitize(write.item.name);
    final DesktopFolder folder;
    final String? subfolder;
    switch (write.destination) {
      case SaveDestination$Ask():
        final picked = await _pickLocation(name);
        if (picked != null) return _Place(picked, renamed: false);
        // The user said no to the batch, not to one item: the job's cancel
        // ends this item and stops the ones after it unasked.
        cancellation.cancel();
        throw const _Ended(SaveResult.cancelled());
      case SaveDestination$Gallery(:final album):
        folder = _galleryFolderOf(write);
        subfolder = album;
      case SaveDestination$Downloads(subfolder: final named):
        folder = DesktopFolder.downloads;
        subfolder = named;
    }
    final base = await _folders.pathOf(folder);
    if (base == null) {
      throw const _Ended(
        SaveResult.failed(SaveFailure.unavailable, code: 'noFolder'),
      );
    }
    final directory = subfolder == null
        ? base
        : _join(base, DesktopSaveNames.sanitize(subfolder));
    await Directory(directory).create(recursive: true);
    return _claim(directory, name);
  }

  /// Pictures or Videos: a photo is a picture and a video a video (a `file`
  /// already routed to one of them); an animation goes by its MIME type, a
  /// GIF to Pictures, a looping video to Videos.
  static DesktopFolder _galleryFolderOf(SaveWrite write) =>
      switch (write.kind) {
        SaveItemKind.video => DesktopFolder.videos,
        SaveItemKind.animation
            when write.item.mimeType.trim().toLowerCase().startsWith(
              'video/',
            ) =>
          DesktopFolder.videos,
        _ => DesktopFolder.pictures,
      };

  /// Creates the first free one of [name], `name (1)`, … in [directory].
  /// Creating it is the claim: a check-then-write would let two saves take
  /// the same name.
  Future<_Place> _claim(String directory, String name) async {
    for (var n = 0; n <= _maxNumber; n++) {
      final path = _join(
        directory,
        n == 0 ? name : DesktopSaveNames.numbered(name, n),
      );
      try {
        await File(path).create(exclusive: true);
        return _Place(path, renamed: n > 0);
      } on PathExistsException {
        continue;
      } on FileSystemException catch (error) {
        final code = error.osError?.errorCode;
        if (code != null && os._isExists(code)) continue;
        rethrow;
      }
    }
    throw const _Ended(
      SaveResult.failed(SaveFailure.unavailable, code: 'nameTaken'),
    );
  }

  static String _join(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  // --- The bytes ---

  /// Puts [write]'s content at [path]; false when cancelled.
  Future<bool> _fill(
    SaveWrite write,
    String path,
    FetchProgress onProgress,
    CancellationToken cancellation,
  ) async {
    final item = write.item;
    if (item.bytes case final bytes?) {
      await File(path).writeAsBytes(bytes, flush: true);
      onProgress(bytes.length, bytes.length);
      return true;
    }
    final source = item.path!;
    if (write.move && await _move(source, path, onProgress)) return true;
    final copied = await SaveFileCopy.run(
      source,
      path,
      onProgress: onProgress,
      cancellation: cancellation,
      chunkSize: _chunkSize,
    );
    // A move that had to copy (another volume) consumes the source after;
    // a source that will not go leaves the save made.
    if (copied && write.move) {
      try {
        await File(source).delete();
      } on FileSystemException catch (error, stackTrace) {
        _report(error, stackTrace, 'while removing a moved file\'s source');
      }
    }
    return copied;
  }

  /// Renames [source] onto [path]; false when the volume does not allow
  /// it, so the caller copies.
  static Future<bool> _move(
    String source,
    String path,
    FetchProgress onProgress,
  ) async {
    final length = await File(source).length();
    try {
      // The claimed (or picked) file goes first: a rename onto an existing
      // file is not replacing on every file system.
      await File(path).delete();
      await File(source).rename(path);
    } on FileSystemException {
      return false;
    }
    onProgress(length, length);
    return true;
  }

  /// Removes what a write that did not finish left at [path].
  static Future<void> _discard(String path) async {
    try {
      await File(path).delete();
    } on PathNotFoundException {
      // Nothing was left.
    } on FileSystemException catch (error, stackTrace) {
      _report(error, stackTrace, 'while removing a partial saved file');
    }
  }

  /// Sets [path]'s modification time to [createdAt]. A file system that
  /// refuses it leaves the item saved: the date is a courtesy, the bytes
  /// are the save.
  static Future<void> _stamp(String path, DateTime createdAt) async {
    try {
      await File(path).setLastModified(createdAt);
    } on FileSystemException catch (error, stackTrace) {
      _report(error, stackTrace, 'while dating a saved file');
    }
  }

  static void _report(Object error, StackTrace stackTrace, String context) =>
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'mpx_library',
          context: ErrorDescription(context),
        ),
      );
}

/// Where an item is written, and whether its name was taken.
final class _Place {
  const _Place(this.path, {required this.renamed});

  final String path;
  final bool renamed;
}

/// Ends a write early with [result], from inside the lookup of its place.
final class _Ended implements Exception {
  const _Ended(this.result);

  final SaveResult result;
}
