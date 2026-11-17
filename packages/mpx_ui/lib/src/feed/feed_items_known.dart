import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/known_descriptors.dart';

/// The host's items of a feed view, each descriptor told to the cache
/// before the controller preloads the item or a clip attaches it, so its
/// preview and thumbnail show though the cache never saw it.
///
/// The cache is the view's own, else the closest `AssetCacheProvider`'s,
/// read when the dependencies change.
mixin FeedItemsKnown<T extends StatefulWidget> on State<T> {
  /// The host's item at [index].
  FeedItem hostItemOf(int index);

  /// The cache the view was handed, or null for the provider's.
  AssetCacheScope? get hostScope;

  AssetCacheScope? _provided;
  final KnownDescriptors _known = KnownDescriptors();

  /// The cache the items are told to.
  AssetCacheScope? get itemsScope => hostScope ?? _provided;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _provided = AssetCacheProvider.maybeOf(context);
  }

  /// The host's item at [index], its descriptor told to the cache.
  FeedItem knownItemOf(int index) {
    final item = hostItemOf(index);
    _known.tell(itemsScope, item.descriptor);
    return item;
  }
}
