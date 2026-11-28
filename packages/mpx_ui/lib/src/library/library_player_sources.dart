import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_player/mpx_player.dart';

/// Where a native player reads a media library video: the platform's URI of
/// the item, opened in place ([PlayerSource.local]), with no copy and nothing
/// through the bytes cache.
///
/// A host that shows library videos in the viewer (the picker-mode viewer)
/// answers its players' `sourcesOf` for library keys from here, ahead of
/// its own sources:
///
/// ```dart
/// sourcesOf: (key) => LibraryFetcher.handles(key)
///     ? LibraryPlayerSources.of(library, key)
///     : networkSourcesOf(key),
/// ```
abstract final class LibraryPlayerSources {
  /// The sources of [key]: one local source for a library video, none for
  /// a photo, a thumbnail key, a key from elsewhere, or an item the library
  /// cannot hand over.
  static Future<List<PlayerSource>> of(
    MediaLibrary library,
    MediaKey key,
  ) async {
    final target = LibraryKeys.read(key);
    if (target == null || target.isThumbnail) return const [];
    final uri = await library.playable(target.asset);
    return uri == null ? const [] : [PlayerSource.local(uri)];
  }
}
