/// The web's media saver in a real browser, its DOM calls behind a fake:
/// `flutter test --platform chrome test/web`. The VM gate skips it
/// (`@TestOn`), and `unit_test.dart` does not import it: `package:web`
/// does not compile for the VM.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_library/mpx_library.dart';
import 'package:mpx_library/src/platform/save_browser_js.dart';
import 'package:mpx_library/src/platform/save_writer_js.dart';
import 'package:mpx_library/testing.dart';
import 'package:web/web.dart' as web;

void main() {
  late _FakeSaveBrowser browser;
  late MediaSaver saver;
  late RecordingDiagnostics diagnostics;

  setUp(() {
    browser = _FakeSaveBrowser();
    saver = _webSaver(browser);
    diagnostics = RecordingDiagnostics.install();
  });

  SaveItem bytes(String text, {String name = 'a.txt'}) => SaveItem.bytes(
    Uint8List.fromList(text.codeUnits),
    name: name,
    mimeType: 'text/plain',
    kind: SaveItemKind.file,
  );

  group('downloads', () {
    test('every item is a download of its bytes, saved with no ref', () async {
      final results = await saver.save([
        bytes('abc', name: 'a.txt'),
        bytes('de', name: 'b.txt'),
      ], const SaveDestination.downloads(subfolder: 'Host')).results;

      expect(results, [
        const SaveResult.saved(null),
        const SaveResult.saved(null),
      ]);
      expect(browser.downloads.map((d) => d.name), ['a.txt', 'b.txt']);
      expect(await browser.downloads.map((d) => d.text).wait, ['abc', 'de']);
      expect(browser.downloads.first.type, 'text/plain');
      expect(diagnostics.whereOp(SaveOp.jobStarted).single.fields, {
        'items': 2,
        'destination': 'downloads',
        'named': true,
        'platform': 'web',
        'photos': 0,
        'videos': 0,
        'animations': 0,
        'files': 2,
      });
      expect(
        diagnostics.whereOp(SaveOp.itemSaved).map((e) => e.fields['bytes']),
        [3, 2],
      );
    });

    test('the gallery is a download too, an animation as its file', () async {
      browser.hasSavePicker = true;
      final results = await saver.save([
        SaveItem.bytes(
          Uint8List.fromList([1, 2, 3, 4]),
          name: 'loop.gif',
          mimeType: 'image/gif',
          kind: SaveItemKind.animation,
        ),
      ], const SaveDestination.gallery(album: 'Host')).results;

      expect(results, [const SaveResult.saved(null)]);
      expect(browser.downloads.single.name, 'loop.gif');
      expect(browser.downloads.single.type, 'image/gif');
      expect(browser.picks, isEmpty);
    });

    test('a file item is read from the private file system', () async {
      browser.files['cache/blobs/k1'] = 'cached';
      final results = await saver.save([
        const SaveItem.file(
          'cache/blobs/k1',
          name: 'k1.mp4',
          mimeType: 'video/mp4',
          kind: SaveItemKind.video,
        ),
        const SaveItem.file(
          'cache/blobs/gone',
          name: 'gone.mp4',
          mimeType: 'video/mp4',
          kind: SaveItemKind.video,
        ),
      ], const SaveDestination.downloads()).results;

      expect(results, [
        const SaveResult.saved(null),
        const SaveResult.failed(SaveFailure.unavailable, code: 'noSource'),
      ]);
      expect(await browser.downloads.single.text, 'cached');
      expect(browser.downloads.single.type, 'video/mp4');
      expect(diagnostics.whereOp(SaveOp.itemFailed), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          fields: {'index': 1, 'reason': 'unavailable', 'code': 'noSource'},
        ),
      ]);
    });
  });

  group('ask', () {
    test('with a save picker each item is written into the picked file in '
        'chunks, saved with no ref', () async {
      browser.hasSavePicker = true;
      final job = _webSaver(
        browser,
        chunkBytes: 2,
      ).save([bytes('abcde', name: 'a.txt')], const SaveDestination.ask());
      final seen = <double>[];
      job.progress.addListener(() => seen.add(job.progress.value));

      expect(await job.results, [const SaveResult.saved(null)]);
      expect(browser.picks.single.name, 'a.txt');
      expect(await browser.picks.single.sink.texts, ['ab', 'cd', 'e']);
      expect(browser.picks.single.sink.closed, isTrue);
      expect(browser.downloads, isEmpty);
      expect(seen, [0.4, 0.8, 1]);
      expect(diagnostics.whereOp(SaveOp.fallbackToAsk), isEmpty);
    });

    test('a picker the user dismisses is cancelled', () async {
      browser
        ..hasSavePicker = true
        ..pickErrors.add('AbortError');
      final results = await saver.save([
        bytes('a', name: 'a.txt'),
        bytes('b', name: 'b.txt'),
      ], const SaveDestination.ask()).results;

      expect(results, [
        const SaveResult.cancelled(),
        const SaveResult.saved(null),
      ]);
      expect(browser.downloads, isEmpty);
      expect(diagnostics.whereOp(SaveOp.itemCancelled), [
        isMpxEvent(fields: containsPair('index', 0)),
      ]);
    });

    test(
      'without a save picker every item is a download, reported once',
      () async {
        final job = saver.save([
          bytes('a', name: 'a.txt'),
          bytes('b', name: 'b.txt'),
        ], const SaveDestination.ask());

        expect(await job.results, [
          const SaveResult.saved(null),
          const SaveResult.saved(null),
        ]);
        expect(browser.downloads.map((d) => d.name), ['a.txt', 'b.txt']);
        expect(diagnostics.whereOp(SaveOp.fallbackToAsk), [
          isMpxEvent(
            level: MpxEventLevel.debug,
            jobId: job.id,
            fields: {'why': 'noSavePicker'},
          ),
        ]);
      },
    );

    test('an item the page has no user activation left for is a '
        'download', () async {
      browser
        ..hasSavePicker = true
        ..pickErrors.addAll([null, 'SecurityError']);
      final results = await saver.save([
        bytes('a', name: 'a.txt'),
        bytes('b', name: 'b.txt'),
      ], const SaveDestination.ask()).results;

      expect(results, [
        const SaveResult.saved(null),
        const SaveResult.saved(null),
      ]);
      expect(browser.picks.map((p) => p.name), ['a.txt']);
      expect(browser.downloads.map((d) => d.name), ['b.txt']);
      expect(diagnostics.whereOp(SaveOp.fallbackToAsk), [
        isMpxEvent(fields: {'why': 'noActivation', 'index': 1}),
      ]);
    });

    test('a cancel between chunks drops the picked file', () async {
      browser.hasSavePicker = true;
      final job = _webSaver(
        browser,
        chunkBytes: 2,
      ).save([bytes('abcdef', name: 'a.txt')], const SaveDestination.ask());
      job.progress.addListener(job.cancel);

      expect(await job.results, [const SaveResult.cancelled()]);
      final sink = browser.picks.single.sink;
      expect(await sink.texts, ['ab']);
      expect(sink.aborted, isTrue);
      expect(sink.closed, isFalse);
    });

    test('the browser\'s write errors name the failure', () async {
      browser.hasSavePicker = true;
      browser.writeErrors.addAll([
        'QuotaExceededError',
        'NotAllowedError',
        'InvalidStateError',
      ]);
      final results = await saver.save([
        bytes('a'),
        bytes('b'),
        bytes('c'),
      ], const SaveDestination.ask()).results;

      expect(results, [
        const SaveResult.failed(
          SaveFailure.noSpace,
          code: 'dom-QuotaExceededError',
        ),
        const SaveResult.failed(
          SaveFailure.accessDenied,
          code: 'dom-NotAllowedError',
        ),
        const SaveResult.failed(
          SaveFailure.unavailable,
          code: 'dom-InvalidStateError',
        ),
      ]);
      expect(browser.picks.map((p) => p.sink.aborted), everyElement(isTrue));
      expect(
        diagnostics.whereOp(SaveOp.itemFailed).map((e) => e.fields['code']),
        [
          'dom-QuotaExceededError',
          'dom-NotAllowedError',
          'dom-InvalidStateError',
        ],
      );
    });
  });

  group('contract, no save picker, files', () {
    MediaSaverContract.run(() {
      final browser = _FakeSaveBrowser();
      return MediaSaverHarness(
        saver: _webSaver(browser),
        file: (index) {
          final path = 'contract/source-$index';
          browser.files[path] = 'photo $index';
          return path;
        },
        destination: const SaveDestination.downloads(),
      );
    });
  });

  group('contract, save picker, bytes', () {
    MediaSaverContract.run(() {
      final browser = _FakeSaveBrowser()..hasSavePicker = true;
      return MediaSaverHarness(
        saver: _webSaver(browser),
        file: (index) {
          final path = 'contract/source-$index';
          browser.files[path] = 'photo $index';
          return path;
        },
        bytes: (index) => Uint8List.fromList('photo $index'.codeUnits),
        destination: const SaveDestination.ask(),
      );
    });
  });

  group('contract, gallery', () {
    MediaSaverContract.run(() {
      final browser = _FakeSaveBrowser();
      return MediaSaverHarness(
        saver: _webSaver(browser),
        file: (index) {
          final path = 'contract/source-$index';
          browser.files[path] = 'photo $index';
          return path;
        },
      );
    });
  });

  group('the page\'s own browser', () {
    const dom = SaveBrowser.dom();

    test('reads a file of the private file system by its path, and none '
        'where there is none', () async {
      final root = await web.window.navigator.storage.getDirectory().toDart;
      final directory = await root
          .getDirectoryHandle(
            'mpx_save_test',
            web.FileSystemGetDirectoryOptions(create: true),
          )
          .toDart;
      addTearDown(
        () => root
            .removeEntry(
              'mpx_save_test',
              web.FileSystemRemoveOptions(recursive: true),
            )
            .toDart,
      );
      final handle = await directory
          .getFileHandle('a.bin', web.FileSystemGetFileOptions(create: true))
          .toDart;
      final stream = await handle.createWritable().toDart;
      await stream.write('opfs'.toJS).toDart;
      await stream.close().toDart;

      final file = await dom.fileAt('/mpx_save_test/a.bin');
      expect((await file!.text().toDart).toDart, 'opfs');
      expect(await dom.fileAt('mpx_save_test/missing.bin'), isNull);
      expect(await dom.fileAt('mpx_save_missing/a.bin'), isNull);
      expect(await dom.fileAt('mpx_save_test'), isNull);
      expect(await dom.fileAt(''), isNull);
    });

    test('tells whether the browser has a save picker', () {
      expect(
        dom.hasSavePicker,
        (web.window as JSObject).has('showSaveFilePicker'),
      );
    });

    test('PlatformMediaSaver is the web writer', () async {
      final job = PlatformMediaSaver().save([
        bytes('a'),
      ], const SaveDestination.downloads())..cancel();

      expect(await job.results, [const SaveResult.cancelled()]);
      expect(diagnostics.whereOp(SaveOp.jobStarted), [
        isMpxEvent(fields: containsPair('platform', 'web')),
      ]);
    });
  });
}

/// The web's [MediaSaver] over its writer with [browser] in place of the
/// DOM.
MediaSaver _webSaver(SaveBrowser browser, {int chunkBytes = 1 << 20}) =>
    PlatformMediaSaver.over(
      SaveWriter$JS(browser: browser, chunkBytes: chunkBytes),
    );

final class _Download {
  _Download(this.blob, this.name);

  final web.Blob blob;
  final String name;

  String get type => blob.type;

  Future<String> get text async => (await blob.text().toDart).toDart;
}

/// A [SaveBrowser] that records downloads and pickers, with a private file
/// system in memory.
final class _FakeSaveBrowser implements SaveBrowser {
  @override
  bool hasSavePicker = false;

  /// Files of the private file system by path.
  final Map<String, String> files = {};

  final List<_Download> downloads = [];

  final List<({String name, _FakeSaveSink sink})> picks = [];

  /// The `DOMException` name each next picker throws; null opens it.
  final List<String?> pickErrors = [];

  /// The `DOMException` name each next picked file's first write throws.
  final List<String> writeErrors = [];

  @override
  Future<web.Blob?> fileAt(String path) async => switch (files[path]) {
    final text? => web.Blob([text.toJS].toJS),
    null => null,
  };

  @override
  void download(web.Blob blob, String name) =>
      downloads.add(_Download(blob, name));

  @override
  Future<SaveSink> pickSaveFile(String name) async {
    if (pickErrors.isNotEmpty) {
      if (pickErrors.removeAt(0) case final error?) {
        _reject(error);
      }
    }
    final sink = _FakeSaveSink(
      writeErrors.isEmpty ? null : writeErrors.removeAt(0),
    );
    picks.add((name: name, sink: sink));
    return sink;
  }
}

final class _FakeSaveSink implements SaveSink {
  _FakeSaveSink(this._writeError);

  final String? _writeError;
  final List<web.Blob> chunks = [];
  bool closed = false;
  bool aborted = false;

  Future<List<String>> get texts async => [
    for (final chunk in chunks) (await chunk.text().toDart).toDart,
  ];

  @override
  Future<void> write(web.Blob chunk) async {
    if (_writeError case final error?) _reject(error);
    chunks.add(chunk);
  }

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> abort() async => aborted = true;
}

/// Fails as the browser does: with a `DOMException` named [name].
Never _reject(String name) =>
    // The browser's own error, which the writer reads by its name.
    // ignore: only_throw_errors
    throw web.DOMException('', name);
