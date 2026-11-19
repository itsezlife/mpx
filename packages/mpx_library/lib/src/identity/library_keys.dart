import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/library/library_asset.dart';

/// What a library key names: an asset's original, or its thumbnail at a
/// pixel size.
@immutable
final class LibraryKeyTarget {
  /// Names [asset], or its thumbnail when [thumbnailPixels] is set.
  const LibraryKeyTarget(this.asset, {this.thumbnailPixels});

  /// The asset.
  final LibraryAssetId asset;

  /// The thumbnail's bounding square in pixels; null for the original.
  final int? thumbnailPixels;

  /// Whether the key names a thumbnail.
  bool get isThumbnail => thumbnailPixels != null;

  @override
  bool operator ==(Object other) =>
      other is LibraryKeyTarget &&
      other.asset == asset &&
      other.thumbnailPixels == thumbnailPixels;

  @override
  int get hashCode => Object.hash(asset, thumbnailPixels);

  @override
  String toString() =>
      'LibraryKeyTarget(${asset.value}'
      '${isThumbnail ? ' @ $thumbnailPixels px' : ''})';
}

/// The media keys and descriptors of library assets.
///
/// | Names | Key |
/// | --- | --- |
/// | an asset | `MediaKey.external('device-library:<id>')` |
/// | its thumbnail at `n` px | `MediaKey.external('device-library-thumbnail:<n>:<id>')` |
///
/// A thumbnail is a key of its own, with the size in it, so the asset cache
/// keeps each size apart from the others and from the original. No new
/// `MediaKey` variant: `external` already means media from outside the
/// host's backend.
abstract final class LibraryKeys {
  static const String _assetPrefix = 'device-library:';
  static const String _thumbnailPrefix = 'device-library-thumbnail:';

  /// The key of [asset]'s original.
  static MediaKey$External libraryKeyOf(LibraryAsset asset) => keyOf(asset.id);

  /// The key of the asset [id]'s original.
  static MediaKey$External keyOf(LibraryAssetId id) =>
      MediaKey$External('$_assetPrefix${id.value}');

  /// The key of [asset]'s thumbnail fitted into a square of [pixels].
  static MediaKey$External thumbnailKeyOf(LibraryAsset asset, int pixels) {
    if (pixels <= 0) throw ArgumentError.value(pixels, 'pixels', 'not > 0');
    return MediaKey$External('$_thumbnailPrefix$pixels:${asset.id.value}');
  }

  /// What [key] names, or null when it is not a library key.
  static LibraryKeyTarget? read(MediaKey key) {
    if (key is! MediaKey$External) return null;
    final id = key.id;
    if (id.startsWith(_assetPrefix)) {
      final asset = id.substring(_assetPrefix.length);
      return asset.isEmpty ? null : LibraryKeyTarget(LibraryAssetId(asset));
    }
    if (id.startsWith(_thumbnailPrefix)) {
      final rest = id.substring(_thumbnailPrefix.length);
      final colon = rest.indexOf(':');
      if (colon <= 0) return null;
      final pixels = int.tryParse(rest.substring(0, colon));
      final asset = rest.substring(colon + 1);
      if (pixels == null || pixels <= 0 || asset.isEmpty) return null;
      return LibraryKeyTarget(LibraryAssetId(asset), thumbnailPixels: pixels);
    }
    return null;
  }

  /// The thumbnail size of an asset key's thumbnail part when its
  /// descriptor names none.
  static const int defaultThumbnailPixels = 320;

  /// The descriptor of [asset]'s original: a still, an animated image or a
  /// video, with the size and duration the platform reported.
  ///
  /// With [thumbnailPixels] the descriptor names a thumbnail of that size,
  /// which `LibraryFetcher` serves for its thumbnail part, so a surface
  /// showing the original draws the thumbnail first.
  static MediaDescriptor descriptorOf(
    LibraryAsset asset, {
    int? thumbnailPixels,
  }) {
    final animated = asset.has(LibraryAssetSubtype.animated);
    return MediaDescriptor(
      thumbnail: thumbnailPixels == null
          ? null
          : MediaThumbnailRef('$thumbnailPixels'),
      key: libraryKeyOf(asset),
      kind: switch (asset.kind) {
        LibraryAssetKind.video => MediaKind.video,
        LibraryAssetKind.photo when animated => MediaKind.animatedImage,
        LibraryAssetKind.photo => MediaKind.still,
      },
      animated: animated || asset.kind == LibraryAssetKind.video,
      dimensions: asset.dimensions,
      duration: asset.duration,
    );
  }

  /// The descriptor of [asset]'s thumbnail at [pixels]: a still whose size
  /// is the asset's fitted into the square, never scaled up.
  static MediaDescriptor thumbnailDescriptorOf(
    LibraryAsset asset,
    int pixels,
  ) => MediaDescriptor(
    key: thumbnailKeyOf(asset, pixels),
    kind: MediaKind.still,
    dimensions: switch (asset.dimensions) {
      final size? => _fit(size, pixels),
      null => null,
    },
  );

  static MediaDimensions _fit(MediaDimensions size, int pixels) {
    final longSide = math.max(size.width, size.height);
    if (longSide <= pixels) return size;
    final scale = pixels / longSide;
    return MediaDimensions(
      math.max(1, (size.width * scale).round()),
      math.max(1, (size.height * scale).round()),
    );
  }
}
