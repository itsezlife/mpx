import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mpx_library/src/intake/drop_intake.dart';
import 'package:mpx_library/src/intake/file_intake.dart';

/// A [DropSource] a test drives: [add] puts drag events out as the platform
/// would.
final class FakeDropSource implements DropSource {
  final StreamController<DropEvent> _events =
      StreamController<DropEvent>.broadcast(sync: true);

  @override
  Stream<DropEvent> get events => _events.stream;

  @override
  Widget wrap(Widget child) => child;

  /// Reports [event].
  void add(DropEvent event) => _events.add(event);

  /// Reports a whole drag of [files]: enter, over, drop.
  void drop(List<IntakeFile> files, {int refused = 0}) {
    add(const DropEnter(DropOffer(types: ['Files'])));
    add(const DropOver());
    add(DropDone(files, refused: refused));
  }

  /// Ends the source.
  Future<void> close() => _events.close();
}

/// A [ClipboardReader] over files a test puts on its clipboard.
final class FakeClipboardReader implements ClipboardReader {
  /// Creates a reader whose clipboard holds [files].
  FakeClipboardReader([List<IntakeFile> files = const []])
    : files = List.of(files);

  /// What the clipboard holds.
  List<IntakeFile> files;

  /// How many times [readFiles] ran.
  int reads = 0;

  @override
  Future<List<IntakeFile>> readFiles() async {
    reads++;
    return List.unmodifiable(files);
  }
}
