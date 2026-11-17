import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Where a clip's encoded file is read from: a closed set, so every binding
/// and engine answers each one.
///
/// [VideoFileSource] and [VideoRangedSource] are read in place, at the
/// offsets the demuxer asks for, on whatever thread decodes: the file never
/// passes through the caller's isolate and is never held whole in memory.
/// [VideoBytesSource] is for a caller that already holds the bytes (a test,
/// the web); it is copied once into the engine that decodes it.
@immutable
sealed class VideoSource {
  const VideoSource();

  /// A file held in memory.
  const factory VideoSource.bytes(Uint8List bytes) = VideoBytesSource;

  /// The file at [path].
  const factory VideoSource.file(String path) = VideoFileSource;

  /// The ranged resource [key] of a native ranged reader.
  const factory VideoSource.ranged({
    required int readerApi,
    required String key,
    int lookaheadBytes,
  }) = VideoRangedSource;
}

/// A [VideoSource] held in memory.
final class VideoBytesSource extends VideoSource {
  /// Creates a source over [bytes], which the caller no longer changes.
  const VideoBytesSource(this.bytes);

  /// The encoded file.
  final Uint8List bytes;

  @override
  String toString() => 'VideoSource.bytes(${bytes.length} bytes)';
}

/// A [VideoSource] in a file, read in place.
final class VideoFileSource extends VideoSource {
  /// Creates a source reading the file at [path].
  const VideoFileSource(this.path);

  /// Where the encoded file is.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is VideoFileSource && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'VideoSource.file($path)';
}

/// A [VideoSource] read through a native ranged reader as its bytes arrive.
///
/// [readerApi] is the address of the reader's function table (the bytes
/// cache's `hbc_api`, version 3 or later) and [key] the resource it serves.
/// Nothing waits for bytes that have not landed: an open or a frame that
/// needs them asks for them and answers stalled at once
/// (`VideoRejection.stalled`, `VideoFrameStatus.stalled`), and the caller
/// tries again when more landed. A clip thus opens once its index and its
/// first stretch are there, and never holds the decoding thread meanwhile.
/// The resource must stay published while the clip is open.
final class VideoRangedSource extends VideoSource {
  /// Creates a source over resource [key] of the reader at [readerApi].
  const VideoRangedSource({
    required this.readerApi,
    required this.key,
    this.lookaheadBytes = 0,
  });

  /// Address of the reader's function table.
  final int readerApi;

  /// The resource the reader opens.
  final String key;

  /// Bytes past its read position a clip wants present before it starts
  /// the next packet; 0 for the wrapper's default (512 KiB).
  final int lookaheadBytes;

  @override
  bool operator ==(Object other) =>
      other is VideoRangedSource &&
      other.readerApi == readerApi &&
      other.key == key;

  @override
  int get hashCode => Object.hash(readerApi, key);

  @override
  String toString() => 'VideoSource.ranged($key)';
}
