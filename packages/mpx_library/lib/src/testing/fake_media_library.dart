import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/library/library_access.dart';
import 'package:mpx_library/src/library/library_album.dart';
import 'package:mpx_library/src/library/library_asset.dart';
import 'package:mpx_library/src/library/library_change.dart';
import 'package:mpx_library/src/library/library_page.dart';
import 'package:mpx_library/src/library/media_library.dart';

/// A [MediaLibrary] held in memory, for tests and for hosts without a
/// device: scripted access transitions, generated assets, added albums,
/// change events and slow originals. Meets `MediaLibraryContract`.
///
/// The all-media album (`LibraryAlbumId('all')`) holds every asset, newest
/// first; [addAlbum] adds others over the same assets. Thumbnails are
/// stand-in bytes that name the asset and the size; originals are small
/// files in a temporary directory that [dispose] deletes.
final class FakeMediaLibrary implements MediaLibrary {
  /// Creates a library of [assets] generated assets ([assetAt]) with
  /// [access]; [requestAccess] turns `notDetermined` into [grantOnRequest].
  ///
  /// Originals of [cloudHeld] assets download first: they take
  /// [originalDelay] in [downloadSteps] reported steps. Local originals take
  /// [originalDelay] without a report.
  FakeMediaLibrary({
    int assets = 0,
    LibraryAccess access = LibraryAccess.full,
    this.grantOnRequest = LibraryAccess.full,
    Set<LibraryAssetId> cloudHeld = const {},
    this.originalDelay = Duration.zero,
    this.downloadSteps = 4,
  }) : _access = ValueNotifier(access),
       _cloudHeld = {...cloudHeld} {
    for (var i = 0; i < assets; i++) {
      final asset = assetAt(i);
      _assets[asset.id] = asset;
      _order[allMedia]!.add(asset.id);
    }
  }

  /// The id of the all-media album.
  static const LibraryAlbumId allMedia = LibraryAlbumId('all');

  /// The [index]th generated asset: newest first, a video every fourth.
  static LibraryAsset assetAt(int index) {
    final video = index % 4 == 3;
    final created = DateTime.utc(2026).subtract(Duration(minutes: index));
    return LibraryAsset(
      id: LibraryAssetId('asset-$index'),
      kind: video ? LibraryAssetKind.video : LibraryAssetKind.photo,
      dimensions: video
          ? const MediaDimensions(1920, 1080)
          : const MediaDimensions(4032, 3024),
      duration: video ? Duration(seconds: 5 + index % 10) : null,
      created: created,
      modified: created,
      mimeType: video ? 'video/mp4' : 'image/jpeg',
    );
  }

  /// What [requestAccess] grants when access is not determined.
  LibraryAccess grantOnRequest;

  /// How long an original takes to be lent.
  final Duration originalDelay;

  /// How many progress reports a cloud-held original's download makes.
  final int downloadSteps;

  final ValueNotifier<LibraryAccess> _access;
  final Set<LibraryAssetId> _cloudHeld;
  final Map<LibraryAssetId, LibraryAsset> _assets = {};
  final Map<LibraryAlbumId, List<LibraryAssetId>> _order = {allMedia: []};
  final Map<LibraryAlbumId, ({LibraryAlbumKind kind, String title, bool end})>
  _meta = {allMedia: (kind: LibraryAlbumKind.allMedia, title: '', end: false)};
  final StreamController<LibraryChange> _changes =
      StreamController<LibraryChange>.broadcast();
  Directory? _directory;

  /// How many times [requestAccess] was called.
  int requestAccessCalls = 0;

  /// How many times [manageSelected] asked the system.
  int manageSelectedCalls = 0;

  /// How many times [openSettings] was called.
  int openSettingsCalls = 0;

  /// Every thumbnail read, in order.
  final List<(LibraryAssetId, int)> thumbnailRequests = [];

  /// Leases lent and not released yet.
  int openLeases = 0;

  // --- Scripting ---

  /// Moves access to [access], as the system settings would; notifies when
  /// it changed.
  // A verb, not a setter: it scripts a transition the system makes.
  // ignore: use_setters_to_change_properties
  void setAccess(LibraryAccess access) => _access.value = access;

  /// Adds an album over [assets] (ids of assets the library holds), listed
  /// after the albums already there.
  void addAlbum(
    LibraryAlbumId id, {
    required List<LibraryAssetId> assets,
    LibraryAlbumKind kind = LibraryAlbumKind.user,
    String title = '',
    bool startsAtEnd = false,
  }) {
    _order[id] = [
      for (final a in assets)
        if (_assets.containsKey(a)) a,
    ];
    _meta[id] = (kind: kind, title: title, end: startsAtEnd);
  }

  /// Puts [assets] at the front of the all-media album (and of [album]) and
  /// emits the change.
  void insert(List<LibraryAsset> assets, {LibraryAlbumId? album}) {
    for (final asset in assets) {
      _assets[asset.id] = asset;
    }
    final ids = [for (final a in assets) a.id];
    for (final target in {allMedia, ?album}) {
      _order[target]?.insertAll(0, ids);
      _changes.add(LibraryChange.album(target, inserted: ids.toSet()));
    }
  }

  /// Takes [ids] out of every album and emits a change for each album that
  /// held one.
  void remove(Set<LibraryAssetId> ids) {
    for (final MapEntry(key: album, value: order) in _order.entries) {
      final removed = order.where(ids.contains).toSet();
      if (removed.isEmpty) continue;
      order.removeWhere(ids.contains);
      _changes.add(LibraryChange.album(album, removed: removed));
    }
    ids.forEach(_assets.remove);
  }

  /// Replaces assets in place and emits a change for each album holding
  /// one.
  void update(List<LibraryAsset> assets) {
    final ids = {for (final a in assets) a.id};
    for (final asset in assets) {
      if (_assets.containsKey(asset.id)) _assets[asset.id] = asset;
    }
    for (final MapEntry(key: album, value: order) in _order.entries) {
      final changed = order.where(ids.contains).toSet();
      if (changed.isNotEmpty) {
        _changes.add(LibraryChange.album(album, changed: changed));
      }
    }
  }

  /// Emits a change without detail.
  void emitReload() => _changes.add(const LibraryChange.reload());

  // --- MediaLibrary ---

  @override
  ValueListenable<LibraryAccess> get access => _access;

  @override
  Future<LibraryAccess> requestAccess() async {
    requestAccessCalls++;
    if (_access.value == LibraryAccess.notDetermined) {
      _access.value = grantOnRequest;
    }
    return _access.value;
  }

  @override
  Future<bool> manageSelected() async {
    if (!_access.value.canManageSelected) return false;
    manageSelectedCalls++;
    return true;
  }

  @override
  Future<void> openSettings() async => openSettingsCalls++;

  @override
  Future<List<LibraryAlbum>> albums() async {
    if (!_access.value.canRead) return const [];
    return [
      for (final MapEntry(key: id, value: order) in _order.entries)
        LibraryAlbum(
          id: id,
          kind: _meta[id]!.kind,
          title: _meta[id]!.title,
          count: order.length,
          cover: order.isEmpty ? null : _assets[order.first],
          startsAtEnd: _meta[id]!.end,
        ),
    ];
  }

  @override
  Future<LibraryPage> page(
    LibraryAlbumId album, {
    required int offset,
    required int limit,
  }) async {
    if (offset < 0) throw ArgumentError.value(offset, 'offset', 'negative');
    if (limit <= 0) throw ArgumentError.value(limit, 'limit', 'not > 0');
    final order = _access.value.canRead ? _order[album] : null;
    if (order == null) {
      return LibraryPage(
        album: album,
        offset: offset,
        assets: const [],
        total: 0,
      );
    }
    final start = offset.clamp(0, order.length);
    final end = (offset + limit).clamp(0, order.length);
    return LibraryPage(
      album: album,
      offset: offset,
      assets: [for (final id in order.sublist(start, end)) _assets[id]!],
      total: order.length,
    );
  }

  @override
  Stream<LibraryChange> get changes => _changes.stream;

  @override
  Future<Uint8List> thumbnail(
    LibraryAssetId asset, {
    required int pixels,
    CancellationToken? cancellation,
  }) async {
    _available(asset);
    thumbnailRequests.add((asset, pixels));
    return Uint8List.fromList(utf8.encode('thumbnail ${asset.value} $pixels'));
  }

  @override
  Future<LibraryFileLease> original(
    LibraryAssetId asset, {
    FetchProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    _available(asset);
    final bytes = utf8.encode('original ${asset.value}');
    if (_cloudHeld.contains(asset)) {
      final steps = downloadSteps < 1 ? 1 : downloadSteps;
      onProgress?.call(0, bytes.length);
      for (var step = 1; step <= steps; step++) {
        await Future<void>.delayed(originalDelay ~/ steps);
        if (cancellation?.isCancelled ?? false) {
          throw LibraryDownloadFailed(asset, 'cancelled');
        }
        onProgress?.call(bytes.length * step ~/ steps, bytes.length);
      }
      _cloudHeld.remove(asset);
    } else {
      await Future<void>.delayed(originalDelay);
      if (cancellation?.isCancelled ?? false) {
        throw LibraryAssetUnavailable(asset, 'cancelled');
      }
    }
    final directory = _directory ??= Directory.systemTemp.createTempSync(
      'mpx_library_fake',
    );
    final name = base64Url.encode(utf8.encode(asset.value));
    final file = File('${directory.path}/$name.bin')..writeAsBytesSync(bytes);
    openLeases++;
    return _FakeLease(file.path, _assets[asset]?.mimeType, () => openLeases--);
  }

  @override
  bool isCloudHeld(LibraryAssetId asset) => _cloudHeld.contains(asset);

  @override
  Future<void> dispose() async {
    await _changes.close();
    _access.dispose();
    final directory = _directory;
    _directory = null;
    if (directory != null && directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }

  void _available(LibraryAssetId asset) {
    if (!_access.value.canRead || !_assets.containsKey(asset)) {
      throw LibraryAssetUnavailable(asset);
    }
  }
}

final class _FakeLease implements LibraryFileLease {
  _FakeLease(this.path, this.mimeType, this._onRelease);

  @override
  final String path;

  @override
  final String? mimeType;

  final VoidCallback _onRelease;
  var _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}
