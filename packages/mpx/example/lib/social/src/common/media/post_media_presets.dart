import 'package:flutter/painting.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/social/src/feature/timeline/model/post.dart';

/// The size and decode of a post's media on the surfaces that show it.
abstract final class PostMediaPresets {
  /// The longest side a picture is decoded at: a tile is never larger than
  /// the screen, and a decode past this costs memory the eye cannot use.
  static const int maxPixelExtent = 1440;

  /// [media] in a box of [size] logical pixels, filling it (a cover fit),
  /// used as [profile] says.
  ///
  /// A clip binds the one spec every surface that plays it binds, so the
  /// viewer goes on from the frame the tile shows; a picture is decoded at
  /// its box's pixels.
  static AssetPreset of(
    PostMedia media, {
    required Size size,
    required double devicePixelRatio,
    required AssetProfile profile,
  }) {
    final filling = profile.copyWith(fit: AssetFit.cover);
    return media.plays
        ? AssetPresets.animation(size: size, profile: filling)
        : AssetPresets.media(
            size: size,
            devicePixelRatio: devicePixelRatio,
            profile: filling,
            maxPixelExtent: maxPixelExtent,
          );
  }
}
