import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/mpx_ui.dart';
import 'package:share_plus/share_plus.dart';

/// The example's gallery: every item is known up front.
final class ListGallery extends ChangeNotifier implements GallerySource {
  ListGallery(this.items);

  final List<GalleryItem> items;

  @override
  int get count => items.length;

  @override
  GalleryItem? itemAt(int index) => items[index];

  @override
  void loadAround(int index) {}
}

/// Where each tile sits: read from its render box. Hidden tiles fade out
/// while the viewer's copy covers them.
final class TileOrigins implements OriginBridge {
  TileOrigins(int count) : keys = List.generate(count, (_) => GlobalKey());

  final List<GlobalKey> keys;

  /// The indexes the viewer covers now.
  final ValueNotifier<Set<int>> hidden = ValueNotifier(const {});

  @override
  GalleryOrigin? originOf(int index) {
    final box = keys[index].currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return GalleryOrigin(
      rect: box.localToGlobal(Offset.zero) & box.size,
      radius: const BorderRadius.all(Radius.circular(12)),
    );
  }

  // Every tile is on screen in the example: nothing to scroll to.
  @override
  Future<void> reveal(int index) async {}

  @override
  void setHidden(int index, {required bool hidden}) {
    this.hidden.value = {
      ...this.hidden.value.where((i) => i != index),
      if (hidden) index,
    };
  }

  // The tiles loop on their own clock; nothing to continue from.
  @override
  void handBack(int index, Duration position) {}
}

/// The bytes cache's file lease as the viewer's file handle.
final class _LeasedFile implements ViewerFile {
  _LeasedFile(this._lease);

  final FileLease _lease;

  @override
  String get path => _lease.path;

  @override
  void release() => _lease.release();
}

/// Opens [stack]'s cached file of a key for a viewer action.
ViewerFileOpener cachedFiles(MpxStack stack) => (key) async {
  final lease = await stack.store.leaseFile(
    BytesCacheFetcher.cacheKeyOf(key, FetchPart.content),
  );
  return lease == null ? null : _LeasedFile(lease);
};

/// The host's save and share. Save asks where with the platform's save
/// panel (desktop); share hands the file to the system share sheet, which
/// also saves to the gallery or Files on mobile. [nameOf] gives a file name
/// with its extension, since the cache stores bytes without one.
List<ViewerAction> saveAndShare(
  BuildContext context,
  String Function(MediaKey key) nameOf,
) => [
  ViewerAction(
    label: 'Save',
    icon: const Icon(Icons.download),
    inBar: true,
    onSelected: (request) async {
      final file = await request.file();
      if (!context.mounted) return;
      if (file == null) return _tell(context, 'Not downloaded yet');
      final name = nameOf(request.item.key);
      final target = await getSaveLocation(suggestedName: name);
      if (target == null) return;
      await File(file.path).copy(target.path);
      if (context.mounted) _tell(context, 'Saved $name');
    },
  ),
  ViewerAction(
    label: 'Share',
    icon: const Icon(Icons.share),
    onSelected: (request) async {
      final file = await request.file();
      if (!context.mounted) return;
      if (file == null) return _tell(context, 'Not downloaded yet');
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          fileNameOverrides: [nameOf(request.item.key)],
        ),
      );
    },
  ),
];

void _tell(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));
}

/// Puts the app window into fullscreen and back, through the example's own
/// channel (macOS); elsewhere nothing happens.
void setWindowFullscreen({required bool fullscreen}) {
  if (kIsWeb || !Platform.isMacOS) return;
  const MethodChannel(
    'mpx_example/window',
  ).invokeMethod<void>('setFullscreen', fullscreen);
}
