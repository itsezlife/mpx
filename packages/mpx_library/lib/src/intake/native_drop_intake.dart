import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mpx_library/src/intake/drop_intake.dart';
import 'package:mpx_library/src/intake/file_intake.dart';
import 'package:mpx_library/src/intake/intake_files.dart';
import 'package:super_clipboard/super_clipboard.dart' as clipboard;
import 'package:super_drag_and_drop/super_drag_and_drop.dart' as dnd;

/// The native [DropSource]: `super_drag_and_drop`'s drop region around the
/// host's widget ([wrap]). Items are taken as local file URIs; an item that
/// is not one (a link, text, a promised file) is refused.
final class NativeDropSource implements DropSource {
  final StreamController<DropEvent> _events =
      StreamController<DropEvent>.broadcast(sync: true);

  @override
  Stream<DropEvent> get events => _events.stream;

  @override
  Widget wrap(Widget child) => dnd.DropRegion(
    formats: dnd.Formats.standardFormats,
    hitTestBehavior: HitTestBehavior.opaque,
    onDropEnter: (event) => _events.add(DropEnter(_offerOf(event.session))),
    onDropOver: (event) {
      _events.add(const DropOver());
      return event.session.allowedOperations.contains(dnd.DropOperation.copy)
          ? dnd.DropOperation.copy
          : dnd.DropOperation.none;
    },
    onDropLeave: (_) => _events.add(const DropLeave()),
    onPerformDrop: (event) async {
      final files = <IntakeFile>[];
      var refused = 0;
      for (final item in event.session.items) {
        final file = await _fileOf(item.dataReader);
        if (file == null) {
          refused++;
        } else {
          files.add(file);
        }
      }
      _events.add(DropDone(files, refused: refused));
    },
    child: child,
  );

  static DropOffer _offerOf(dnd.DropSession session) {
    final types = [for (final item in session.items) ...item.platformFormats];
    final hasFiles = session.items.any(
      (item) => item.canProvide(dnd.Formats.fileUri),
    );
    return DropOffer(types: types, hasFiles: hasFiles || types.isEmpty);
  }

  static Future<IntakeFile?> _fileOf(clipboard.DataReader? reader) async {
    if (reader == null || !reader.canProvide(dnd.Formats.fileUri)) {
      return null;
    }
    final done = Completer<Uri?>();
    final progress = reader.getValue<Uri>(
      dnd.Formats.fileUri,
      done.complete,
      onError: (_) => done.complete(null),
    );
    if (progress == null) return null;
    final uri = await done.future;
    if (uri == null || !uri.isScheme('file')) return null;
    return IntakeFiles.fromPath(uri.toFilePath());
  }
}

/// The native [ClipboardReader]: `super_clipboard`'s system clipboard.
/// File URIs come back as their files; image data is written into
/// [directory] (the system temporary folder by default) on the IO threads.
final class NativeClipboardReader implements ClipboardReader {
  /// Creates the reader.
  NativeClipboardReader({String? directory})
    : directory = directory ?? Directory.systemTemp.path;

  /// Where pasted image data is written.
  final String directory;

  static const List<(clipboard.FileFormat, String)> _images = [
    (clipboard.Formats.png, 'image/png'),
    (clipboard.Formats.jpeg, 'image/jpeg'),
    (clipboard.Formats.gif, 'image/gif'),
    (clipboard.Formats.webp, 'image/webp'),
    (clipboard.Formats.heic, 'image/heic'),
    (clipboard.Formats.tiff, 'image/tiff'),
  ];

  @override
  Future<List<IntakeFile>> readFiles() async {
    final system = clipboard.SystemClipboard.instance;
    if (system == null) return const [];
    final reader = await system.read();
    final files = <IntakeFile>[];
    for (final item in reader.items) {
      if (item.canProvide(clipboard.Formats.fileUri)) {
        final uri = await item.readValue(clipboard.Formats.fileUri);
        if (uri != null && uri.isScheme('file')) {
          final file = await IntakeFiles.fromPath(uri.toFilePath());
          if (file != null) files.add(file);
          continue;
        }
      }
      for (final (format, mime) in _images) {
        if (!item.canProvide(format)) continue;
        final done = Completer<IntakeFile?>();
        final progress = item.getFile(format, (file) async {
          try {
            final bytes = await file.readAll();
            done.complete(
              await IntakeFiles.fromBytes(
                bytes,
                mimeType: mime,
                directory: directory,
                name: file.fileName,
              ),
            );
          } on Object {
            done.complete(null);
          } finally {
            file.close();
          }
        }, onError: (_) => done.complete(null));
        if (progress == null) continue;
        final file = await done.future;
        if (file != null) files.add(file);
        break;
      }
    }
    return files;
  }
}
