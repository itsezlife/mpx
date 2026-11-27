import 'package:meta/meta.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';

/// Where an uploaded file now lives on the remote end, as its transport
/// answered at the end of the upload: what a completed upload job holds,
/// and what a publisher sends on.
///
/// Opaque to the engine: [id] and [attributes] are the transport's (a file
/// id, an object key, the upload's URL), carried as given.
@immutable
final class RemoteRef implements TransferResult {
  /// A reference named [id], with the transport's [attributes].
  RemoteRef(this.id, {Map<String, String> attributes = const {}})
    : attributes = Map.unmodifiable(attributes);

  /// The remote end's identity for the file.
  final String id;

  /// Anything else the transport answered that its publisher needs.
  final Map<String, String> attributes;

  /// How the journal writes this kind.
  @internal
  static const TransferResultCodec codec = _RemoteRefCodec();

  @override
  bool operator ==(Object other) {
    if (other is! RemoteRef ||
        other.id != id ||
        other.attributes.length != attributes.length) {
      return false;
    }
    for (final MapEntry(:key, :value) in attributes.entries) {
      if (other.attributes[key] != value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    id,
    Object.hashAllUnordered(
      attributes.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );

  // The id may be a URL: it stays out of logs.
  @override
  String toString() => 'RemoteRef(${attributes.length} attributes)';
}

final class _RemoteRefCodec implements TransferResultCodec {
  const _RemoteRefCodec();

  @override
  String get kind => 'remoteRef';

  @override
  Map<String, Object?>? encode(TransferResult result) => switch (result) {
    RemoteRef(:final id, :final attributes) => {
      'id': id,
      if (attributes.isNotEmpty) 'attributes': attributes,
    },
    _ => null,
  };

  @override
  TransferResult decode(Map<String, Object?> json) => RemoteRef(
    json['id']! as String,
    attributes: {
      ...?(json['attributes'] as Map<String, Object?>?)?.cast<String, String>(),
    },
  );
}
