// The journal on the web, over a real origin private file system.
//
// Run with:
// flutter test --platform chrome test/web/journal_web_test.dart
//
// Browser only: OPFS, Blob and beforeunload do not exist on the VM, so this
// file stays out of test/unit_test.dart.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_storage_opfs_js.dart';
import 'package:mpx_transfer/src/journal/platform_journal_store_js.dart';
import 'package:mpx_transfer/src/journal/unload_warning_window_js.dart';
import 'package:mpx_transfer/testing.dart';
import 'package:web/web.dart' as web;

import '../support.dart';

var _directories = 0;

/// A fresh OPFS directory of its own for one test, removed after it.
Future<web.FileSystemDirectoryHandle> _freshDirectory() async {
  final root = await web.window.navigator.storage.getDirectory().toDart;
  final name =
      'mpx_transfer_test_${DateTime.now().microsecondsSinceEpoch}_'
      '${_directories++}';
  addTearDown(
    () => root
        .removeEntry(name, web.FileSystemRemoveOptions(recursive: true))
        .toDart,
  );
  return root
      .getDirectoryHandle(name, web.FileSystemGetDirectoryOptions(create: true))
      .toDart;
}

Future<List<String>> _namesIn(web.FileSystemDirectoryHandle directory) async {
  final names = <String>[];
  for (final name in ['u-a.0', 'u-a.1', 'u-a.kept', 'u-b.0', 'u-b.kept']) {
    try {
      await directory.getFileHandle(name).toDart;
      names.add(name);
    } on Object {
      // Not there.
    }
  }
  return names;
}

web.Blob _blob(List<int> bytes) =>
    web.Blob([Uint8List.fromList(bytes).toJS].toJS);

/// Whether the page's `beforeunload` would ask the user now.
bool _wouldAsk() {
  final event = web.Event('beforeunload', web.EventInit(cancelable: true));
  web.window.dispatchEvent(event);
  return event.defaultPrevented;
}

void main() {
  JournalStoreContract.run('opfs', () async {
    final directory = await _freshDirectory();
    // A new store over the same directory at each start, as a reload
    // reopens it.
    return () => JournalStore$Opfs$JS(directory);
  });

  ReuseTableContract.run('opfs', () async {
    final directory = await _freshDirectory();
    return () => JournalStore$Opfs$JS(directory, name: 'reuse');
  });

  JournalStoreContract.run('memory, where the page has no OPFS', () {
    final store = MemoryJournalStore();
    return () => store;
  });

  UploadSourceCopiesContract.run('opfs', () {
    final directory = _freshDirectory();
    return () async => UploadSourceCopies$Opfs$JS.open(await directory);
  });

  group('OPFS source copies', () {
    test('copy a Blob byte for byte', () async {
      final directory = await _freshDirectory();
      final copies = await UploadSourceCopies$Opfs$JS.open(directory);
      const id = TransferId.parse('u-a');
      await copies.copy(id, [
        SourceBytes$Blob$JS(_blob([1, 2, 3, 4])),
      ]);

      final copy = (await copies.read(id, 0))!;
      expect(copy, isA<SourceBytes$Blob$JS>());
      expect(await copy.read(), [1, 2, 3, 4]);
    });

    test('delete what a reload cut short at the next open', () async {
      final directory = await _freshDirectory();
      final copies = await UploadSourceCopies$Opfs$JS.open(directory);
      await copies.copy(const TransferId.parse('u-b'), [
        MemorySourceBytes(Uint8List(2)),
      ]);
      // A copy of u-a with its first source written and no mark: a reload
      // fell in the middle of it.
      final sources = await directory.getDirectoryHandle('sources').toDart;
      final cut = await sources
          .getFileHandle('u-a.0', web.FileSystemGetFileOptions(create: true))
          .toDart;
      final writable = await cut.createWritable().toDart;
      await writable.write(Uint8List(3).toJS).toDart;
      await writable.close().toDart;

      final again = await UploadSourceCopies$Opfs$JS.open(directory);
      expect(again.held, [const TransferId.parse('u-b')]);
      expect(await _namesIn(sources), ['u-b.0', 'u-b.kept']);
    });
  });

  group('the engine over OPFS', () {
    late RecordingDiagnostics recorder;
    setUp(() => recorder = RecordingDiagnostics.install());

    Future<TransfersHarness> open(
      web.FileSystemDirectoryHandle directory, {
      required int limit,
    }) async {
      final h = await TransfersHarness.open(
        lifecycle: ManualPlaybackLifecycleSource(
          initial: AppLifecycleState.resumed,
        ),
        // A new store and new copies over the same directory at each
        // start, as after a reload.
        store: () => JournalStore$Opfs$JS(directory),
        sourceCopies: () => UploadSourceCopies$Opfs$JS.open(directory),
        sourceCopyLimit: limit,
      );
      addTearDown(() => h.transfers.dispose());
      return h;
    }

    test('a job under the limit resumes after a reload; one over it comes '
        'back failed with its source lost', () async {
      final directory = await _freshDirectory();
      final h = await open(directory, limit: 8);
      final under = h.addUpload(
        sources: [
          SourceBytes$Blob$JS(_blob([1, 2, 3])),
        ],
        total: 3,
      );
      final over = h.addUpload(
        sources: [SourceBytes$Blob$JS(_blob(List.filled(9, 7)))],
      );
      h.runner.progress(under, 1, total: 3);
      await h.settle();
      expect(recorder.whereOp(JournalOp.sourceCopied).single.jobId, under);
      expect(recorder.whereOp(JournalOp.sourceOverLimit), [
        isMpxEvent(jobId: over, fields: {'bytes': 9, 'limit': 8}),
      ]);

      final reloaded = await h.kill();
      expect(
        await stateOf(reloaded, under),
        const TransferState.queued(total: 3),
      );
      expect(
        await stateOf(reloaded, over),
        const TransferState.failed(
          kind: TransferFailureKind.sourceLost,
          retryable: false,
        ),
      );
      expect(recorder.whereOp(JournalOp.sourceLost).single.jobId, over);
      expect(recorder.whereOp(JournalOp.opened).last.fields['store'], 'opfs');

      // The copy the resumed job reads is the source.
      final copies = await UploadSourceCopies$Opfs$JS.open(directory);
      expect(await (await copies.read(under, 0))!.read(), [1, 2, 3]);
    });

    test('a completed job leaves no copy behind', () async {
      final directory = await _freshDirectory();
      final h = await open(directory, limit: 8);
      final id = h.addUpload(
        sources: [
          SourceBytes$Blob$JS(_blob([1])),
        ],
      );
      await h.settle();
      h.runner.complete(id, const FakeTransferResult('r'));
      await h.settle();
      await h.restart();
      expect(
        (await UploadSourceCopies$Opfs$JS.open(directory)).holds(id),
        isFalse,
      );
    });
  });

  group('the page', () {
    late RecordingDiagnostics recorder;
    setUp(() => recorder = RecordingDiagnostics.install());

    test('opens the journal in OPFS', () async {
      final directory = await _freshDirectory();
      final platform = await $openJournalPlatform(
        null,
        root: () async => directory,
      );
      expect(platform.store.kind, JournalStoreKind.opfs);
      expect(platform.sourceCopies, isA<UploadSourceCopies$Opfs$JS>());
      expect(platform.unloadWarning, isA<UnloadWarning$Window$JS>());
    });

    test('falls back to memory and reports an OPFS that refuses to '
        'open', () async {
      final platform = await $openJournalPlatform(
        null,
        root: () => Future.error(web.DOMException('refused', 'SecurityError')),
      );
      expect(platform.store.kind, JournalStoreKind.memory);
      expect(platform.sourceCopies, isA<NoUploadSourceCopies>());
      expect(recorder.whereOp(JournalOp.writeFailed), [
        isMpxEvent(
          level: MpxEventLevel.error,
          fields: {'code': 'dom-SecurityError'},
        ),
      ]);
    });

    test('Transfers.open opens the journal in OPFS', () async {
      final transfers = await Transfers.open(
        cacheKeyOf: (key) => key.encoded,
        lifecycle: ManualPlaybackLifecycleSource(),
      );
      addTearDown(transfers.dispose);
      expect(recorder.whereOp(JournalOp.opened).single.fields['store'], 'opfs');
      expect(transfers.sourceCopyLimit, 500 * 1024 * 1024);
    });

    test('asks before it is left while a job runs, and not once none '
        'does', () async {
      final warning = UnloadWarning$Window$JS();
      final h = await TransfersHarness.open(
        lifecycle: ManualPlaybackLifecycleSource(
          initial: AppLifecycleState.resumed,
        ),
        unloadWarning: warning,
      );
      addTearDown(() => h.transfers.dispose());
      expect(_wouldAsk(), isFalse);

      final id = h.addUpload();
      h.runner.progress(id, 1);
      expect(_wouldAsk(), isTrue);

      h.runner.complete(id, const FakeTransferResult('r'));
      expect(_wouldAsk(), isFalse);

      h.addUpload();
      expect(_wouldAsk(), isTrue);
      await h.transfers.dispose();
      expect(_wouldAsk(), isFalse);
    });
  });
}
