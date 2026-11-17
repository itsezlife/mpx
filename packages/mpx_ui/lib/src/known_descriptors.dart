import 'package:mpx_core/mpx_core.dart';

/// Tells a cache what the host knows about content (`AssetCacheScope.know`)
/// once per descriptor and cache, for a surface that meets the same items
/// on every build (a feed's items, a viewer's pages).
///
/// The descriptors are held weakly: a host's item that goes away takes its
/// mark with it, so a long session tells as much as it shows and keeps
/// nothing for the items it no longer holds.
final class KnownDescriptors {
  final Expando<AssetCacheScope> _toldTo = Expando('told to');

  /// Tells [scope] about [descriptor] unless it was told already; does
  /// nothing without either.
  void tell(AssetCacheScope? scope, MediaDescriptor? descriptor) {
    if (scope == null ||
        descriptor == null ||
        identical(_toldTo[descriptor], scope)) {
      return;
    }
    _toldTo[descriptor] = scope;
    scope.know(descriptor);
  }
}
