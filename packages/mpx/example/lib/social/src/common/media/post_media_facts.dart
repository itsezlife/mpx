import 'dart:ui';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// A post's media as each part of the stack wants to be told of it: the
/// cache's descriptor, the feed's item and the viewer's gallery item all
/// come from the same facts.
abstract final class PostMediaFacts {
  /// What the cache learns of [media] before a surface attaches it.
  static MediaDescriptor descriptor(PostMedia media) {
    final width = media.width;
    final height = media.height;
    return MediaDescriptor(
      key: media.key,
      kind: media.plays ? MediaKind.video : MediaKind.still,
      animated: media.plays,
      dimensions: width == null || height == null || width <= 0 || height <= 0
          ? null
          : MediaDimensions(width, height),
      byteSize: media.byteSize,
      // A GIF has no timeline: its badge reads "GIF", not a length.
      duration: media.kind == PostMediaKind.video ? media.duration : null,
      // The server always sends a small still beside a file; the origins
      // know where it is.
      thumbnail: MediaThumbnailRef(media.key.encoded),
      streamable: media.plays,
      silentLoop: media.kind == PostMediaKind.gif,
    );
  }

  /// What the feed policy weighs for [media]: its size and length, and
  /// whether its bytes are on the device already ([onDevice]), in which case
  /// the policy plays it whatever its size, as playing it costs no network.
  static FeedItem feedItem(PostMedia media, {bool onDevice = false}) =>
      FeedItem(
        media.key,
        byteSize: media.byteSize,
        duration: media.duration,
        hasAudio: media.kind == PostMediaKind.video,
        local: onDevice,
        descriptor: descriptor(media),
      );

  /// Whether [media]'s file is all on the device, by what [fetcher] knows: a
  /// download the reader asked for, or one a viewer or a player made, has
  /// finished. The store holding a row is not that: a clip streamed in part
  /// has one too.
  static bool isOnDevice(PostMedia media, ContentFetcher fetcher) =>
      media.plays && !fetcher.needsDownload(media.key);

  /// What the viewer pages through for [media].
  static GalleryItem galleryItem(PostMedia media) {
    final width = media.width;
    final height = media.height;
    return GalleryItem(
      media.key,
      kind: switch (media.kind) {
        PostMediaKind.photo => GalleryMediaKind.photo,
        PostMediaKind.video => GalleryMediaKind.video,
        PostMediaKind.gif => GalleryMediaKind.animation,
      },
      size: width == null || height == null
          ? null
          : Size(width.toDouble(), height.toDouble()),
      hasAudio: media.kind == PostMediaKind.video,
      descriptor: descriptor(media),
    );
  }
}
