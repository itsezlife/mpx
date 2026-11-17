import 'package:flutter/foundation.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';

/// A [GallerySource] over a list held in memory. With [loaded] set, only the
/// indexes in it answer an item until the test [load]s more; [loadAround]
/// calls are recorded.
final class FakeGallerySource extends ChangeNotifier implements GallerySource {
  /// Creates a source of [items]; all of them loaded unless [loaded] says
  /// which.
  FakeGallerySource(List<GalleryItem> items, {Set<int>? loaded})
    : _items = List.of(items),
      _loaded = loaded ?? {for (var i = 0; i < items.length; i++) i};

  final List<GalleryItem> _items;
  final Set<int> _loaded;

  /// Every index [loadAround] was called with, in order.
  final List<int> requests = [];

  @override
  int get count => _items.length;

  @override
  GalleryItem? itemAt(int index) =>
      _loaded.contains(index) ? _items[index] : null;

  @override
  void loadAround(int index) => requests.add(index);

  /// Puts [item] at [index], loaded, moving the items from there one on (a
  /// host that learned of an item before them), and tells the listeners.
  void insert(int index, GalleryItem item) {
    _items.insert(index, item);
    final moved = {for (final at in _loaded) at >= index ? at + 1 : at};
    _loaded
      ..clear()
      ..addAll(moved)
      ..add(index);
    notifyListeners();
  }

  /// Makes [indexes] answer their items and tells the listeners.
  void load(Iterable<int> indexes) {
    _loaded.addAll(indexes);
    notifyListeners();
  }
}
