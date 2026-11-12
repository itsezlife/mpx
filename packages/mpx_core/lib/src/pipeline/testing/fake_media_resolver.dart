import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/pipeline/media_resolver.dart';

/// An in-memory [MediaResolver] for tests, resolving a fixed set of
/// descriptors.
///
/// Follows the whole seam contract. [requests] records each batch it was
/// asked for, so a test can check that a consumer batches; [failure] makes
/// every call fail, as a lost connection would.
final class FakeMediaResolver implements MediaResolver {
  /// Creates a resolver that knows [descriptors].
  FakeMediaResolver(Iterable<MediaDescriptor> descriptors)
    : _known = {for (final d in descriptors) d.key: d};

  final Map<MediaKey, MediaDescriptor> _known;
  final _requests = <List<MediaKey>>[];

  /// When non-null, [resolve] fails with it.
  Exception? failure;

  /// The keys of each [resolve] call, in call order, repeats included.
  List<List<MediaKey>> get requests => List.unmodifiable(_requests);

  @override
  Future<Map<MediaKey, MediaDescriptor>> resolve(
    Iterable<MediaKey> keys,
  ) async {
    _requests.add(List.unmodifiable(keys));
    final failure = this.failure;
    if (failure != null) throw failure;
    return {for (final key in keys) key: ?_known[key]};
  }
}
