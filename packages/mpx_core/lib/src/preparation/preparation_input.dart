import 'package:meta/meta.dart';
import 'package:mpx_core/src/preparation/compression_preset.dart';

/// One item to prepare for upload: a local file (an object URL on the web)
/// and, when known, its MIME type and size.
@immutable
final class PreparationInput {
  /// Describes the file at [path].
  const PreparationInput(this.path, {this.mimeType, this.byteSize});

  /// Absolute path of the file; on the web, an object URL of its blob.
  final String path;

  /// Its size in bytes, when the host knows it (always on the web, which
  /// has no file to ask).
  final int? byteSize;

  /// Its MIME type, when the host knows it.
  final String? mimeType;

  @override
  bool operator ==(Object other) =>
      other is PreparationInput &&
      other.path == path &&
      other.byteSize == byteSize &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(path, byteSize, mimeType);

  @override
  String toString() => 'PreparationInput($path)';
}

/// How the host wants an item sent.
@immutable
sealed class PreparationIntent {
  const PreparationIntent();

  /// As a photo: scaled and encoded by the policy, at standard or
  /// [highQuality].
  const factory PreparationIntent.photo({bool highQuality}) =
      PreparationIntent$Photo;

  /// As a video, compressed at [preset]; without one it goes as it is.
  const factory PreparationIntent.video({CompressionPreset? preset}) =
      PreparationIntent$Video;

  /// As a file: the original bytes, with a thumbnail when it is media.
  const factory PreparationIntent.file() = PreparationIntent$File;
}

/// See [PreparationIntent.photo].
final class PreparationIntent$Photo extends PreparationIntent {
  /// Creates the intent.
  const PreparationIntent$Photo({this.highQuality = false});

  /// Whether the policy's high-quality size and quality apply.
  final bool highQuality;

  @override
  bool operator ==(Object other) =>
      other is PreparationIntent$Photo && other.highQuality == highQuality;

  @override
  int get hashCode => Object.hash(PreparationIntent$Photo, highQuality);

  @override
  String toString() => 'PreparationIntent.photo(highQuality: $highQuality)';
}

/// See [PreparationIntent.video].
final class PreparationIntent$Video extends PreparationIntent {
  /// Creates the intent.
  const PreparationIntent$Video({this.preset});

  /// The compression step, or null to send the video as it is.
  final CompressionPreset? preset;

  @override
  bool operator ==(Object other) =>
      other is PreparationIntent$Video && other.preset == preset;

  @override
  int get hashCode => Object.hash(PreparationIntent$Video, preset);

  @override
  String toString() => 'PreparationIntent.video(${preset?.name})';
}

/// See [PreparationIntent.file].
final class PreparationIntent$File extends PreparationIntent {
  /// Creates the intent.
  const PreparationIntent$File();

  @override
  bool operator ==(Object other) => other is PreparationIntent$File;

  @override
  int get hashCode => (PreparationIntent$File).hashCode;

  @override
  String toString() => 'PreparationIntent.file()';
}
