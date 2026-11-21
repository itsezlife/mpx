import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_ui/src/library/library_pages.dart';

/// A photo or video the host made while the picker was open (with the
/// camera), shown ahead of the library's items.
///
/// The host owns its captures: it keeps the list (`LibraryPicker.captures`)
/// and its selection, which holds a capture by [key] like any item. The
/// picker only shows them: first in the grid, newest first, with the same
/// cell, marks and selection number as a library item, and first in the
/// viewer's pages.
@immutable
final class PickerCapture {
  /// Describes a capture stored under [key].
  const PickerCapture({
    required this.key,
    required this.kind,
    this.dimensions,
    this.duration,
    this.byteSize,
    this.created,
  });

  /// Where the capture's bytes resolve (the host's capture cache).
  final MediaKey$Local key;

  /// Photo or video.
  final LibraryAssetKind kind;

  /// The pixel size as displayed, when known.
  final MediaDimensions? dimensions;

  /// A video's playing time, when known.
  final Duration? duration;

  /// The file's size in bytes, when known.
  final int? byteSize;

  /// When it was taken, when known.
  final DateTime? created;

  static const String _prefix = 'mpx-capture:';

  /// The capture as the grid and the viewer read an item: an asset whose id
  /// names [key] (`PickerCaptureKeys.isCapture` tells it apart).
  LibraryAsset get asset => LibraryAsset(
    id: LibraryAssetId('$_prefix${key.uuid}'),
    kind: kind,
    dimensions: dimensions,
    duration: duration,
    created: created,
    byteSize: byteSize,
  );

  /// What the asset cache needs to show it.
  MediaDescriptor get descriptor => MediaDescriptor(
    key: key,
    kind: kind == LibraryAssetKind.video ? MediaKind.video : MediaKind.still,
    animated: kind == LibraryAssetKind.video,
    dimensions: dimensions,
    duration: duration,
  );

  @override
  bool operator ==(Object other) =>
      other is PickerCapture &&
      other.key == key &&
      other.kind == kind &&
      other.dimensions == dimensions &&
      other.duration == duration &&
      other.byteSize == byteSize &&
      other.created == created;

  @override
  int get hashCode =>
      Object.hash(key, kind, dimensions, duration, byteSize, created);

  @override
  String toString() => 'PickerCapture(${key.uuid}, ${kind.name})';
}

/// The keys of what the picker shows, a library asset or a capture's asset
/// ([PickerCapture.asset]) alike.
abstract final class PickerCaptureKeys {
  /// Whether [asset] stands for a capture.
  static bool isCapture(LibraryAsset asset) =>
      asset.id.value.startsWith(PickerCapture._prefix);

  /// The key the selection holds for [asset]: the capture's own key, or the
  /// library key.
  static MediaKey keyOf(LibraryAsset asset) => isCapture(asset)
      ? MediaKey$Local(asset.id.value.substring(PickerCapture._prefix.length))
      : LibraryKeys.libraryKeyOf(asset);

  /// What a cell of [pixels] shows for [asset]: the capture itself, or the
  /// library thumbnail.
  static MediaKey thumbnailKeyOf(LibraryAsset asset, int pixels) =>
      isCapture(asset)
      ? keyOf(asset)
      : LibraryKeys.thumbnailKeyOf(asset, pixels);

  /// The descriptor of [thumbnailKeyOf].
  static MediaDescriptor thumbnailDescriptorOf(
    LibraryAsset asset,
    int pixels,
  ) => isCapture(asset)
      ? _captureDescriptor(asset)
      : LibraryKeys.thumbnailDescriptorOf(asset, pixels);

  /// The descriptor of [asset]'s original, with a library thumbnail of
  /// [thumbnailPixels] as its stand-in.
  static MediaDescriptor descriptorOf(
    LibraryAsset asset, {
    int? thumbnailPixels,
  }) => isCapture(asset)
      ? _captureDescriptor(asset)
      : LibraryKeys.descriptorOf(asset, thumbnailPixels: thumbnailPixels);

  static MediaDescriptor _captureDescriptor(LibraryAsset asset) =>
      PickerCapture(
        key: keyOf(asset) as MediaKey$Local,
        kind: asset.kind,
        dimensions: asset.dimensions,
        duration: asset.duration,
      ).descriptor;
}

/// What the picker pages: the host's [captures], newest first, then the
/// album's [pages]. Notifies when either changes.
final class PickerItems extends ChangeNotifier {
  /// Joins [captures] (in the order taken, oldest first) ahead of [pages].
  PickerItems(this.pages, {this.captures}) {
    pages.addListener(notifyListeners);
    captures?.addListener(_onCaptures);
    _onCaptures(notify: false);
  }

  /// The album's pages.
  final LibraryPages pages;

  /// The host's captures, oldest first; null for none.
  final ValueListenable<List<PickerCapture>>? captures;

  List<LibraryAsset> _captured = const [];

  void _onCaptures({bool notify = true}) {
    final list = captures?.value ?? const <PickerCapture>[];
    _captured = [for (final capture in list.reversed) capture.asset];
    if (notify) notifyListeners();
  }

  /// How many captures come first.
  int get captureCount => _captured.length;

  /// Captures and album items.
  int get total => _captured.length + pages.total;

  /// The item at [index], or null while its page loads.
  LibraryAsset? assetAt(int index) {
    if (index < 0) return null;
    if (index < _captured.length) return _captured[index];
    return pages.assetAt(index - _captured.length);
  }

  /// As [LibraryPages.nearestAt], over the captures and the album.
  LibraryAsset? nearestAt(int index) {
    if (index < 0 || index >= total) return null;
    if (index < _captured.length) return _captured[index];
    return pages.nearestAt(index - _captured.length);
  }

  /// The index of the item the selection holds as [key], among the
  /// captures and the pages read, or null.
  int? indexOf(MediaKey key) {
    for (var i = 0; i < _captured.length; i++) {
      if (PickerCaptureKeys.keyOf(_captured[i]) == key) return i;
    }
    return switch (LibraryKeys.read(key)) {
      final target? when !target.isThumbnail => switch (pages.indexOf(
        target.asset,
      )) {
        final index? => index + _captured.length,
        null => null,
      },
      _ => null,
    };
  }

  @override
  void dispose() {
    pages.removeListener(notifyListeners);
    captures?.removeListener(_onCaptures);
    super.dispose();
  }
}
