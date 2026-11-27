import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

void main() {
  test(
    'a photo, a video and a file walk their states and publish once',
    () async {
      final transport = fakeTransport();
      final preparation = FakeMediaPreparation();
      final publisher = FakePublisher();
      final h = await publishing([transport], preparation: preparation);
      h.transfers.registerPublisher(publisherId, publisher);
      final file = preparedOf(30);
      late PublishJob job;
      final items = <String, List<String>>{};

      final states = await statesDuring(
        job = h.transfers.publish(
          requestOf([
            itemOf(
              'photo',
              PublishSource.prepare(
                inputOf(500),
                const PreparationIntent.photo(),
              ),
            ),
            itemOf(
              'video',
              PublishSource.prepare(
                inputOf(900),
                const PreparationIntent.video(),
              ),
            ),
            itemOf('file', PublishSource.prepared(file)),
          ]),
        ),
        () async {
          for (final id in ['photo', 'video', 'file']) {
            job.watchItem(id).listen((item) {
              final list = items.putIfAbsent(id, () => []);
              if (list.lastOrNull != item.state.name) list.add(item.state.name);
            });
          }
          await pumpEventQueue();
          expect(preparation.handles, hasLength(2));
          preparation.handles[0].report(0.5);
          await pumpEventQueue();
          expect(
            job.snapshot.item('photo')!.state,
            const PublishItemState.preparing(0.5),
          );
          expect(job.snapshot.state, const PublishJobState.preparing());
          for (final handle in preparation.handles) {
            handle.complete();
          }
          await pumpEventQueue();
        },
      );

      expect(states, ['preparing', 'uploading', 'publishing', 'completed']);
      expect(job.snapshot.state, const PublishJobState.completed(null));
      expect(items['photo'], ['preparing', 'uploading', 'uploaded']);
      expect(items['video'], ['preparing', 'uploading', 'uploaded']);
      expect(items['file']!.last, 'uploaded');
      expect(publisher.calls, hasLength(1));
      final call = publisher.calls.single;
      expect(call.payload, [1, 2, 3]);
      expect(call.items.keys, ['photo', 'video', 'file']);
      for (final refs in call.items.values) {
        expect(refs.file, isNotNull);
        expect(refs.isRemote, isFalse);
      }
      expect(transport.finishes, hasLength(3));
      expect([for (final open in transport.opens) open.info.size]..sort(), [
        30,
        preparedSize,
        preparedSize,
      ]);
    },
  );

  test('a video uploads in the big lane, a photo in the small one', () async {
    final transport = fakeTransport();
    final h = await publishing([transport]);
    h.transfers.registerPublisher(publisherId, FakePublisher());
    h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepared(preparedOf(10, kind: PreparedKind.video)),
        ),
        itemOf('p', PublishSource.prepared(preparedOf(10))),
      ]),
    );
    await pumpEventQueue();
    final lanes = [
      for (final job in await h.transfers.watch().first)
        h.uploadOf(job.id)!.lane,
    ];
    expect(lanes, unorderedEquals([UploadLane.big, UploadLane.small]));
  });

  test('the uploads of a job are transfer jobs with its tag, its durability '
      'and each item key', () async {
    final h = await publishing([fakeTransport()]);
    h.transfers.publish(
      requestOf([
        itemOf('a', PublishSource.prepared(preparedOf(10))),
      ], tag: 'chat:1:m'),
    );
    await pumpEventQueue();
    final uploads = await h.transfers.watch().first;
    expect(uploads.single.tag, 'chat:1:m');
    expect(uploads.single.durability, TransferDurability.system);
    expect(uploads.single.key, keyOf('a'));
  });

  test('a job with no items publishes at once', () async {
    final publisher = FakePublisher();
    final h = await publishing([]);
    h.transfers.registerPublisher(publisherId, publisher);
    final job = h.transfers.publish(requestOf(const []));
    await pumpEventQueue();
    expect(publisher.calls.single.items, isEmpty);
    expect(job.snapshot.state, const PublishJobState.completed(null));
    expect(job.snapshot.items, isEmpty);
  });

  test('the publisher result completes the job', () async {
    final publisher = FakePublisher()
      ..answerWith(PublishOutcome.published(result: Uint8List.fromList([9])));
    final h = await publishing([]);
    h.transfers.registerPublisher(publisherId, publisher);
    final job = h.transfers.publish(requestOf(const []));
    await pumpEventQueue();
    expect(
      job.snapshot.state,
      PublishJobState.completed(Uint8List.fromList([9])),
    );
  });

  test('a remote item neither prepares nor uploads', () async {
    final transport = fakeTransport();
    final preparation = FakeMediaPreparation();
    final publisher = FakePublisher();
    final h = await publishing([transport], preparation: preparation);
    h.transfers.registerPublisher(publisherId, publisher);
    final job = h.transfers.publish(
      requestOf([itemOf('r', const PublishSource.remote())]),
    );
    await pumpEventQueue();
    expect(preparation.handles, isEmpty);
    expect(transport.opens, isEmpty);
    expect(job.snapshot.item('r')!.state, const PublishItemState.uploaded());
    final refs = publisher.calls.single.items['r']!;
    expect(refs.isRemote, isTrue);
    expect(refs.key, keyOf('r'));
  });

  test('a reuse hit neither prepares nor uploads, and carries the stored '
      'references', () async {
    final transport = fakeTransport();
    final preparation = FakeMediaPreparation(
      onPrepare: (handle) => handle.complete(),
    );
    final publisher = FakePublisher();
    final h = await publishing([transport], preparation: preparation);
    h.transfers.registerPublisher(publisherId, publisher);
    final input = inputOf(500);
    PublishItem item() => itemOf(
      'x',
      PublishSource.prepare(input, const PreparationIntent.photo()),
      fingerprint: 'asset-1@2026',
    );

    h.transfers.publish(requestOf([item()]));
    await pumpEventQueue();
    expect(preparation.handles, hasLength(1));
    expect(transport.opens, hasLength(1));

    final again = h.transfers.publish(requestOf([item()]));
    await pumpEventQueue();
    expect(preparation.handles, hasLength(1), reason: 'not prepared again');
    expect(transport.opens, hasLength(1), reason: 'not uploaded again');
    expect(again.snapshot.state, const PublishJobState.completed(null));
    expect(
      publisher.calls[1].items['x']!.file,
      publisher.calls[0].items['x']!.file,
    );
  });

  test('without a fingerprint the file path, size and time are the reuse '
      'key, so a changed file uploads again', () async {
    final transport = fakeTransport();
    final h = await publishing([transport]);
    h.transfers.registerPublisher(publisherId, FakePublisher());
    final media = preparedOf(10);
    h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(media))]),
    );
    await pumpEventQueue();
    h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(media))]),
    );
    await pumpEventQueue();
    expect(transport.opens, hasLength(1));

    sourceFiles.touch(media.path);
    h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(media))]),
    );
    await pumpEventQueue();
    expect(transport.opens, hasLength(2));
  });

  test('a facade without preparation refuses an item that needs it, and '
      'takes prepared and remote items', () async {
    final recorder = RecordingDiagnostics.install();
    final h = await publishing([fakeTransport()]);
    expect(
      () => h.transfers.publish(
        requestOf([
          itemOf('p', PublishSource.prepared(preparedOf(10))),
          itemOf(
            'n',
            PublishSource.prepare(inputOf(10), const PreparationIntent.file()),
          ),
        ]),
      ),
      throwsA(
        isA<PreparationUnavailable>().having((e) => e.itemId, 'itemId', 'n'),
      ),
    );
    expect(recorder.whereOp(PublishPreparationOp.refusedNoSeam), [
      isMpxEvent(
        level: MpxEventLevel.error,
        itemId: 'n',
        category: 'preparation',
      ),
    ]);
    expect(await h.transfers.watch().first, isEmpty, reason: 'no job made');

    final job = h.transfers.publish(
      requestOf([
        itemOf('p', PublishSource.prepared(preparedOf(10))),
        itemOf('r', const PublishSource.remote()),
      ]),
    );
    expect(job.snapshot.items, hasLength(2));
  });

  test('a transport that takes thumbnails separately gets two uploads per '
      'media item', () async {
    final transport = FakeUploadTransport(
      capabilities: const UploadCapabilities(
        partSize: _partSize,
        bytesInFlight: 4 * part,
        resume: UploadResume.unlimited(),
        thumbnail: UploadThumbnail.separate,
        reuse: UploadReuse.lifetime(Duration(hours: 24)),
      ),
    );
    final publisher = FakePublisher();
    final h = await publishing([
      transport,
    ], preparation: FakeMediaPreparation(onPrepare: (h) => h.complete()));
    h.transfers.registerPublisher(publisherId, publisher);
    h.transfers.publish(
      requestOf([
        itemOf(
          'photo',
          PublishSource.prepare(inputOf(50), const PreparationIntent.photo()),
        ),
        itemOf(
          'video',
          PublishSource.prepared(
            preparedOf(40, kind: PreparedKind.video, thumbnail: true),
          ),
        ),
      ]),
    );
    await pumpEventQueue();
    expect(transport.opens, hasLength(4));
    expect([for (final open in transport.opens) open.info.size]..sort(), [
      thumbnailSize,
      thumbnailSize,
      40,
      preparedSize,
    ]);
    for (final refs in publisher.calls.single.items.values) {
      expect(refs.thumbnail, isNotNull);
      expect(refs.thumbnail, isNot(refs.file));
    }
  });

  test('a job whose publisher is not registered waits, across a restart, '
      'until the host registers it', () async {
    final h = await publishing([fakeTransport()]);
    final job = h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
    );
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.awaitingPublisher());
    expect(h.transfers.debugSnapshot().publish!.awaitingPublisher, [job.id]);

    await h.settle();
    await h.restart();
    await pumpEventQueue();
    final back = h.transfers.publishJob(job.id)!;
    expect(back.snapshot.state, const PublishJobState.awaitingPublisher());

    final publisher = FakePublisher();
    h.transfers.registerPublisher(publisherId, publisher);
    await pumpEventQueue();
    expect(publisher.calls, hasLength(1));
    expect(back.snapshot.state, const PublishJobState.completed(null));
  });

  test('transfers.upload completes at uploaded with its RemoteRef and calls '
      'no publisher', () async {
    final transport = fakeTransport();
    final publisher = FakePublisher();
    final h = await publishing([transport]);
    h.transfers.registerPublisher(publisherId, publisher);
    final job = h.transfers.upload(
      itemOf('u', PublishSource.prepared(preparedOf(10))),
      tag: 'avatar',
    );
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.completed(null));
    expect(job.snapshot.publisher, isNull);
    expect(
      job.snapshot.item('u')!.state,
      PublishItemState.uploaded(file: RemoteRef('fake-1')),
    );
    expect(publisher.calls, isEmpty);
  });

  test('a failed upload fails the job at the upload stage', () async {
    final transport = fakeTransport()
      ..failOpen(error: const UploadTransportException('refused', status: 403));
    final h = await publishing([transport]);
    h.transfers.registerPublisher(publisherId, FakePublisher());
    final job = h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
    );
    await pumpEventQueue();
    expect(
      job.snapshot.state,
      const PublishJobState.failed(
        stage: PublishStage.upload,
        reason: 'server',
        retryable: false,
      ),
    );
  });

  test('a failed preparation fails the job at the prepare stage', () async {
    final h = await publishing([
      fakeTransport(),
    ], preparation: FakeMediaPreparation(onPrepare: (h) => h.fail('noSpace')));
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'a',
          PublishSource.prepare(inputOf(10), const PreparationIntent.photo()),
        ),
      ]),
    );
    await pumpEventQueue();
    expect(
      job.snapshot.state,
      const PublishJobState.failed(
        stage: PublishStage.prepare,
        reason: 'noSpace',
        retryable: true,
      ),
    );
  });

  test('a paused upload pauses the job with its reason', () async {
    final transport = fakeTransport(holdParts: true);
    final h = await publishing([transport]);
    final job = h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
    );
    await pumpEventQueue();
    final upload = (await h.transfers.watch().first).single.id;
    h.transfers.pause(upload);
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.paused(PauseReason.user));
    h.transfers.resume(upload);
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.uploading());
  });

  test('a repeated item id and an unknown transport are refused', () async {
    final h = await publishing([fakeTransport()]);
    final item = itemOf('a', PublishSource.prepared(preparedOf(10)));
    expect(
      () => h.transfers.publish(requestOf([item, item])),
      throwsArgumentError,
    );
    expect(
      () => h.transfers.publish(
        PublishRequest(
          items: [item],
          payload: Uint8List(0),
          publisher: publisherId,
          transport: 'nope',
        ),
      ),
      throwsArgumentError,
    );
  });

  test('a failed upload whose source was lost retries with a source the '
      'host gives again, from zero', () async {
    final transport = fakeTransport(partSize: 10, bytesInFlight: 10);
    final h = await uploads([transport]);
    final source = sourceOf(30);
    sourceFiles.delete(source.path);
    final id = h.upload(source);
    await pumpEventQueue();
    expect(
      await stateOf(h.transfers, id),
      isA<TransferState$Failed>().having(
        (s) => s.kind,
        'kind',
        TransferFailureKind.sourceLost,
      ),
    );

    sourceFiles.put('/uploads/again.bin', size: 20);
    expect(
      h.transfers.retry(
        id,
        source: const UploadSource$Finished('/uploads/again.bin', size: 20),
      ),
      isTrue,
    );
    await pumpEventQueue();
    expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    expect(h.uploadOf(id)!.source.path, '/uploads/again.bin');
    expect(transport.finishes.single.finalSize, 20);
  });

  test(
    'debugSnapshot lists jobs, items with reuse hits and publishers',
    () async {
      final h = await publishing([fakeTransport()]);
      h.transfers.registerPublisher('other', FakePublisher());
      final job = h.transfers.publish(
        requestOf([
          itemOf('a', PublishSource.prepared(preparedOf(10))),
          itemOf('r', const PublishSource.remote()),
        ]),
      );
      await pumpEventQueue();
      final section = h.transfers.debugSnapshot().publish!;
      expect(section.publishers, ['other']);
      expect(section.jobs.single.id, job.id);
      expect(section.jobs.single.items.map((i) => i.item.itemId), ['a', 'r']);
      expect(section.jobs.single.items.every((i) => !i.reuseHit), isTrue);
      expect(section.awaitingOwner, isEmpty);
    },
  );
}

int _partSize(int size) => part;
