import 'dart:js_interop';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/platform/save_browser_js.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_op.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';
import 'package:web/web.dart' as web;

/// The save writer of the web.
SaveWriter $createSaveWriter() => SaveWriter$JS();

/// The web's [SaveWriter]: every save is a download, except `ask` where the
/// browser has a save picker.
///
/// - `gallery` and `downloads` hand the item to the browser as a download
///   (an object URL on an `<a download>`); the browser decides whether to
///   ask where, and an album or a sub-folder has no meaning here.
/// - `ask` opens the save picker for each item and writes the item into the
///   file the user picked, in chunks of [chunkBytes] with progress and
///   cancel between them. A dismissed picker is `cancelled`. Without a
///   picker, or when the page has no user activation left to open one (the
///   browser lets a page open it only shortly after a user gesture, so a
///   batch's later items may find it spent), the item is a download.
/// - The browser confirms nothing about a download, so every saved item is
///   `saved(null)`.
/// - An item's bytes are its [SaveItem.bytes], or the file at its
///   [SaveItem.path] in the origin's private file system (where a keeper
///   holds content as files on the web); a path with no file there fails
///   `unavailable` (code `noSource`).
/// - An animation, like any kind, saves as its file.
final class SaveWriter$JS extends SaveWriter$PerItem {
  /// The writer over [browser] (the page's own by default).
  SaveWriter$JS({
    SaveBrowser browser = const SaveBrowser.dom(),
    this.chunkBytes = 1 << 20,
  }) : _browser = browser,
       assert(chunkBytes > 0, 'A chunk holds at least one byte.');

  final SaveBrowser _browser;

  /// How much of an item goes into the picked file between two progress
  /// reports and cancel checks.
  final int chunkBytes;

  @override
  String get platform => 'web';

  @override
  Future<SaveResult$Failed?> admit(
    String jobId,
    SaveDestination destination,
    List<SaveItem> items,
  ) async {
    if (destination is SaveDestination$Ask && !_browser.hasSavePicker) {
      _fallback(jobId, 'noSavePicker');
    }
    // The web asks for no access.
    return null;
  }

  @override
  Future<SaveResult> write(
    SaveWrite write, {
    required FetchProgress onProgress,
    required CancellationToken cancellation,
  }) async {
    final item = write.item;
    final source = await _sourceOf(item);
    if (source == null) {
      return const SaveResult.failed(SaveFailure.unavailable, code: 'noSource');
    }
    if (cancellation.isCancelled) return const SaveResult.cancelled();
    if (write.destination is! SaveDestination$Ask || !_browser.hasSavePicker) {
      return _download(source, item, onProgress);
    }
    final SaveSink sink;
    try {
      sink = await _browser.pickSaveFile(item.name);
    } on Object catch (error, stackTrace) {
      switch (SaveBrowser$Errors.nameOf(error)) {
        case 'AbortError':
          return const SaveResult.cancelled();
        case 'SecurityError':
          _fallback(write.jobId, 'noActivation', index: write.index);
          return _download(source, item, onProgress);
        case final name?:
          return _failureOf(name);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    return _writeInto(sink, source, onProgress, cancellation);
  }

  /// The item's content as a blob typed with its MIME type, or null when
  /// its file is not there.
  Future<web.Blob?> _sourceOf(SaveItem item) async {
    final options = web.BlobPropertyBag(type: item.mimeType);
    if (item.bytes case final bytes?) {
      return web.Blob([bytes.toJS].toJS, options);
    }
    final file = await _browser.fileAt(item.path!);
    // Wrapping retypes the file without copying it.
    return file == null ? null : web.Blob([file].toJS, options);
  }

  SaveResult _download(
    web.Blob source,
    SaveItem item,
    FetchProgress onProgress,
  ) {
    _browser.download(source, item.name);
    onProgress(source.size, source.size);
    return const SaveResult.saved(null);
  }

  Future<SaveResult> _writeInto(
    SaveSink sink,
    web.Blob source,
    FetchProgress onProgress,
    CancellationToken cancellation,
  ) async {
    final total = source.size;
    try {
      for (var start = 0; start < total; start += chunkBytes) {
        if (cancellation.isCancelled) return _abort(sink);
        final end = start + chunkBytes < total ? start + chunkBytes : total;
        await sink.write(source.slice(start, end));
        onProgress(end, total);
      }
      if (cancellation.isCancelled) return _abort(sink);
      await sink.close();
    } on Object catch (error) {
      try {
        await sink.abort();
      } on Object {
        // The stream is broken already: the first error is the item's.
      }
      if (SaveBrowser$Errors.nameOf(error) case final name?) {
        return _failureOf(name);
      }
      rethrow;
    }
    return const SaveResult.saved(null);
  }

  /// Drops the half-written file of a cancelled item.
  static Future<SaveResult> _abort(SaveSink sink) async {
    await sink.abort();
    return const SaveResult.cancelled();
  }

  /// The failure a `DOMException` named [name] stands for.
  static SaveResult$Failed _failureOf(String name) =>
      SaveResult$Failed(switch (name) {
        'QuotaExceededError' => SaveFailure.noSpace,
        'NotAllowedError' => SaveFailure.accessDenied,
        _ => SaveFailure.unavailable,
      }, code: 'dom-$name');

  static void _fallback(String jobId, String why, {int? index}) =>
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        SaveOp.fallbackToAsk,
        jobId: jobId,
        fields: () => {'why': why, 'index': ?index},
      );
}
