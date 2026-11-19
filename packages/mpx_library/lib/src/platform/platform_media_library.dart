import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/library/library_access.dart';
import 'package:mpx_library/src/library/library_album.dart';
import 'package:mpx_library/src/library/library_asset.dart';
import 'package:mpx_library/src/library/library_change.dart';
import 'package:mpx_library/src/library/library_page.dart';
import 'package:mpx_library/src/library/media_library.dart';
import 'package:mpx_library/src/platform/library_wire.dart';

/// The [MediaLibrary] of the platform: MediaStore on Android, PhotoKit on
/// iOS (compiled only under the host's `MPX_LIBRARY_PHOTOS` condition;
/// without it access is [LibraryAccess.restricted]).
///
/// One wire for both ([LibraryWire]). Access is read at creation and again
/// whenever the app resumes. Android's content observers tell no detail and
/// fire in bursts, so its changes are collected for [changeDebounce] (2 s)
/// and come out as one [LibraryChange.reload]; PhotoKit's change details
/// come out per album as they arrive.
final class PlatformMediaLibrary implements MediaLibrary {
  /// Creates the library over the plugin's channels; a test passes its own.
  PlatformMediaLibrary({
    MethodChannel methods = methodsChannel,
    EventChannel events = eventsChannel,
    Duration? changeDebounce,
    bool watchLifecycle = true,
  }) : _methods = methods,
       _events = events,
       changeDebounce =
           changeDebounce ??
           (defaultTargetPlatform == TargetPlatform.android
               ? const Duration(seconds: 2)
               : Duration.zero) {
    _subscription = _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'mpx_library',
            context: ErrorDescription('while observing the media library'),
          ),
        );
      },
    );
    if (watchLifecycle) {
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(refreshAccess()),
      );
    }
    unawaited(refreshAccess());
  }

  /// The plugin's method channel.
  static const MethodChannel methodsChannel = MethodChannel(
    'dev.mpx.library/methods',
  );

  /// The plugin's event channel: access, change and download events.
  static const EventChannel eventsChannel = EventChannel(
    'dev.mpx.library/events',
  );

  /// How long change events are collected into one reload; zero passes
  /// each one on as it comes.
  final Duration changeDebounce;

  final MethodChannel _methods;
  final EventChannel _events;
  final ValueNotifier<LibraryAccess> _access = ValueNotifier(
    LibraryAccess.notDetermined,
  );
  final StreamController<LibraryChange> _changes =
      StreamController<LibraryChange>.broadcast();
  final Set<LibraryAssetId> _cloud = {};
  final Map<int, FetchProgress> _downloads = {};
  // Cancelled in [dispose].
  // ignore: cancel_subscriptions
  StreamSubscription<Object?>? _subscription;
  AppLifecycleListener? _lifecycle;
  Timer? _debounce;
  int _lastRequest = 0;
  bool _disposed = false;

  /// Reads the access again (the user may have changed it in the system
  /// settings); notifies when it changed.
  Future<LibraryAccess> refreshAccess() async {
    final map = await _invoke<Map<Object?, Object?>>('access');
    return _setAccess(map);
  }

  @override
  ValueListenable<LibraryAccess> get access => _access;

  @override
  Future<LibraryAccess> requestAccess() async {
    if (_access.value != LibraryAccess.notDetermined) {
      // Re-read: the first read may not have landed yet.
      final now = await refreshAccess();
      if (now != LibraryAccess.notDetermined) return now;
    }
    return _setAccess(await _invoke<Map<Object?, Object?>>('requestAccess'));
  }

  @override
  Future<bool> manageSelected() async {
    if (!_access.value.canManageSelected) return false;
    await _invoke<void>('manageSelected');
    await refreshAccess();
    return true;
  }

  @override
  Future<void> openSettings() => _invoke<void>('openSettings');

  @override
  Future<List<LibraryAlbum>> albums() async {
    if (!_access.value.canRead) return const [];
    final list = await _invoke<List<Object?>>('albums') ?? const [];
    return [
      for (final item in list.cast<Map<Object?, Object?>>())
        LibraryWire.albumOf(item),
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
    if (!_access.value.canRead) {
      return LibraryPage(
        album: album,
        offset: offset,
        assets: const [],
        total: 0,
      );
    }
    final map = await _invoke<Map<Object?, Object?>>('page', {
      'album': album.value,
      'offset': offset,
      'limit': limit,
    });
    final assets = <LibraryAsset>[];
    for (final item
        in ((map?['assets'] as List<Object?>?) ?? const [])
            .cast<Map<Object?, Object?>>()) {
      final asset = LibraryWire.assetOf(item);
      if (item['cloud'] == true) {
        _cloud.add(asset.id);
      } else {
        _cloud.remove(asset.id);
      }
      assets.add(asset);
    }
    return LibraryPage(
      album: album,
      offset: offset,
      assets: assets,
      total: map?['total'] as int? ?? 0,
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
    final bytes = await _read<Uint8List>(asset, 'thumbnail', {
      'id': asset.value,
      'pixels': pixels,
    });
    if (bytes == null || bytes.isEmpty) throw LibraryAssetUnavailable(asset);
    return bytes;
  }

  @override
  Future<LibraryFileLease> original(
    LibraryAssetId asset, {
    FetchProgress? onProgress,
    CancellationToken? cancellation,
  }) async {
    final request = ++_lastRequest;
    if (onProgress != null) _downloads[request] = onProgress;
    cancellation?.onCancel(
      () => unawaited(_invoke<void>('cancelOriginal', {'request': request})),
    );
    try {
      final map = await _read<Map<Object?, Object?>>(asset, 'original', {
        'id': asset.value,
        'request': request,
      });
      if (map == null) throw LibraryAssetUnavailable(asset);
      _cloud.remove(asset);
      return _PlatformLease(
        map['path']! as String,
        map['mime'] as String?,
        () => _invoke<void>('releaseOriginal', {'path': map['path']}),
      );
    } finally {
      _downloads.remove(request);
    }
  }

  @override
  bool isCloudHeld(LibraryAssetId asset) => _cloud.contains(asset);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _debounce?.cancel();
    _lifecycle?.dispose();
    await _subscription?.cancel();
    await _changes.close();
    _access.dispose();
  }

  // --- Events ---

  void _onEvent(Object? event) {
    if (_disposed || event is! Map<Object?, Object?>) return;
    switch (event['type']) {
      case 'access':
        _setAccess(event);
      case 'progress':
        _downloads[event['request']]?.call(
          event['received'] as int? ?? 0,
          event['total'] as int?,
        );
      case 'changed':
        _changed(event);
    }
  }

  void _changed(Map<Object?, Object?> event) {
    if (changeDebounce > Duration.zero) {
      _debounce?.cancel();
      _debounce = Timer(changeDebounce, () {
        if (!_disposed) _changes.add(const LibraryChange.reload());
      });
      return;
    }
    final album = event['album'] as String?;
    if (album == null) return _changes.add(const LibraryChange.reload());
    Set<LibraryAssetId> ids(String key) => {
      for (final id in (event[key] as List<Object?>?) ?? const [])
        LibraryAssetId(id! as String),
    };
    _changes.add(
      LibraryChange.album(
        LibraryAlbumId(album),
        inserted: ids('inserted'),
        removed: ids('removed'),
        changed: ids('changed'),
      ),
    );
  }

  // --- Calls ---

  LibraryAccess _setAccess(Map<Object?, Object?>? map) {
    if (map == null || _disposed) return _access.value;
    return _access.value = LibraryWire.accessOf(map);
  }

  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }

  Future<T?> _read<T>(
    LibraryAssetId asset,
    String method,
    Map<String, Object?> arguments,
  ) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      throw switch (error.code) {
        'download' => LibraryDownloadFailed(asset, error.message ?? 'download'),
        _ => LibraryAssetUnavailable(asset, error.message ?? error.code),
      };
    } on MissingPluginException {
      throw LibraryAssetUnavailable(asset, 'no native side');
    }
  }
}

final class _PlatformLease implements LibraryFileLease {
  _PlatformLease(this.path, this.mimeType, this._release);

  @override
  final String path;

  @override
  final String? mimeType;

  final Future<void> Function() _release;
  bool _released = false;

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}
