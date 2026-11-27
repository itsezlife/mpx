import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// The identity of one transfer job.
///
/// A download's id is derived from its cache key ([TransferId.forDownload]),
/// so asking for the same content twice finds the one job that already
/// exists. An upload's id is issued by the engine when the job is made
/// ([TransferId.issue]): sending the same file twice is two jobs.
///
/// Opaque to hosts: compare it, keep it, route a notification tap by it, but
/// never parse it. Diagnostics carry it as the event's `jobId`.
extension type const TransferId._(String value) implements String {
  /// The id of the download of the content the bytes cache stores under
  /// [cacheKey].
  ///
  /// A digest rather than the key itself: a cache key may be a URL, and ids
  /// travel into diagnostics and notifications, which carry no user content.
  /// The same key gives the same id in every run, which is what lets a
  /// second request, or a restart, find the job.
  factory TransferId.forDownload(String cacheKey) {
    final digest = sha256.convert(utf8.encode(cacheKey)).bytes;
    return TransferId._('d-${_hex(digest.take(16))}');
  }

  /// A new upload id, unique across runs: 128 random bits, so ids issued
  /// before a restart never collide with those issued after it.
  factory TransferId.issue() =>
      TransferId._('u-${_hex(List.generate(16, (_) => _random.nextInt(256)))}');

  /// The id written as [value], for an id read back from storage or from
  /// the native envelope.
  const TransferId.parse(String value) : this._(value);
}

final Random _random = Random.secure();

String _hex(Iterable<int> bytes) =>
    bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
