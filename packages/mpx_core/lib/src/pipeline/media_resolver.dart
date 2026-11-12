import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';

/// Resolves bare [MediaKey]s into [MediaDescriptor]s.
///
/// The host implements it, because only the host can find out what a key
/// stands for: a key that arrives without facts (in stored text, in a recent
/// list, in a link) has no descriptor until it is resolved. Resolution is
/// batched so a screenful of keys costs one request.
///
/// ## Results
///
/// [resolve] answers with a descriptor for every key it could resolve and
/// leaves out the rest: an unknown or deleted key is absent from the result,
/// not an error, and each returned descriptor's key equals the key it is
/// listed under. The result never holds keys that were not asked for. Repeated
/// keys in `keys` are resolved once. An empty request gives an empty result.
///
/// ## Failure and cancellation
///
/// The future fails when the batch as a whole could not be attempted, for
/// example with no connection; keys left out of a successful result were
/// attempted and are unknown. A caller may remember that answer, so a
/// resolver that cannot answer for a key yet (data still syncing) fails the
/// batch rather than leaving the key out. There is no cancellation: a caller
/// that no longer wants the result ignores it. Resolving again is always
/// allowed.
abstract interface class MediaResolver {
  /// The descriptors of those [keys] that resolve.
  Future<Map<MediaKey, MediaDescriptor>> resolve(Iterable<MediaKey> keys);
}
