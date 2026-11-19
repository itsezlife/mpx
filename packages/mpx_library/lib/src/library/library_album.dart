import 'package:meta/meta.dart';
import 'package:mpx_library/src/library/library_asset.dart';

/// The platform's id of a library album. Opaque, like [LibraryAssetId].
extension type const LibraryAlbumId(String value) {}

/// Which album a [LibraryAlbum] is, so the host can name the built-in ones
/// in its own strings.
enum LibraryAlbumKind {
  /// Every photo and video: Android's All media, iOS's Recents. Always the
  /// first album.
  allMedia,

  /// Every photo (Android).
  allPhotos,

  /// Every video (Android).
  allVideos,

  /// What the device's camera took (Android).
  camera,

  /// The user's favourites (iOS).
  favourites,

  /// An album the platform keeps by itself: a folder bucket on Android, a
  /// smart album (screenshots, selfies, slow-mo) on iOS.
  system,

  /// An album the user made.
  user,
}

/// One album of the device's media library.
///
/// The order of `MediaLibrary.albums` is the platform's: the all-media album
/// first, then Android's All photos, All videos, Camera and folder buckets
/// by recency, or iOS's Favorites, non-empty smart albums and user albums.
@immutable
final class LibraryAlbum {
  /// Describes an album.
  const LibraryAlbum({
    required this.id,
    required this.kind,
    required this.title,
    required this.count,
    this.cover,
    this.startsAtEnd = false,
  }) : assert(count >= 0, 'An album count is not negative.');

  /// The platform's id; pages are read by it.
  final LibraryAlbumId id;

  /// Which album it is.
  final LibraryAlbumKind kind;

  /// The platform's name of the album; a host names [LibraryAlbumKind]'s
  /// built-in albums in its own strings instead.
  final String title;

  /// How many assets the album held when it was read.
  final int count;

  /// The asset that represents the album (its newest), when it has one.
  final LibraryAsset? cover;

  /// Whether a grid of the album opens scrolled to its end (iOS albums other
  /// than Recents are oldest first and open at the newest).
  final bool startsAtEnd;

  @override
  bool operator ==(Object other) =>
      other is LibraryAlbum &&
      other.id == id &&
      other.kind == kind &&
      other.title == title &&
      other.count == count &&
      other.cover == cover &&
      other.startsAtEnd == startsAtEnd;

  @override
  int get hashCode => Object.hash(id, kind, title, count, cover, startsAtEnd);

  @override
  String toString() =>
      'LibraryAlbum(${id.value}, ${kind.name}, "$title", $count)';
}
