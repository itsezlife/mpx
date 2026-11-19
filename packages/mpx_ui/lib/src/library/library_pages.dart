import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_library/mpx_library.dart';

/// The pages of one library album a grid has asked for, loaded on demand
/// around what it builds.
///
/// [assetAt] answers what is loaded and asks for the page that holds the
/// index when it is not; nothing else is read, so a grid over a large album
/// loads only the pages near its viewport. [reload] drops every page (a
/// library change) and the grid asks again as it builds.
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
    final assets = _pages[page];
    if (assets == null) {
      _request(page);
      return null;
    }
    final offset = index - page * pageSize;
    return offset < assets.length ? assets[offset] : null;
  }

  /// Drops every page; they load again as they are asked for.
  void reload() {
    _generation++;
    _pages.clear();
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
      _pages[page] = result.assets;
      _total = result.total;
      notifyListeners();
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
