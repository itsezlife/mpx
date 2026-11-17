import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:mpx_core/src/identity/media_key.dart';

/// How a piece of media renders, which picks the decoder that reads it.
///
/// Decoders register per kind, so two kinds that need different decoders
/// stay apart even when a viewer would call both "animation".
enum MediaKind {
  /// A single still image.
  still,

  /// A resolution-independent vector animation.
  vectorAnimation,

  /// A sequence of frames in an image format (animated WebP, GIF, APNG),
  /// read by image codecs.
  ///
  /// Not [video]: an image codec cannot read a video stream, nor a video
  /// decoder an image file, so one kind for both would let only one of the
  /// two decoders be registered.
  animatedImage,

  /// Video-coded media (WebM, MP4), read by a video decoder.
  video,

  /// A kind the host could not tell. No decoder takes it, so the media stays
  /// at its placeholder.
  unknown,
}

/// An opaque handle to the thumbnail of a piece of media, issued by the host.
///
/// Nothing in the core reads it: the host's fetcher resolves it, and only the
/// host knows its structure.
extension type const MediaThumbnailRef(String value) {}

/// The intrinsic pixel size of the source media.
///
/// A hint known before the media loads, so a placeholder can reserve the
/// right shape. It is not a layout size.
@immutable
final class MediaDimensions {
  /// Creates dimensions; both must be positive.
  const MediaDimensions(this.width, this.height)
    : assert(width > 0 && height > 0, 'MediaDimensions must be positive.');

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  @override
  bool operator ==(Object other) =>
      other is MediaDimensions &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'MediaDimensions($width x $height)';
}

/// A stand-in of a piece of media known without fetching the media or its
/// thumbnail: a tiny picture, or the vector outline of its shape.
///
/// The host expands its own wire formats before the descriptor (a
/// header-stripped JPEG made whole, a compressed path written out as SVG path
/// data); the core reads only an encoded image or path data and stays neutral
/// about how they travel.
///
/// - [MediaPreview.raster]: an image the engine decodes (JPEG, PNG, WebP),
///   a few dozen pixels on its long edge; the pipeline blurs it at decode.
/// - [MediaPreview.outline]: SVG path data in a view box, the shape of the
///   content (a sticker, an emoji) drawn as a filled path.
@immutable
sealed class MediaPreview {
  /// A preview of [encoded] image bytes. The preview keeps a copy, so a later
  /// change to [encoded] changes nothing.
  factory MediaPreview.raster(Uint8List encoded) = MediaPreview$Raster;

  /// A preview of the outline [pathData] (SVG path syntax) laid out in
  /// [viewBox].
  const factory MediaPreview.outline(String pathData, MediaDimensions viewBox) =
      MediaPreview$Outline;

  const MediaPreview._();
}

/// A [MediaPreview] of encoded image bytes.
///
/// Equal to another of the same bytes in any list: the content hash is
/// computed once, and the bytes are compared only when it matches.
final class MediaPreview$Raster extends MediaPreview {
  /// A preview of a copy of [encoded].
  MediaPreview$Raster(Uint8List encoded)
    : encoded = Uint8List.fromList(encoded).asUnmodifiableView(),
      _hash = Object.hashAll(encoded),
      super._();

  /// The encoded image, read only.
  final Uint8List encoded;

  final int _hash;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MediaPreview$Raster ||
        other._hash != _hash ||
        other.encoded.length != encoded.length) {
      return false;
    }
    for (var i = 0; i < encoded.length; i++) {
      if (other.encoded[i] != encoded[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => _hash;

  @override
  String toString() => 'MediaPreview.raster(${encoded.length} bytes)';
}

/// A [MediaPreview] of an outline: SVG path data in a view box.
final class MediaPreview$Outline extends MediaPreview {
  /// A preview of [pathData] in [viewBox].
  const MediaPreview$Outline(this.pathData, this.viewBox) : super._();

  /// The outline, in SVG path syntax.
  final String pathData;

  /// The box [pathData] is laid out in.
  final MediaDimensions viewBox;

  @override
  bool operator ==(Object other) =>
      other is MediaPreview$Outline &&
      other.pathData == pathData &&
      other.viewBox == viewBox;

  @override
  int get hashCode => Object.hash(pathData, viewBox);

  @override
  String toString() =>
      'MediaPreview.outline(${pathData.length} chars, $viewBox)';
}

/// What the host knows about a piece of media beyond which media it is.
///
/// A [key] plus the facts the pipeline needs before any byte has loaded: the
/// [kind] that picks a decoder, whether it moves, and size hints. Every fact
/// defaults to "not known", so a descriptor built from partial host data is
/// valid. Whether a descriptor is known at all is the pipeline's question
/// (it asks the host for missing ones), never a field here.
@immutable
final class MediaDescriptor {
  /// Creates a descriptor of [key].
  const MediaDescriptor({
    required this.key,
    this.kind = MediaKind.unknown,
    this.animated = false,
    this.dimensions,
    this.byteSize,
    this.duration,
    this.thumbnail,
    this.preview,
    this.streamable = false,
    this.silentLoop = false,
  }) : assert(byteSize == null || byteSize >= 0, 'byteSize is not negative.');

  /// The media this descriptor describes.
  final MediaKey key;

  /// How the media renders.
  final MediaKind kind;

  /// Whether the media moves. Independent of [kind]: an animated image may
  /// hold one frame only.
  final bool animated;

  /// The source pixel size, when the host knows it.
  final MediaDimensions? dimensions;

  /// The size of the media file in bytes, when the host knows it.
  final int? byteSize;

  /// How long one pass of the media runs, when the host knows it.
  final Duration? duration;

  /// The thumbnail to show while the media loads, when there is one.
  final MediaThumbnailRef? thumbnail;

  /// The stand-in drawn before the thumbnail, when the host has one.
  final MediaPreview? preview;

  /// Whether the media can play before it has all arrived (a video laid out
  /// for progressive playback). Defaults to false.
  final bool streamable;

  /// Whether the media is a GIF sent as video: a silent loop that plays by
  /// itself, with no timeline. Its badge reads "GIF", never a duration. An
  /// [MediaKind.animatedImage] is one whatever this says. Defaults to false.
  final bool silentLoop;

  /// Whether the media is a GIF: an animated image, or a [silentLoop].
  bool get isGif => kind == MediaKind.animatedImage || silentLoop;

  @override
  bool operator ==(Object other) =>
      other is MediaDescriptor &&
      other.silentLoop == silentLoop &&
      other.key == key &&
      other.kind == kind &&
      other.animated == animated &&
      other.dimensions == dimensions &&
      other.byteSize == byteSize &&
      other.duration == duration &&
      other.thumbnail == thumbnail &&
      other.preview == preview &&
      other.streamable == streamable;

  @override
  int get hashCode => Object.hash(
    key,
    kind,
    animated,
    dimensions,
    byteSize,
    duration,
    thumbnail,
    preview,
    streamable,
    silentLoop,
  );

  @override
  String toString() {
    final facts = [
      kind.name,
      if (preview case final preview?)
        'preview: ${switch (preview) {
          MediaPreview$Raster() => 'raster',
          MediaPreview$Outline() => 'outline',
        }}',
      if (streamable) 'streamable',
      if (silentLoop) 'silent loop',
    ];
    return 'MediaDescriptor($key, ${facts.join(', ')})';
  }
}
