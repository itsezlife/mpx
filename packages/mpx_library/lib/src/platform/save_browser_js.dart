import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// The browser calls the web's save writer makes, behind one seam so the
/// writer's rules (which destination downloads, a dismissed picker, the
/// fallbacks, the failure reasons) run against a fake in tests.
///
/// Every call passes the browser's errors through as they are (a
/// `DOMException`); the writer reads their names.
abstract interface class SaveBrowser {
  /// The page's own browser.
  const factory SaveBrowser.dom() = _SaveBrowser$Dom;

  /// Whether the browser has a save picker (`showSaveFilePicker`).
  bool get hasSavePicker;

  /// The file at [path] in the origin's private file system, or null when
  /// there is none. [path] is relative to its root, its directories
  /// separated by `/` (a leading `/` is ignored).
  Future<web.Blob?> fileAt(String path);

  /// Hands [blob] to the browser as a download called [name]; the browser
  /// decides whether to ask where.
  void download(web.Blob blob, String name);

  /// Opens the save picker with [name] suggested and returns where the user
  /// chose to write. Throws an `AbortError` when the user dismisses it and a
  /// `SecurityError` when the page has no user activation left to open it.
  Future<SaveSink> pickSaveFile(String name);
}

/// A file the user picked to write into, written chunk by chunk.
abstract interface class SaveSink {
  /// Appends [chunk].
  Future<void> write(web.Blob chunk);

  /// Ends the file; what was written is kept.
  Future<void> close();

  /// Drops the file; nothing written is kept.
  Future<void> abort();
}

@JS('showSaveFilePicker')
external JSPromise<web.FileSystemFileHandle> _showSaveFilePicker(
  _SaveFilePickerOptions options,
);

extension type _SaveFilePickerOptions._(JSObject _) implements JSObject {
  external factory _SaveFilePickerOptions({String suggestedName});
}

final class _SaveBrowser$Dom implements SaveBrowser {
  const _SaveBrowser$Dom();

  /// How long a download's object URL outlives the click. Revoked at once,
  /// some browsers drop the download before they read the blob; kept, the
  /// blob stays in memory for the page's life.
  static const Duration _revokeAfter = Duration(seconds: 30);

  @override
  bool get hasSavePicker => globalContext.has('showSaveFilePicker');

  @override
  Future<web.Blob?> fileAt(String path) async {
    final parts = [
      for (final part in path.split('/'))
        if (part.isNotEmpty) part,
    ];
    if (parts.isEmpty) return null;
    try {
      var directory = await web.window.navigator.storage.getDirectory().toDart;
      for (final part in parts.take(parts.length - 1)) {
        directory = await directory.getDirectoryHandle(part).toDart;
      }
      final handle = await directory.getFileHandle(parts.last).toDart;
      return await handle.getFile().toDart;
    } on Object catch (error) {
      if (SaveBrowser$Errors.nameOf(error)
          case 'NotFoundError' || 'TypeMismatchError') {
        return null;
      }
      rethrow;
    }
  }

  @override
  void download(web.Blob blob, String name) {
    final url = web.URL.createObjectURL(blob);
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = name
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor
      ..click()
      ..remove();
    Timer(_revokeAfter, () => web.URL.revokeObjectURL(url));
  }

  @override
  Future<SaveSink> pickSaveFile(String name) async {
    final handle = await _showSaveFilePicker(
      _SaveFilePickerOptions(suggestedName: name),
    ).toDart;
    return _SaveSink$Dom(await handle.createWritable().toDart);
  }
}

final class _SaveSink$Dom implements SaveSink {
  _SaveSink$Dom(this._stream);

  final web.FileSystemWritableFileStream _stream;

  @override
  Future<void> write(web.Blob chunk) => _stream.write(chunk).toDart;

  @override
  Future<void> close() => _stream.close().toDart;

  @override
  Future<void> abort() => _stream.abort().toDart;
}

/// Reading the browser's errors.
abstract final class SaveBrowser$Errors {
  /// The name of the `DOMException` [error] is (`AbortError`,
  /// `QuotaExceededError` …), or null when it is none. Never its message,
  /// which can carry a file name.
  ///
  /// Read as a property: a `DOMException` type test erases to any JS
  /// object, whose `name` may be absent.
  static String? nameOf(Object error) => switch (error) {
    final JSObject box => switch (box.getProperty<JSAny?>('name'.toJS)) {
      final JSString name => name.toDart,
      _ => null,
    },
    _ => null,
  };
}
