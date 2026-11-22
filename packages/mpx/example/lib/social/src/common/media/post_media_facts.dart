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

  /// What the feed policy weighs for [media].
  static FeedItem feedItem(PostMedia media) => FeedItem(
    media.key,
    byteSize: media.byteSize,
    duration: media.duration,
    hasAudio: media.kind == PostMediaKind.video,
    descriptor: descriptor(media),
  );

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
