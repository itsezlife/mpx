import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';

/// What a completed tracked download produced: its content, whole in the
/// bytes cache under the job's key.
///
/// The bytes stay in the cache's data; the job holds no bytes and no path.
/// `TrackedTransfers.leaseFile` lends the cached file while the cache still
/// holds it.
@immutable
final class DownloadedContent implements TransferResult {
  /// A download that brought [bytes] bytes (null when the source did not
  /// say how many).
  const DownloadedContent({this.bytes});

  /// How many bytes the content has, or null when unknown.
  final int? bytes;

  /// How the journal writes this kind.
  @internal
  static const TransferResultCodec codec = _DownloadedContentCodec();

  @override
  bool operator ==(Object other) =>
      other is DownloadedContent && other.bytes == bytes;

  @override
  int get hashCode => Object.hash(DownloadedContent, bytes);

  @override
  String toString() => 'DownloadedContent($bytes)';
}

final class _DownloadedContentCodec implements TransferResultCodec {
  const _DownloadedContentCodec();

  @override
  String get kind => 'download';

  @override
  Map<String, Object?>? encode(TransferResult result) => switch (result) {
    DownloadedContent(:final bytes) => {'bytes': ?bytes},
    _ => null,
  };

  @override
  TransferResult decode(Map<String, Object?> json) =>
      DownloadedContent(bytes: json['bytes'] as int?);
}
