import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_core/mpx_core.dart';

/// Keeps capture output in the bytes store under a local media key, so the
/// sender's own item plays at once through the normal pipeline, before any
/// upload.
///
/// The flow, one key per capture:
///
/// 1. [mintKey] when the capture or compression starts; the host's message
///    carries the key from then on.
/// 2. [put] the finished output: the file moves into the store under
///    [cacheKeyOf] the key.
/// 3. After upload, [alias] the server's cache key to it: the server key
///    resolves to the same bytes, no copy or move, while the bubble keeps
///    playing under the local key.
/// 4. [release] the local key once the message is confirmed; the server key
///    keeps the bytes. Retention drops the local key otherwise.
final class CaptureCache {
  /// Creates a cache over [store]; output counts against [quota].
  ///
  /// [newUuid] names each minted key; the default draws a random (version 4)
  /// UUID from a secure source.
  CaptureCache({
    required this.store,
    this.quota = BytesQuota.videoRanges,
    String Function()? newUuid,
  }) : _newUuid = newUuid ?? _randomUuid;

  /// The store output lands in.
  final IBytesStore store;

  /// The quota output counts against.
  final BytesQuota quota;

  final String Function() _newUuid;

  /// The cache key of [key]'s bytes.
  ///
  /// The media key's stable form, as the fetch adapter keys a part's content,
  /// so a reader that asks the fetcher for [key] finds the bytes. A local
  /// form is short enough that no store hashes it.
  static BytesCacheKey cacheKeyOf(MediaKey$Local key) =>
      BytesCacheKey(key.encoded);

  /// A fresh local key for one capture or compression.
  MediaKey$Local mintKey() => MediaKey$Local(_newUuid());

  /// Moves [output] into the store under [key]; it resolves from there as
  /// soon as this completes.
  ///
  /// A store that keeps ranged resources takes the file in chunks, never
  /// whole in memory, as a complete ranged resource: readers that stream
  /// (a native player) and readers of whole bytes both find it. Other stores
  /// take it whole. [deleteSource] removes [output]'s file afterwards; on a
  /// failure the key holds nothing and the file stays.
  Future<void> put(
    MediaKey$Local key,
    CaptureOutput output, {
    bool deleteSource = true,
  }) async {
    final cacheKey = cacheKeyOf(key);
    final file = File(output.path);
    try {
      if (store case final IRangedBytesStore ranged
          when ranged.supportsRanges) {
        await _putRanged(ranged, cacheKey, file);
      } else {
        await store.write(cacheKey, await file.readAsBytes(), quota: quota);
      }
    } on Object {
      await store.evict(cacheKey);
      rethrow;
    }
    if (deleteSource) await file.delete();
  }

  /// Makes [server] resolve to the bytes [key] holds; false when [key] holds
  /// nothing (not put yet, released or expired).
  Future<bool> alias(MediaKey$Local key, BytesCacheKey server) =>
      store.alias(cacheKeyOf(key), server);

  /// Drops [key] once its message is confirmed; keys aliased to it keep the
  /// bytes.
  Future<void> release(MediaKey$Local key) => store.release(cacheKeyOf(key));

  Future<void> _putRanged(
    IRangedBytesStore ranged,
    BytesCacheKey key,
    File file,
  ) async {
    final length = await file.length();
    final lease = await ranged.openRanged(key, quota: quota);
    final source = await file.open();
    try {
      final chunk = Uint8List(_chunkSize);
      var offset = 0;
      RangedState? state;
      while (offset < length) {
        final read = await source.readInto(chunk);
        if (read == 0) break;
        state = await ranged.writeRange(
          key,
          offset,
          Uint8List.sublistView(chunk, 0, read),
          totalLength: length,
          quota: quota,
        );
        offset += read;
      }
      if (state?.isComplete != true) {
        throw StateError('${file.path} changed while it moved into the store');
      }
    } finally {
      await source.close();
      await lease.release();
    }
  }

  static const int _chunkSize = 1 << 20;

  static final math.Random _random = math.Random.secure();

  static String _randomUuid() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant
    final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
    return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
        '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
        '${hex.sublist(10).join()}';
  }
}
