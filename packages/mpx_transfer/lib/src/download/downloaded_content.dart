import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';
import 'package:mpx_transfer/src/journal/json_fields.dart';

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

/// `{"bytes"?: count}`, the count left out when unknown; a count that is
/// not an integer throws a [FormatException] naming the field.
final class _DownloadedContentCodec implements TransferResultCodec {
  const _DownloadedContentCodec();

  @override
  String get kind => 'download';

  @override
  Map<String, Object?>? encode(TransferResult result) => switch (result) {
    DownloadedContent(:final bytes) => {_Key.bytes: ?bytes},
    _ => null,
  };

  @override
  DownloadedContent decode(Map<String, Object?> json) =>
      DownloadedContent(bytes: JsonFields(json).optionalInteger(_Key.bytes));
}

/// Field names of a downloaded content's stored form.
abstract final class _Key {
  static const String bytes = 'bytes';
}
