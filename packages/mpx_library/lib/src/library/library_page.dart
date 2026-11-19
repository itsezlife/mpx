import 'package:meta/meta.dart';
import 'package:mpx_library/src/library/library_album.dart';
import 'package:mpx_library/src/library/library_asset.dart';

/// A window of an album's assets, by offset in the album's order (Android:
/// newest first; iOS: Recents newest first, other albums oldest first).
@immutable
final class LibraryPage {
  /// Creates a page of [assets] that starts at [offset] of [album], which
  /// held [total] assets when it was read.
  LibraryPage({
    required this.album,
    required this.offset,
    required List<LibraryAsset> assets,
    required this.total,
  }) : assets = List.unmodifiable(assets),
       assert(offset >= 0, 'A page offset is not negative.');

  /// The album the page is of.
  final LibraryAlbumId album;

  /// The position of the first asset in the album.
  final int offset;

  /// The assets, in the album's order; empty past the end.
  final List<LibraryAsset> assets;

  /// The album's asset count when the page was read.
  final int total;

  /// The offset of the asset after the last one.
  int get end => offset + assets.length;

  /// Whether no asset follows this page.
  bool get isLast => end >= total;

  @override
  String toString() => 'LibraryPage(${album.value}, $offset..$end of $total)';
}
