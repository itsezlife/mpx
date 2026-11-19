import 'package:meta/meta.dart';
import 'package:mpx_library/src/library/library_album.dart';
import 'package:mpx_library/src/library/library_asset.dart';

/// The library changed after pages were read: pages read before it may be
/// stale, and pages read after it already reflect it.
///
/// A change event is the only way already-returned assets move: without one
/// a page read again at the same offset returns the same assets.
@immutable
sealed class LibraryChange {
  const LibraryChange();

  /// What changed in [album].
  const factory LibraryChange.album(
    LibraryAlbumId album, {
    Set<LibraryAssetId> inserted,
    Set<LibraryAssetId> removed,
    Set<LibraryAssetId> changed,
  }) = LibraryChange$Album;

  /// Anything may have changed (the platform told no detail, or the albums
  /// themselves changed): read the albums and the pages again.
  const factory LibraryChange.reload() = LibraryChange$Reload;
}

/// A [LibraryChange] inside one album, with the assets it touched.
final class LibraryChange$Album extends LibraryChange {
  /// Describes a change of [album].
  const LibraryChange$Album(
    this.album, {
    this.inserted = const {},
    this.removed = const {},
    this.changed = const {},
  });

  /// The album that changed.
  final LibraryAlbumId album;

  /// Assets that joined the album.
  final Set<LibraryAssetId> inserted;

  /// Assets that left the album.
  final Set<LibraryAssetId> removed;

  /// Assets whose content or facts changed in place.
  final Set<LibraryAssetId> changed;

  @override
  bool operator ==(Object other) =>
      other is LibraryChange$Album &&
      other.album == album &&
      _same(other.inserted, inserted) &&
      _same(other.removed, removed) &&
      _same(other.changed, changed);

  @override
  int get hashCode => Object.hash(
    album,
    Object.hashAllUnordered(inserted),
    Object.hashAllUnordered(removed),
    Object.hashAllUnordered(changed),
  );

  @override
  String toString() =>
      'LibraryChange.album(${album.value}, +${inserted.length} '
      '-${removed.length} ~${changed.length})';

  static bool _same(Set<LibraryAssetId> a, Set<LibraryAssetId> b) =>
      a.length == b.length && a.containsAll(b);
}

/// A [LibraryChange] without detail: everything is read again.
final class LibraryChange$Reload extends LibraryChange {
  /// Creates the reload event.
  const LibraryChange$Reload();

  @override
  bool operator ==(Object other) => other is LibraryChange$Reload;

  @override
  int get hashCode => (LibraryChange$Reload).hashCode;

  @override
  String toString() => 'LibraryChange.reload()';
}
