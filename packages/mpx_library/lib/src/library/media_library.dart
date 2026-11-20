import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/library/library_access.dart';
import 'package:mpx_library/src/library/library_album.dart';
import 'package:mpx_library/src/library/library_asset.dart';
import 'package:mpx_library/src/library/library_change.dart';
import 'package:mpx_library/src/library/library_page.dart';

/// The file of an asset's original, lent by the platform until [release].
///
/// The file belongs to the adapter (a copy it made, or the platform's own
/// file): the host reads it and never moves or deletes it.
abstract interface class LibraryFileLease {
  /// Absolute path of the file.
  String get path;

  /// The MIME type of the file, when known.
  String? get mimeType;

  /// Gives the file back; the path may stop existing. Idempotent.
  Future<void> release();
}

/// Why a library read did not produce what was asked.
sealed class LibraryException implements Exception {
  const LibraryException(this.message);

  /// What happened, for logs.
  final String message;
}

/// The asset is gone, or the current access does not cover it. Repeating
/// the read unchanged will not help.
final class LibraryAssetUnavailable extends LibraryException {
  /// Creates the error for [asset].
  const LibraryAssetUnavailable(this.asset, [String message = 'unavailable'])
    : super(message);

  /// The asset asked for.
  final LibraryAssetId asset;

  @override
  String toString() => 'LibraryAssetUnavailable(${asset.value}): $message';
}

/// A cloud-held original could not be downloaded (offline, a busy server);
/// worth repeating later.
final class LibraryDownloadFailed extends LibraryException {
  /// Creates the error for [asset].
  const LibraryDownloadFailed(this.asset, super.message);

  /// The asset asked for.
  final LibraryAssetId asset;

  @override
  String toString() => 'LibraryDownloadFailed(${asset.value}): $message';
}

/// The device's photo and video library: access, albums, paged assets,
/// change events, thumbnails and originals.
///
/// Implementations: the platform adapters (MediaStore on Android, PhotoKit
/// on iOS) and `FakeMediaLibrary` in `testing.dart`; all meet
/// `MediaLibraryContract`.
///
/// ## Contract
///
/// - [albums] and [page] read off the UI isolate's critical path and never
///   hold the whole library in memory. Without read access
///   ([LibraryAccess.canRead] false) both complete empty.
/// - A [LibraryPage] is a window by offset: consecutive pages are gap-free
///   and without duplicates, and an offset at or past the end gives an empty
///   page. Without a [changes] event in between, the same window read again
///   returns the same assets in the same order.
/// - [access] notifies on every transition, from [requestAccess], from
///   [manageSelected] and from the system settings (re-read on resume).
/// - [manageSelected] does nothing and answers false unless [access] is
///   [LibraryAccess.limited] or [LibraryAccess.partial].
/// - [thumbnail] and [original] fail with [LibraryAssetUnavailable] for an
///   asset that is gone or not covered, and [original] with
///   [LibraryDownloadFailed] when a cloud-held original cannot be fetched.
abstract interface class MediaLibrary {
  /// The current access; listen for transitions.
  ValueListenable<LibraryAccess> get access;

  /// Shows the system prompt when access is [LibraryAccess.notDetermined];
  /// otherwise changes nothing. Completes with the access after it.
  Future<LibraryAccess> requestAccess();

  /// Lets the user change which items a limited or partial access covers
  /// (the system's choice sheet). True when the system was asked; false,
  /// with nothing shown, under any other access.
  Future<bool> manageSelected();

  /// Opens the system settings of the host app, where the user changes the
  /// access.
  Future<void> openSettings();

  /// The albums, all-media first; empty without read access.
  Future<List<LibraryAlbum>> albums();

  /// Up to [limit] assets of [album] from [offset] on.
  ///
  /// [offset] is not negative and [limit] is positive; an unknown album
  /// gives an empty page.
  Future<LibraryPage> page(
    LibraryAlbumId album, {
    required int offset,
    required int limit,
  });

  /// Changes after pages were read (debounced by the adapter). Broadcast.
  Stream<LibraryChange> get changes;

  /// The encoded thumbnail of [asset] fitted into a square of [pixels], from
  /// the platform's thumbnail API (a cloud-held asset's thumbnail may be
  /// fetched on demand).
  Future<Uint8List> thumbnail(
    LibraryAssetId asset, {
    required int pixels,
    CancellationToken? cancellation,
  });

  /// The original of [asset] as a file, lent until the lease is released.
  ///
  /// A cloud-held original downloads first and reports its bytes through
  /// [onProgress]; a local one is never reported.
  Future<LibraryFileLease> original(
    LibraryAssetId asset, {
    FetchProgress? onProgress,
    CancellationToken? cancellation,
  });

  /// A URI a platform player reads [asset]'s video from in place, without
  /// a copy: on Android its MediaStore content URI, on iOS the file URL of
  /// its original (a cloud-held one downloads first). Null for a photo, an
  /// asset that is gone, or where the platform has none.
  Future<Uri?> playable(LibraryAssetId asset);

  /// Whether reading [asset]'s original downloads it, from what the adapter
  /// knows without waiting; false when it cannot tell.
  bool isCloudHeld(LibraryAssetId asset);

  /// Stops observing the library and releases what the adapter holds.
  Future<void> dispose();
}
