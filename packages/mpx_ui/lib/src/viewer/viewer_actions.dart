import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';

/// A file on disk the host holds for the viewer while an action uses it: the
/// cached bytes of an item. The viewer releases it when the action is done,
/// so the host's cache may evict it again.
///
/// A host over a bytes cache with file handouts wraps its lease in this; the
/// package depends on no cache.
abstract interface class ViewerFile {
  /// Where the file is.
  String get path;

  /// Gives the file back. Idempotent.
  void release();
}

/// Opens the cached file of [key], or answers null when the bytes are not on
/// the device (not downloaded yet, evicted).
typedef ViewerFileOpener = Future<ViewerFile?> Function(MediaKey key);

/// What a host action is handed: the item, its cached file and the picture
/// as it shows now. Files opened through [file] are released by the viewer
/// once the action completes.
final class ViewerActionRequest {
  /// Creates a request; the viewer makes them.
  ViewerActionRequest({
    required this.index,
    required this.item,
    required Future<ViewerFile?> Function() openFile,
    required Future<ui.Image?> Function() captureFrame,
  }) : _openFile = openFile,
       _captureFrame = captureFrame;

  /// The index of the item.
  final int index;

  /// The item.
  final GalleryItem item;

  final Future<ViewerFile?> Function() _openFile;
  final Future<ui.Image?> Function() _captureFrame;
  final List<ViewerFile> _opened = [];
  bool _done = false;

  /// The item's cached file, or null when it is not on the device. Valid
  /// until the action completes.
  Future<ViewerFile?> file() async {
    final file = await _openFile();
    if (file == null) return null;
    if (_done) {
      file.release();
      return null;
    }
    _opened.add(file);
    return file;
  }

  /// The picture as the viewer shows it now (the current frame of a video),
  /// or null when it has nothing drawn. The caller owns the image.
  Future<ui.Image?> frame() => _captureFrame();

  /// Releases every file the action opened. Called by the viewer.
  void complete() {
    _done = true;
    for (final file in _opened) {
      file.release();
    }
    _opened.clear();
  }
}

/// One action the host offers for an item: save, share, show in the list.
/// [inBar] actions sit in the top bar as icons; the others are items of the
/// overflow menu, in order.
@immutable
final class ViewerAction {
  /// Creates an action.
  const ViewerAction({
    required this.label,
    required this.onSelected,
    this.icon,
    this.inBar = false,
  }) : assert(!inBar || icon != null, 'A bar action needs an icon.');

  /// The menu text, and the bar icon's semantic label.
  final String label;

  /// The icon, drawn in the tokens' foreground colour.
  final Widget? icon;

  /// Whether it sits in the top bar rather than the menu.
  final bool inBar;

  /// Runs the action. The viewer waits for it to complete before it releases
  /// the files the action opened.
  final FutureOr<void> Function(ViewerActionRequest request) onSelected;
}

/// Builds a piece of chrome for the item at [index].
typedef ViewerItemBuilder =
    Widget? Function(BuildContext context, int index, GalleryItem item);

/// The texts the viewer draws itself.
@immutable
final class ViewerStrings {
  /// Creates strings; the defaults are English.
  const ViewerStrings({
    this.counter = _counter,
    this.back = 'Back',
    this.more = 'More',
  });

  static String _counter(int position, int count) => '$position of $count';

  /// The "N of M" counter, [position] counting from 1.
  final String Function(int position, int count) counter;

  /// The back button's semantic label.
  final String back;

  /// The overflow button's semantic label.
  final String more;
}

/// What the viewer draws over its pages, and what the host fills in: the
/// actions per item, the title, subtitle and caption builders, the strings
/// and how files are opened. Rich text stays the host's: a builder returns
/// any widget.
@immutable
final class ViewerChrome {
  /// Creates the chrome.
  const ViewerChrome({
    this.actions,
    this.openFile,
    this.title,
    this.subtitle,
    this.caption,
    this.strings = const ViewerStrings(),
    this.thumbnails = false,
    this.backIcon,
    this.moreIcon,
  });

  /// The actions of an item; none when null.
  final List<ViewerAction> Function(int index, GalleryItem item)? actions;

  /// Opens an item's cached file for an action; actions get no file when
  /// null.
  final ViewerFileOpener? openFile;

  /// The title (the author, the kind of media).
  final ViewerItemBuilder? title;

  /// The line under the title (the date).
  final ViewerItemBuilder? subtitle;

  /// The caption under the picture.
  final ViewerItemBuilder? caption;

  /// The texts the viewer draws itself.
  final ViewerStrings strings;

  /// Whether a strip of the gallery's thumbnails shows at the bottom.
  final bool thumbnails;

  /// The back button's icon; a plain arrow when null.
  final Widget? backIcon;

  /// The overflow button's icon; three dots when null.
  final Widget? moreIcon;
}
