import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/mpx_library.dart';

/// The pages of one library album a grid has asked for, loaded on demand
/// around what it builds.
///
/// [assetAt] answers what is loaded and asks for the page that holds the
/// index when it is not; nothing else is read, so a grid over a large album
/// loads only the pages near its viewport. [reload] (a library change, a
/// resume) marks every page stale: a stale page still answers while the
/// grid's next build reads it afresh, and the fresh read replaces it in
/// place, so a reload never blanks the grid and one that changed nothing
/// changes nothing on screen.
final class LibraryPages extends ChangeNotifier {
  /// Creates the window over [album] of [library], [pageSize] assets a page.
  LibraryPages({
    required this.library,
    required this.album,
    this.pageSize = 60,
    int? initialTotal,
  }) : _total = initialTotal ?? album.count;

  /// The library read.
  final MediaLibrary library;

  /// The album read.
  final LibraryAlbum album;

  /// Assets per page.
  final int pageSize;

  final Map<int, List<LibraryAsset>> _pages = {};
  // Pages read since the last reload; a page held but not here is stale.
  final Set<int> _fresh = {};
  final Set<int> _loading = {};
  int _total;
  int _generation = 0;
  bool _disposed = false;

  /// How many pages were read, for tests and diagnostics.
  int pageReads = 0;

  /// The album's asset count as last read.
  int get total => _total;

  /// The asset at [index], or null while its page loads.
  LibraryAsset? assetAt(int index) {
    if (index < 0 || index >= _total) return null;
    final page = index ~/ pageSize;
    if (!_fresh.contains(page)) _request(page);
    final assets = _pages[page];
    if (assets == null) return null;
    final offset = index - page * pageSize;
    return offset < assets.length ? assets[offset] : null;
  }

  /// The asset at [index] when its page is in; while it loads (asked for, as
  /// [assetAt] does), the held asset nearest to [index]: the last of a page
  /// before it or the first of a page after it. Null outside the album or
  /// with nothing held.
  ///
  /// For what stands for a place in the album (a date for a scroll
  /// position) while a far jump's page loads: the asset just left behind
  /// answers until the page lands, where a null would blink the answer out
  /// and back.
  LibraryAsset? nearestAt(int index) {
    if (index < 0 || index >= _total) return null;
    if (assetAt(index) case final asset?) return asset;
    final target = index ~/ pageSize;
    LibraryAsset? nearest;
    var distance = _total;
    for (final MapEntry(key: page, value: assets) in _pages.entries) {
      if (assets.isEmpty) continue;
      final (at, asset) = page < target
          ? (page * pageSize + assets.length - 1, assets.last)
          : (page * pageSize, assets.first);
      if ((at - index).abs() < distance) {
        distance = (at - index).abs();
        nearest = asset;
      }
    }
    return nearest;
  }

  /// Marks every page stale; each is read again when next asked for and
  /// answers what it held until then.
  void reload() {
    _generation++;
    _fresh.clear();
    _loading.clear();
    if (!_disposed) notifyListeners();
  }

  void _request(int page) {
    if (_loading.contains(page)) return;
    _loading.add(page);
    final generation = _generation;
    unawaited(_load(page, generation));
  }

  Future<void> _load(int page, int generation) async {
    try {
      final result = await library.page(
        album.id,
        offset: page * pageSize,
        limit: pageSize,
      );
      pageReads++;
      if (_disposed || generation != _generation) return;
      _fresh.add(page);
      final same =
          result.total == _total && listEquals(_pages[page], result.assets);
      _pages[page] = result.assets;
      _total = result.total;
      if (!same) notifyListeners();
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'mpx_ui',
          context: ErrorDescription('while reading a library page'),
        ),
      );
    } finally {
      if (generation == _generation) _loading.remove(page);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
