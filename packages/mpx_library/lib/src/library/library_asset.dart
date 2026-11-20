import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';

/// The platform's id of a library asset: a MediaStore row id on Android, a
/// PhotoKit local identifier on iOS. Opaque; only the adapter that issued it
/// reads it.
extension type const LibraryAssetId(String value) {}

/// What a library asset is.
enum LibraryAssetKind {
  /// A still picture (also an animated image such as a GIF; see
  /// [LibraryAssetSubtype.animated]).
  photo,

  /// A video.
  video,
}

/// A trait the platform reports on a library asset; an asset may have any
/// number of them.
enum LibraryAssetSubtype {
  /// A photo with a short video around it (a live photo).
  live,

  /// A video recorded at a high frame rate to play slowed down.
  slowMotion,

  /// A video recorded at a low frame rate to play sped up.
  timeLapse,

  /// The user marked it as a favourite.
  favourite,

  /// A capture of the device's screen.
  screenshot,

  /// A picture that moves (a GIF, an animated WebP).
  animated,
}

/// One item of the device's media library, as an album page returns it.
///
/// Only facts: which item ([id]), what it is, and what the platform knows
/// about it without reading its bytes. Its media key and descriptors come
/// from `LibraryKeys`.
@immutable
final class LibraryAsset {
  /// Describes an asset.
  const LibraryAsset({
    required this.id,
    required this.kind,
    this.subtypes = const {},
    this.dimensions,
    this.duration,
    this.created,
    this.modified,
    this.mimeType,
    this.byteSize,
  });

  /// The platform's id.
  final LibraryAssetId id;

  /// Photo or video.
  final LibraryAssetKind kind;

  /// The traits the platform reports.
  final Set<LibraryAssetSubtype> subtypes;

  /// The pixel size as displayed (after the stored orientation), when known.
  final MediaDimensions? dimensions;

  /// The playing time of a video, when known.
  final Duration? duration;

  /// When the item was taken or created, when known.
  final DateTime? created;

  /// When the item last changed, when known.
  final DateTime? modified;

  /// The MIME type of the original, when known.
  final String? mimeType;

  /// The original's size in bytes, when the platform tells it without
  /// reading the file (Android); null otherwise.
  final int? byteSize;

  /// Whether the platform reports [subtype].
  bool has(LibraryAssetSubtype subtype) => subtypes.contains(subtype);

  @override
  bool operator ==(Object other) =>
      other is LibraryAsset &&
      other.id == id &&
      other.kind == kind &&
      _sameSubtypes(other.subtypes, subtypes) &&
      other.dimensions == dimensions &&
      other.duration == duration &&
      other.created == created &&
      other.modified == modified &&
      other.mimeType == mimeType &&
      other.byteSize == byteSize;

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    Object.hashAllUnordered(subtypes),
    dimensions,
    duration,
    created,
    modified,
    mimeType,
    byteSize,
  );

  @override
  String toString() => 'LibraryAsset(${id.value}, ${kind.name})';

  static bool _sameSubtypes(
    Set<LibraryAssetSubtype> a,
    Set<LibraryAssetSubtype> b,
  ) => a.length == b.length && a.containsAll(b);
}
