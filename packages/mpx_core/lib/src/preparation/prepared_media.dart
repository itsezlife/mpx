import 'package:flutter/foundation.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';

/// What a prepared item is sent as.
///
/// The value's [name] is its stable identity in a stored prepared item
/// (`PreparationEncoding`): a kind is never renamed, only added.
enum PreparedKind {
  /// A photo.
  photo,

  /// A video.
  video,

  /// A file.
  file,
}

/// An item ready to upload: the prepared file and what is known about it.
///
/// [path] is a file the preparer wrote into its output directory, or the
/// input itself when [isOriginal] (the host must not delete that one). The
/// thumbnail is a file beside it ([thumbnailPath]) when the preparer wrote
/// one, so a journal can name it; [thumbnail] holds its bytes in memory when
/// the preparer kept them.
@immutable
final class PreparedMedia {
  /// Describes a prepared item.
  const PreparedMedia({
    required this.kind,
    required this.path,
    required this.isOriginal,
    required this.byteSize,
    this.mimeType,
    this.dimensions,
    this.duration,
    this.thumbnailPath,
    this.thumbnail,
    this.thumbnailDimensions,
    this.hasAudio = false,
    this.animated = false,
    this.bytes,
  });

  /// What it is sent as.
  final PreparedKind kind;

  /// The file to upload.
  final String path;

  /// Whether [path] is the input, unchanged.
  final bool isOriginal;

  /// The size of [path] in bytes.
  final int byteSize;

  /// The MIME type of [path], when known.
  final String? mimeType;

  /// The pixel size as displayed, when it is a picture or a video.
  final MediaDimensions? dimensions;

  /// The playing time of a video.
  final Duration? duration;

  /// A JPEG thumbnail (the poster of a video) written as a file, when one
  /// could be made and the preparer writes files.
  final String? thumbnailPath;

  /// The bytes of the JPEG thumbnail, when the preparer kept them in
  /// memory. Not part of the stored form (`PreparationEncoding`).
  final Uint8List? thumbnail;

  /// The pixel size of the thumbnail.
  final MediaDimensions? thumbnailDimensions;

  /// Whether a video has a sound track.
  final bool hasAudio;

  /// Whether it moves without sound: an animated still, or a silent video
  /// that loops.
  final bool animated;

  /// The output itself where the platform writes no files (the web): an
  /// encoded JPEG to upload instead of [path]. Null for a file output and
  /// for an original. Not part of the stored form (`PreparationEncoding`).
  final Uint8List? bytes;

  @override
  bool operator ==(Object other) =>
      other is PreparedMedia &&
      other.kind == kind &&
      other.path == path &&
      other.isOriginal == isOriginal &&
      other.byteSize == byteSize &&
      other.mimeType == mimeType &&
      other.dimensions == dimensions &&
      other.duration == duration &&
      other.thumbnailPath == thumbnailPath &&
      listEquals(other.thumbnail, thumbnail) &&
      other.thumbnailDimensions == thumbnailDimensions &&
      other.hasAudio == hasAudio &&
      other.animated == animated &&
      listEquals(other.bytes, bytes);

  @override
  int get hashCode => Object.hash(
    kind,
    path,
    isOriginal,
    byteSize,
    mimeType,
    dimensions,
    duration,
    thumbnailPath,
    thumbnailDimensions,
    hasAudio,
    animated,
  );

  @override
  String toString() =>
      'PreparedMedia(${kind.name}, $path, $byteSize B, '
      '${dimensions ?? '?'}${isOriginal ? ', original' : ''})';
}
