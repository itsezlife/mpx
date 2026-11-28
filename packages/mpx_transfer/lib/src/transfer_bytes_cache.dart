import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';

/// The bytes cache a facade's content lives in: how a media key names its
/// entry ([keyOf], the composition root's mapping) and the [store] a
/// publish job aliases its server keys in. The two travel together: a
/// tracked download is found and a server key aliased through the same
/// mapping.
@immutable
final class TransferBytesCache {
  /// The cache [store], keyed by [keyOf]; with no [store] the facade
  /// aliases in its downloads' store, and without that makes no alias.
  const TransferBytesCache({required this.keyOf, this.store});

  /// The entry key of a media key.
  final String Function(MediaKey key) keyOf;

  /// The store server keys are aliased in; null for the downloads' store.
  final IBytesStore? store;
}
