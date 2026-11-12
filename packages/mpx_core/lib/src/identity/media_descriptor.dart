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

  @override
  bool operator ==(Object other) =>
      other is MediaDescriptor &&
      other.key == key &&
      other.kind == kind &&
      other.animated == animated &&
      other.dimensions == dimensions &&
      other.byteSize == byteSize &&
      other.duration == duration &&
      other.thumbnail == thumbnail;

  @override
  int get hashCode => Object.hash(
    key,
    kind,
    animated,
    dimensions,
    byteSize,
    duration,
    thumbnail,
  );

  @override
  String toString() => 'MediaDescriptor($key, ${kind.name})';
}
