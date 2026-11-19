import 'dart:async';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/identity/library_keys.dart';
import 'package:mpx_library/src/library/media_library.dart';

/// The [ContentFetcher] of library keys (`LibraryKeys`): thumbnails from the
/// platform's thumbnail API, originals as file leases.
///
/// The host composes it ahead of its network fetcher, routing the keys
/// [handles] accepts here; any other key fails as permanent. Only a
/// cloud-held original is a download ([needsDownload]); a thumbnail never
/// is, so a grid of thumbnails shows no download.
final class LibraryFetcher implements ContentFetcher {
  /// Creates the fetcher over [library].
  const LibraryFetcher(this.library);

  /// The library the bytes come from.
  final MediaLibrary library;

  /// Whether [key] is a library key this fetcher serves.
  static bool handles(MediaKey key) => LibraryKeys.read(key) != null;

  @override
  Future<FetchedContent> fetch(FetchRequest request) async {
    final target = LibraryKeys.read(request.descriptor.key);
    if (target == null) {
      throw FetchFailure.permanent(
        'not a library key: ${request.descriptor.key}',
      );
    }
    try {
      final pixels =
          target.thumbnailPixels ??
          switch (request.part) {
            FetchPart.thumbnail => _pixelsOf(request.descriptor),
            FetchPart.content => null,
          };
      if (pixels != null) {
        return FetchedContent.bytes(
          await library.thumbnail(
            target.asset,
            pixels: pixels,
            cancellation: request.cancellation,
          ),
        );
      }
      final lease = await library.original(
        target.asset,
        onProgress: request.onProgress,
        cancellation: request.cancellation,
      );
      return FetchedContent.file(
        lease.path,
        onRelease: () => unawaited(lease.release()),
      );
    } on LibraryAssetUnavailable catch (error) {
      throw FetchFailure.permanent(error.message, error);
    } on LibraryDownloadFailed catch (error) {
      throw FetchFailure.transient(error.message, error);
    }
  }

  @override
  bool needsDownload(MediaKey key) {
    final target = LibraryKeys.read(key);
    if (target == null || target.isThumbnail) return false;
    return library.isCloudHeld(target.asset);
  }

  // The thumbnail part of an asset key: the size `LibraryKeys.descriptorOf`
  // wrote into the descriptor's thumbnail reference.
  static int _pixelsOf(MediaDescriptor descriptor) =>
      int.tryParse(descriptor.thumbnail?.value ?? '') ??
      LibraryKeys.defaultThumbnailPixels;
}
