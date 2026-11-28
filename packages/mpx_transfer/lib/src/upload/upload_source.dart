import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/upload/upload_temp_file.dart';

/// The file an upload reads: finished, with a known size, or growing, still
/// being written by whatever produces it (a recorder, a compressor).
///
/// An upload always reads a file, so a kill can resume it from the same
/// bytes: in-memory bytes go through a temp file first ([fromBytes]).
@immutable
sealed class UploadSource {
  const UploadSource(this.path);

  /// The finished file at [path], [size] bytes long.
  const factory UploadSource.finished(String path, {required int size}) =
      UploadSource$Finished;

  /// The file at [path] while it is still written: [available] bytes so far,
  /// [finalSize] once known, and [headRewritten] once its producer has
  /// rewritten the start of the file (a container header written last).
  ///
  /// Declared so the shape does not change when growing uploads land; until
  /// then an upload of a growing source is refused.
  const factory UploadSource.growing(
    String path, {
    required int available,
    int? finalSize,
    bool headRewritten,
  }) = UploadSource$Growing;

  /// Writes [bytes] to a new file in [directory] (the platform's temp
  /// directory when omitted) and answers it as a finished source.
  ///
  /// The caller owns the file: it deletes it once the upload is done.
  /// On the web, where an upload reads the origin private file system,
  /// this throws an [UnsupportedError] until the web journal lands.
  static Future<UploadSource$Finished> fromBytes(
    List<int> bytes, {
    String? directory,
  }) async => UploadSource$Finished(
    await $writeUploadTempFile(bytes, directory: directory),
    size: bytes.length,
  );

  /// Where the file is: a file system path on the VM, a path in the origin
  /// private file system on the web.
  final String path;
}

/// [UploadSource.finished].
final class UploadSource$Finished extends UploadSource {
  /// See [UploadSource.finished].
  const UploadSource$Finished(super.path, {required this.size})
    : assert(size >= 0, 'size must be >= 0');

  /// The file's size in bytes.
  final int size;

  @override
  bool operator ==(Object other) =>
      other is UploadSource$Finished &&
      other.path == path &&
      other.size == size;

  @override
  int get hashCode => Object.hash(UploadSource$Finished, path, size);

  @override
  String toString() => 'UploadSource.finished($size bytes)';
}

/// [UploadSource.growing].
final class UploadSource$Growing extends UploadSource {
  /// See [UploadSource.growing].
  const UploadSource$Growing(
    super.path, {
    required this.available,
    this.finalSize,
    this.headRewritten = false,
  });

  /// The bytes written so far.
  final int available;

  /// The file's size once its producer finished; null before.
  final int? finalSize;

  /// Whether the producer has rewritten the start of the file.
  final bool headRewritten;

  @override
  bool operator ==(Object other) =>
      other is UploadSource$Growing &&
      other.path == path &&
      other.available == available &&
      other.finalSize == finalSize &&
      other.headRewritten == headRewritten;

  @override
  int get hashCode => Object.hash(
    UploadSource$Growing,
    path,
    available,
    finalSize,
    headRewritten,
  );

  @override
  String toString() =>
      'UploadSource.growing($available bytes, final: $finalSize)';
}
