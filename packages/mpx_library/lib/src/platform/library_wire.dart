import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/library/library_access.dart';
import 'package:mpx_library/src/library/library_album.dart';
import 'package:mpx_library/src/library/library_asset.dart';

/// The maps the native library adapters answer with, read into the
/// package's types. One wire for Android and Apple, so one Dart adapter
/// serves both.
///
/// | Map | Fields |
/// | --- | --- |
/// | access | `platform` (`android` / `apple`); Android: `sdk`, `images`, `video`, `selected`, `legacy`, `asked`; Apple: `status` |
/// | asset | `id`, `kind` (`photo` / `video`), `subtypes`, `width`, `height`, `durationMs`, `createdMs`, `modifiedMs`, `mime`, `size` (bytes), `cloud` |
/// | album | `id`, `kind`, `title`, `count`, `cover` (an asset), `startsAtEnd` |
abstract final class LibraryWire {
  /// The access an access map reports.
  ///
  /// Android has no "not asked" state of its own: the adapter remembers
  /// whether it asked (`asked`). On API 34 and later the user-selected
  /// permission alone is [LibraryAccess.partial]; on 33 images and video
  /// are both needed; below, the legacy storage permission. A missing grant
  /// after an ask is [LibraryAccess.denied].
  static LibraryAccess accessOf(Map<Object?, Object?> map) {
    switch (map['platform']) {
      case 'apple':
        return switch (map['status']) {
          'notDetermined' => LibraryAccess.notDetermined,
          'denied' => LibraryAccess.denied,
          'limited' => LibraryAccess.limited,
          'authorized' => LibraryAccess.full,
          _ => LibraryAccess.restricted,
        };
      case 'android':
        final sdk = map['sdk'] as int? ?? 0;
        final images = map['images'] == true;
        final video = map['video'] == true;
        final selected = map['selected'] == true;
        final legacy = map['legacy'] == true;
        final full = sdk >= 33 ? images && video : legacy;
        if (full) return LibraryAccess.full;
        if (sdk >= 34 && selected) return LibraryAccess.partial;
        return map['asked'] == true
            ? LibraryAccess.denied
            : LibraryAccess.notDetermined;
      default:
        return LibraryAccess.restricted;
    }
  }

  /// The asset an asset map describes.
  static LibraryAsset assetOf(Map<Object?, Object?> map) {
    final width = map['width'] as int? ?? 0;
    final height = map['height'] as int? ?? 0;
    final durationMs = map['durationMs'] as int?;
    final created = map['createdMs'] as int?;
    final modified = map['modifiedMs'] as int?;
    return LibraryAsset(
      id: LibraryAssetId(map['id']! as String),
      kind: map['kind'] == 'video'
          ? LibraryAssetKind.video
          : LibraryAssetKind.photo,
      subtypes: {
        for (final name in (map['subtypes'] as List<Object?>?) ?? const [])
          ?_subtype(name),
      },
      dimensions: width > 0 && height > 0
          ? MediaDimensions(width, height)
          : null,
      duration: durationMs == null || durationMs <= 0
          ? null
          : Duration(milliseconds: durationMs),
      created: created == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(created, isUtc: true),
      modified: modified == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modified, isUtc: true),
      mimeType: map['mime'] as String?,
      byteSize: switch (map['size']) {
        final int size when size > 0 => size,
        _ => null,
      },
    );
  }

  /// The album an album map describes.
  static LibraryAlbum albumOf(Map<Object?, Object?> map) => LibraryAlbum(
    id: LibraryAlbumId(map['id']! as String),
    kind:
        LibraryAlbumKind.values.asNameMap()[map['kind']] ??
        LibraryAlbumKind.system,
    title: map['title'] as String? ?? '',
    count: map['count'] as int? ?? 0,
    cover: switch (map['cover']) {
      final Map<Object?, Object?> cover => assetOf(cover),
      _ => null,
    },
    startsAtEnd: map['startsAtEnd'] == true,
  );

  static LibraryAssetSubtype? _subtype(Object? name) =>
      LibraryAssetSubtype.values.asNameMap()[name];
}
