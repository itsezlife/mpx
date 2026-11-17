import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// What a gallery item is, as the viewer shows it.
enum GalleryMediaKind {
  /// A still picture: zoom, no playback controls.
  photo,

  /// A video with sound and controls.
  video,

  /// A silent loop without controls.
  animation,
}

/// One item of a gallery: which media, what kind, how large.
@immutable
final class GalleryItem {
  /// Creates an item.
  const GalleryItem(
    this.key, {
    this.kind = GalleryMediaKind.photo,
    this.size,
    this.hasAudio = true,
    this.descriptor,
    this.downloadContext,
  });

  /// Which media.
  final MediaKey key;

  /// What kind of media.
  final GalleryMediaKind kind;

  /// The media's size in pixels, when known; the viewer fits the picture by
  /// its aspect ratio, and falls back to the origin's when it is null.
  final Size? size;

  /// Whether a video has a sound track; the loop rule of some policies
  /// reads it.
  final bool hasAudio;

  /// What the host knows about the media (its preview, thumbnail, size and
  /// byte size), or null. The viewer tells the cache before a page of it
  /// attaches, so the page draws the preview and the thumbnail of media the
  /// cache has not seen.
  final MediaDescriptor? descriptor;

  /// Where the item shows, for the cache's auto-download policy: the page's
  /// tag. Null uses the policy's default.
  final AutoDownloadContext? downloadContext;

  @override
  bool operator ==(Object other) =>
      other is GalleryItem &&
      other.key == key &&
      other.kind == kind &&
      other.size == size &&
      other.hasAudio == hasAudio &&
      other.descriptor == descriptor &&
      other.downloadContext == downloadContext;

  @override
  int get hashCode =>
      Object.hash(key, kind, size, hasAudio, descriptor, downloadContext);

  @override
  String toString() => 'GalleryItem($key, ${kind.name}, $size)';
}

/// The items a viewer pages through, indexed from 0 to [count].
///
/// A host's gallery is often larger than what it holds: it loads pages both
/// ways as the viewer moves ([loadAround]) and tells its listeners when
/// items arrive or the count changes. [count] is the total the host knows,
/// for "5 of 120"; items not loaded yet answer null and show a placeholder.
abstract interface class GallerySource implements Listenable {
  /// How many items the gallery has.
  int get count;

  /// The item at [index], or null while it is not loaded.
  GalleryItem? itemAt(int index);

  /// Asks for the items around [index], both ways. The viewer calls it for
  /// the item it shows; a source that holds everything does nothing.
  void loadAround(int index);
}
