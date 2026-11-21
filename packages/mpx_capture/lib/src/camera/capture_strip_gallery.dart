import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// The host's media that a camera page's strip lists after its shots: the
/// album the host's picker shows, so the strip offers the whole gallery as
/// the picker does, the shots first.
///
/// The album can hold thousands of items, so the strip asks only for the
/// ones it builds: [itemAt] answers what is loaded, may start loading the
/// rest, and the gallery notifies when more is in (or [count] changed).
abstract interface class CaptureStripGallery implements Listenable {
  /// How many items the album holds.
  int get count;

  /// The item at [index] (0-based in the album) with a thumbnail of
  /// [thumbnailPixels] square, or null while it loads: its cell shows the
  /// strip's background until the gallery notifies.
  CaptureStripItem? itemAt(int index, {required int thumbnailPixels});
}

/// One item of a [CaptureStripGallery].
@immutable
final class CaptureStripItem {
  /// Describes an item by its [key] in the host's selection, the still its
  /// cell draws, and a video's [duration].
  const CaptureStripItem({
    required this.key,
    required this.thumbnail,
    this.duration,
  });

  /// The item's key in the host's selection: what the strip's order and
  /// toggle callbacks are given.
  final MediaKey key;

  /// The still the cell draws, resolved through the asset cache.
  final MediaDescriptor thumbnail;

  /// A video's duration, which the cell shows; null for a photo.
  final Duration? duration;

  @override
  bool operator ==(Object other) =>
      other is CaptureStripItem &&
      other.key == key &&
      other.thumbnail == thumbnail &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(key, thumbnail, duration);
}
