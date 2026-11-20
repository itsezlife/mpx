import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/widgets.dart';
import 'package:mpx_library/src/intake/drop_intake.dart';
import 'package:mpx_library/src/intake/file_intake.dart';
import 'package:web/web.dart' as web;

/// The web's file intake.
Future<FileIntake> $createFileIntake() async => WebFileIntake();

/// The web's drop source.
DropSource? $createDropSource() => WebDropSource();

/// The web's clipboard reader.
ClipboardReader? $createClipboardReader() => const WebClipboardReader();

IntakeFile _intakeOf(web.File file) => IntakeFile(
  source: IntakeSource.blob(file),
  name: file.name,
  size: file.size,
  mimeType: file.type.isEmpty ? null : file.type,
  modified: DateTime.fromMillisecondsSinceEpoch(file.lastModified),
);

List<IntakeFile> _filesOf(web.FileList? list) => [
  if (list != null)
    for (var i = 0; i < list.length; i++) ?list.item(i).let(_intakeOf),
];

extension<T extends Object> on T? {
  R? let<R>(R Function(T) map) {
    final value = this;
    return value == null ? null : map(value);
  }
}

/// The web's [FileIntake]: a hidden file input with `accept` and
/// `multiple`. Browsers say nothing when the dialog is dismissed (older
/// ones send no `cancel`), so a pick that has answered nothing within
/// [idleAfterFocus] of the window getting its focus back ends empty.
/// Files are blob handles ([IntakeSource.blob] of a `File`). There is no
/// system camera.
final class WebFileIntake implements FileIntake {
  /// Creates the intake.
  WebFileIntake({this.idleAfterFocus = const Duration(milliseconds: 1000)});

  /// How long after the window's focus returns a pick waits for files.
  final Duration idleAfterFocus;

  @override
  bool get canCaptureWithSystemCamera => false;

  @override
  Future<List<IntakeFile>> pickFiles({
    IntakeFilter filter = IntakeFilter.allFiles,
    bool multiple = true,
  }) {
    final done = Completer<List<IntakeFile>>();
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..multiple = multiple
      ..accept = switch (filter) {
        IntakeFilter.allFiles => '',
        IntakeFilter.images => 'image/*',
        IntakeFilter.videos => 'video/*',
        IntakeFilter.imagesAndVideos => 'image/*,video/*',
      };
    input.style.display = 'none';
    Timer? idle;
    void finish(List<IntakeFile> files) {
      if (done.isCompleted) return;
      idle?.cancel();
      input.remove();
      done.complete(files);
    }

    final JSFunction onFocus = ((web.Event _) {
      idle?.cancel();
      idle = Timer(idleAfterFocus, () => finish(const []));
    }).toJS;
    input
      ..addEventListener(
        'change',
        ((web.Event _) => finish(_filesOf(input.files))).toJS,
      )
      ..addEventListener('cancel', ((web.Event _) => finish(const [])).toJS);
    web.window.addEventListener('focus', onFocus);
    unawaited(
      done.future.whenComplete(
        () => web.window.removeEventListener('focus', onFocus),
      ),
    );
    web.document.body?.append(input);
    input.click();
    return done.future;
  }

  @override
  Future<IntakeFile?> captureWithSystemCamera(IntakeCaptureKind kind) =>
      throw UnsupportedError('no system camera on the web');
}

/// The web's [DropSource]: the document's DOM drag events. Enter and leave
/// fire for every nested element; `DropTracker` counts them. A drag that
/// tells no types (Safari, before the drop) is offered as unknown files;
/// items that are not files (links, text) are refused at the drop.
final class WebDropSource implements DropSource {
  /// Creates the source; it listens while [events] has a listener.
  WebDropSource() {
    _events = StreamController<DropEvent>.broadcast(
      onListen: _listen,
      onCancel: _unlisten,
    );
  }

  late final StreamController<DropEvent> _events;
  final Map<String, JSFunction> _handlers = {};

  @override
  Stream<DropEvent> get events => _events.stream;

  /// The document is listened to whole: [child] needs no region.
  @override
  Widget wrap(Widget child) => child;

  void _listen() {
    _handlers
      ..['dragenter'] = ((web.DragEvent event) {
        event.preventDefault();
        _events.add(
          DropEnter(_offerOf(event.dataTransfer), position: _positionOf(event)),
        );
      }).toJS
      ..['dragover'] = ((web.DragEvent event) {
        // Without it the browser opens the file instead of dropping it.
        event.preventDefault();
        _events.add(DropOver(position: _positionOf(event)));
      }).toJS
      ..['dragleave'] = ((web.DragEvent _) {
        _events.add(const DropLeave());
      }).toJS
      ..['drop'] = ((web.DragEvent event) {
        event.preventDefault();
        final transfer = event.dataTransfer;
        final files = _filesOf(transfer?.files);
        final types = _typesOf(transfer);
        final links =
            files.isEmpty &&
            (types.contains('text/uri-list') || types.contains('text/plain'));
        _events.add(
          DropDone(files, refused: links ? 1 : 0, position: _positionOf(event)),
        );
      }).toJS;
    // A closure: interop members cannot be torn off.
    // ignore: unnecessary_lambdas
    _handlers.forEach(
      (type, handler) => web.document.addEventListener(type, handler),
    );
  }

  void _unlisten() {
    // A closure: interop members cannot be torn off.
    // ignore: unnecessary_lambdas
    _handlers.forEach(
      (type, handler) => web.document.removeEventListener(type, handler),
    );
    _handlers.clear();
  }

  // The page's CSS pixels are the Flutter view's logical pixels when the
  // view fills the window, as it does for a Flutter web app.
  static Offset _positionOf(web.DragEvent event) =>
      Offset(event.clientX.toDouble(), event.clientY.toDouble());

  static List<String> _typesOf(web.DataTransfer? transfer) => [
    if (transfer != null)
      for (final type in transfer.types.toDart) type.toDart,
  ];

  static DropOffer _offerOf(web.DataTransfer? transfer) {
    final types = _typesOf(transfer);
    if (types.isEmpty) return const DropOffer();
    return DropOffer(types: types, hasFiles: types.contains('Files'));
  }
}

/// The web's [ClipboardReader]: the async clipboard's image items, as blob
/// handles. The browser asks the user the first time.
final class WebClipboardReader implements ClipboardReader {
  /// Creates the reader.
  const WebClipboardReader();

  @override
  Future<List<IntakeFile>> readFiles() async {
    final List<web.ClipboardItem> items;
    try {
      items = (await web.window.navigator.clipboard.read().toDart).toDart;
    } on Object {
      return const [];
    }
    final files = <IntakeFile>[];
    for (final item in items) {
      for (final type in item.types.toDart.map((t) => t.toDart)) {
        if (!type.startsWith('image/')) continue;
        final blob = await item.getType(type).toDart;
        files.add(
          IntakeFile(
            source: IntakeSource.blob(blob),
            name: 'pasted.${type.substring(6)}',
            size: blob.size,
            mimeType: type,
            modified: DateTime.now(),
          ),
        );
        break;
      }
    }
    return files;
  }
}
