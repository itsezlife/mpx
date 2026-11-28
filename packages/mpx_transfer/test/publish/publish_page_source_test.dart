import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

const Duration _window = Duration(milliseconds: 20);

/// Longer than [_window], so the window before it has been written.
const Duration _pastWindow = Duration(milliseconds: 80);

/// Media the host prepared at [path], where no file is, holding [bytes]
/// (none for a picked original read from the item's page source).
PreparedMedia _mediaAt(String path, int size, {Uint8List? bytes}) =>
    PreparedMedia(
      kind: PreparedKind.photo,
      path: path,
      isOriginal: bytes == null,
      byteSize: size,
      mimeType: 'image/jpeg',
      bytes: bytes,
    );

/// The real file system, as the VM's engine reads it.
final class _Disk implements UploadSourceFiles {
  const _Disk();

  @override
  Future<UploadSourceStat?> stat(String path) async {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return null;
    return UploadSourceStat(size: stat.size, modified: stat.modified);
  }
}

/// Waits until [done], for work on the real file system, which an event
/// queue pump does not wait for.
Future<void> _until(bool Function() done) async {
  for (var wait = 0; wait < 200 && !done(); wait++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settled(UploadsHarness h) async {
  await pumpEventQueue();
  await h.transfers.debugSourcesCopied;
  await pumpEventQueue();
}

void main() {
  late RecordingDiagnostics recorder;

  setUp(() => recorder = RecordingDiagnostics.install());

  group('on the VM', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('mpx_page_sources_');
      addTearDown(() => directory.delete(recursive: true));
    });

    List<File> written() => [
      for (final entry in directory.listSync(recursive: true))
        if (entry is File) entry,
    ];

    test('prepared bytes with no file at the path are written to a file of '
        'the engine, uploaded, and deleted once the job completed', () async {
      final transport = fakeTransport(partSize: 4, holdParts: true);
      final h = await publishing(
        [transport],
        files: const _Disk(),
        sourceDirectory: directory.path,
      );
      final publisher = FakePublisher();
      h.transfers.registerPublisher(publisherId, publisher);
      final bytes = Uint8List.fromList(List.generate(10, (i) => i));
      final job = h.transfers.publish(
        requestOf([
          itemOf(
            'a',
            PublishSource.prepared(
              _mediaAt('/nowhere/a.jpg', 99, bytes: bytes),
            ),
          ),
        ]),
      );
      await _until(() => transport.opens.isNotEmpty);

      final file = written().single;
      expect(file.readAsBytesSync(), bytes);
      expect(file.path, startsWith('${directory.path}/${job.id}/'));
      expect(transport.opens.single.info.size, 10);
      final copied = recorder.whereOp(JournalOp.sourceCopied).single;
      expect(copied.level, MpxEventLevel.debug);
      expect(copied.fields['bytes'], 10);
      expect(copied.jobId, startsWith('u-'));

      transport.holdParts = false;
      for (final index in [0, 1, 2]) {
        transport.ack(index);
        await pumpEventQueue();
      }
      await pumpEventQueue();
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(transport.finishes.single.finalSize, 10);
      expect(recorder.errors, isEmpty);
      await _until(() => written().isEmpty);
      expect(written(), isEmpty);
      expect(recorder.errors, isEmpty);
      for (final event in recorder.events) {
        expect(event.fields.values, isNot(contains(contains('/'))));
      }
    });

    test(
      "an item's page source is written the same way where no file is",
      () async {
        final transport = fakeTransport();
        final h = await publishing(
          [transport],
          files: const _Disk(),
          sourceDirectory: directory.path,
        );
        h.transfers.registerPublisher(publisherId, FakePublisher());
        final job = h.transfers.publish(
          requestOf([
            PublishItem(
              itemId: 'a',
              key: keyOf('a'),
              source: PublishSource.prepared(_mediaAt('/nowhere/a.jpg', 7)),
              pageSource: SourceBytes.memory(Uint8List(7)),
            ),
          ]),
        );
        await _until(() => job.snapshot.state is PublishJobState$Completed);
        expect(job.snapshot.state, const PublishJobState.completed(null));
        expect(transport.finishes.single.finalSize, 7);
        expect(recorder.whereOp(JournalOp.sourceCopied), hasLength(1));
      },
    );

    test('a file at the path wins over prepared bytes', () async {
      final transport = fakeTransport();
      final h = await publishing([transport], sourceDirectory: directory.path);
      h.transfers.registerPublisher(publisherId, FakePublisher());
      final media = preparedOf(12);
      final job = h.transfers.publish(
        requestOf([
          itemOf(
            'a',
            PublishSource.prepared(
              PreparedMedia(
                kind: media.kind,
                path: media.path,
                isOriginal: false,
                byteSize: 12,
                bytes: Uint8List(3),
              ),
            ),
          ),
        ]),
      );
      await pumpEventQueue();
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(transport.finishes.single.finalSize, 12);
      expect(recorder.whereOp(JournalOp.sourceCopied), isEmpty);
      expect(written(), isEmpty);
    });

    test('files a kill left for a job that is gone are swept at the next '
        'start; those of a running job stay', () async {
      final transport = fakeTransport(holdParts: true);
      final h = await publishing(
        [transport],
        files: const _Disk(),
        sourceDirectory: directory.path,
      );
      Directory(
        '${directory.path}/p-gone/mpx_upload_x',
      ).createSync(recursive: true);
      h.transfers.publish(
        requestOf([
          itemOf(
            'a',
            PublishSource.prepared(
              _mediaAt('/nowhere/a.jpg', 4, bytes: Uint8List(4)),
            ),
          ),
        ]),
      );
      await _until(() => transport.opens.isNotEmpty);
      await h.settle();
      await h.kill();
      final gone = Directory('${directory.path}/p-gone');
      await _until(() => !gone.existsSync());
      expect(gone.existsSync(), isFalse);
      expect(written(), hasLength(1));
    });

    test('a page source on a retry of an upload is refused: the VM reads '
        'a file', () async {
      final h = await uploads([fakeTransport()]);
      final id = h.upload(sourceOf(4));
      expect(
        () =>
            h.transfers.retry(id, pageSource: SourceBytes.memory(Uint8List(1))),
        throwsArgumentError,
      );
    });

    test('a blob source is the web only', () {
      expect(() => SourceBytes.blob(Object()), throwsUnsupportedError);
    });
  });

  group('where uploads read page sources (the web)', () {
    late FakeUploadSourceCopies copies;

    setUp(() => copies = FakeUploadSourceCopies());

    Future<UploadsHarness> web(FakeUploadTransport transport) async {
      final h = await publishing(
        [transport],
        sourceCopies: copies,
        progressInterval: _window,
      );
      h.transfers.registerPublisher(publisherId, FakePublisher());
      return h;
    }

    PublishItem picked(String id, int size) => PublishItem(
      itemId: id,
      key: keyOf(id),
      source: PublishSource.prepared(_mediaAt('blob:picked-$id', size)),
      pageSource: SourceBytes.memory(Uint8List(size)),
    );

    test('a picked file uploads from the page and is copied', () async {
      final transport = fakeTransport(partSize: 4);
      final h = await web(transport);
      final job = h.transfers.publish(requestOf([picked('a', 10)]));
      await _settled(h);

      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(transport.finishes.single.finalSize, 10);
      final upload = recorder.whereOp(JournalOp.sourceCopied).single;
      expect(upload.fields, {'bytes': 10, 'ms': isA<int>()});
      expect(recorder.errors, isEmpty);
    });

    test('prepared bytes upload from the page', () async {
      final transport = fakeTransport();
      final h = await web(transport);
      final job = h.transfers.publish(
        requestOf([
          itemOf(
            'a',
            PublishSource.prepared(
              _mediaAt('out-1.jpg', 99, bytes: Uint8List(6)),
            ),
          ),
        ]),
      );
      await _settled(h);
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(transport.finishes.single.finalSize, 6);
      expect(
        recorder.whereOp(JournalOp.sourceCopied).single.fields['bytes'],
        6,
      );
    });

    test('a reload mid upload resumes from the copy', () async {
      final transport = fakeTransport(
        partSize: 4,
        bytesInFlight: 4,
        holdParts: true,
      );
      final h = await web(transport);
      final job = h.transfers.publish(requestOf([picked('a', 12)]));
      await _settled(h);
      transport.ack(0);
      await Future<void>.delayed(_pastWindow);
      await h.settle();
      expect(copies.held, hasLength(1));

      recorder.clear();
      transport.holdParts = false;
      await h.kill();
      h.transfers.registerPublisher(publisherId, FakePublisher());
      await _settled(h);

      expect(
        h.transfers.publishJob(job.id)!.snapshot.state,
        const PublishJobState.completed(null),
      );
      expect(transport.opens.last.resumeToken, isNotNull);
      expect(recorder.whereOp(JournalOp.sourceLost), isEmpty);
      expect(
        recorder.whereOp(TransportOp.resumeDecision).single.fields['outcome'],
        'resumed',
      );
      expect(recorder.errors, isEmpty);
    });

    test('a reload that kept no copy fails the item with its source lost; '
        'a retry with the file picked again uploads it from zero', () async {
      final transport = fakeTransport(partSize: 4, holdParts: true);
      final h = await web(transport);
      copies.holdCopies();
      final job = h.transfers.publish(requestOf([picked('a', 12)]));
      await pumpEventQueue();
      await h.settle();
      copies.cutCopies();
      await h.transfers.debugSourcesCopied;

      recorder.clear();
      transport.holdParts = false;
      await h.kill();
      h.transfers.registerPublisher(publisherId, FakePublisher());
      await _settled(h);

      final reloaded = h.transfers.publishJob(job.id)!;
      expect(
        reloaded.snapshot.item('a')!.state,
        const PublishItemState.failed(
          stage: PublishStage.upload,
          reason: PublishFailureReason('sourceLost'),
          retryable: false,
        ),
      );
      expect(recorder.whereOp(JournalOp.sourceLost), hasLength(1));

      recorder.clear();
      expect(
        reloaded.retryItem('a', source: SourceBytes.memory(Uint8List(9))),
        isTrue,
      );
      await _settled(h);
      expect(reloaded.snapshot.state, const PublishJobState.completed(null));
      expect(transport.finishes.last.finalSize, 9);
      expect(transport.opens.last.resumeToken, isNull);
      expect(
        recorder.whereOp(JournalOp.sourceCopied).single.fields['bytes'],
        9,
      );
    });

    test(
      'an item with nothing the page holds fails with its source lost',
      () async {
        final transport = fakeTransport();
        final h = await web(transport);
        final job = h.transfers.publish(
          requestOf([
            itemOf('a', PublishSource.prepared(_mediaAt('blob:gone', 5))),
          ]),
        );
        await _settled(h);
        expect(
          job.snapshot.item('a')!.state,
          const PublishItemState.failed(
            stage: PublishStage.upload,
            reason: PublishFailureReason('sourceLost'),
            retryable: true,
          ),
        );
        expect(transport.opens, isEmpty);
        expect(
          recorder.whereOp(TransportOp.partGaveUp).single.fields['code'],
          'source_lost',
        );
      },
    );
  });
}
