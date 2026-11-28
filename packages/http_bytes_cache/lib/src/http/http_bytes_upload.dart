import 'package:meta/meta.dart';

/// {@template http_bytes_upload_body}
/// What [HttpBytesClient.upload] sends: [length] bytes from [offset] of a
/// file or a blob, streamed as the request body, never read whole into the
/// calling isolate's memory; with a small [prefix] before them and a
/// [suffix] after, such as a multipart form's framing around the file.
/// {@endtemplate}
@immutable
sealed class HttpBytesUploadBody {
  /// {@macro http_bytes_upload_body}
  const HttpBytesUploadBody({
    required this.offset,
    required this.length,
    this.prefix = const <int>[],
    this.suffix = const <int>[],
  }) : assert(offset >= 0, 'offset must be >= 0'),
       assert(length >= 0, 'length must be >= 0');

  /// The range `[offset, offset + length)` of the file at [path].
  ///
  /// On the VM [path] is a file system path, read on the transfer worker.
  /// On the web it names a file in the origin private file system, its
  /// directories separated by `/` from the root.
  const factory HttpBytesUploadBody.file(
    String path, {
    required int length,
    int offset,
    List<int> prefix,
    List<int> suffix,
  }) = HttpBytesUploadBody$File;

  /// The range `[offset, offset + length)` of [blob], a browser `Blob` (or a
  /// `File`), handed to `fetch` as a slice. The web only: typed [Object] so
  /// the VM compiles without the browser's types.
  const factory HttpBytesUploadBody.blob(
    Object blob, {
    required int length,
    int offset,
    List<int> prefix,
    List<int> suffix,
  }) = HttpBytesUploadBody$Blob;

  /// The first byte of the source sent.
  final int offset;

  /// How many bytes of the source are sent.
  final int length;

  /// Bytes sent before the source's range; empty by default. Held in
  /// memory, so meant for framing, not content.
  final List<int> prefix;

  /// Bytes sent after the source's range; empty by default.
  final List<int> suffix;

  /// The whole body's size, [prefix], range and [suffix]: the request's
  /// `Content-Length`.
  int get contentLength => prefix.length + length + suffix.length;
}

/// [HttpBytesUploadBody.file].
final class HttpBytesUploadBody$File extends HttpBytesUploadBody {
  /// A range of the file at [path].
  const HttpBytesUploadBody$File(
    this.path, {
    required super.length,
    super.offset = 0,
    super.prefix,
    super.suffix,
  });

  /// Where the file is (see [HttpBytesUploadBody.file]).
  final String path;
}

/// [HttpBytesUploadBody.blob].
final class HttpBytesUploadBody$Blob extends HttpBytesUploadBody {
  /// A range of [blob].
  const HttpBytesUploadBody$Blob(
    this.blob, {
    required super.length,
    super.offset = 0,
    super.prefix,
    super.suffix,
  });

  /// The browser `Blob`.
  final Object blob;
}
