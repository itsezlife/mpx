import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

/// Longer than the tests' progress window, so the window before it has
/// been written.
const Duration _pastWindow = Duration(milliseconds: 80);

const Duration _window = Duration(milliseconds: 20);

void main() {
  test('a kill while preparing starts the preparation over, and the job '
      'publishes once with its key', () async {
    final preparation = FakeMediaPreparation();
    final h = await publishing([fakeTransport()], preparation: preparation);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'a',
          PublishSource.prepare(inputOf(10), const PreparationIntent.video()),
        ),
      ]),
    );
    await pumpEventQueue();
    preparation.last.report(0.4);
    await h.settle();
    await h.kill();
    await pumpEventQueue();
    expect(preparation.handles, hasLength(2), reason: 'prepared again');
    expect(preparation.handles.first.isCancelled, isTrue);

    final publisher = FakePublisher();
    h.transfers.registerPublisher(publisherId, publisher);
    preparation.last.complete();
    await pumpEventQueue();
    expect(publisher.calls, hasLength(1));
    expect(
      h.transfers.publishJob(job.id)!.snapshot.state,
      const PublishJobState.completed(null),
    );
  });

  test('a kill mid upload redoes no finished preparation and resends no '
      'journaled part', () async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 10,
      holdParts: true,
    );
    final preparation = FakeMediaPreparation(onPrepare: (h) => h.complete());
    final h = await publishing(
      [transport],
      preparation: preparation,
      progressInterval: _window,
    );
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'a',
          PublishSource.prepare(inputOf(500), const PreparationIntent.photo()),
        ),
      ]),
    );
    await pumpEventQueue();
    for (final index in [0, 1, 2]) {
      transport.ack(index);
      await pumpEventQueue();
    }
    await Future<void>.delayed(_pastWindow);
    await h.settle();
    final sentBefore = transport.sent.length;
    transport.holdParts = false;
    await h.kill();
    await pumpEventQueue();

    expect(preparation.handles, hasLength(1), reason: 'not prepared again');
    final resent = transport.sent.skip(sentBefore).map((part) => part.index);
    expect(resent, isNot(contains(anyOf(0, 1, 2))));
    expect(transport.opens.last.resumeToken, isNotNull);

    final publisher = FakePublisher();
    h.transfers.registerPublisher(publisherId, publisher);
    await pumpEventQueue();
    expect(publisher.calls, hasLength(1));
    expect(transport.finishes, hasLength(1));
    expect(
      h.transfers.publishJob(job.id)!.snapshot.state,
      const PublishJobState.completed(null),
    );
  });

  test('a kill while the publisher is called calls it again after the '
      'restart with the same engine key', () async {
    final h = await publishing([fakeTransport()]);
    final first = FakePublisher(hold: true);
    h.transfers.registerPublisher(publisherId, first);
    final job = h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
    );
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.publishing());
    await h.settle();
    await h.kill();

    final second = FakePublisher();
    h.transfers.registerPublisher(publisherId, second);
    await pumpEventQueue();
    expect(second.calls, hasLength(1));
    expect(
      second.calls.single.idempotencyKey,
      first.calls.single.idempotencyKey,
    );
    expect(h.transfers.debugSnapshot().publish!.jobs, isEmpty);
    expect(
      h.transfers.publishJob(job.id)!.snapshot.state,
      const PublishJobState.completed(null),
    );
  });

  test(
    "the request's idempotency key is the one every attempt carries",
    () async {
      final h = await publishing([]);
      final first = FakePublisher(hold: true);
      h.transfers.registerPublisher(publisherId, first);
      h.transfers.publish(requestOf(const [], idempotencyKey: 'client-1'));
      await pumpEventQueue();
      await h.settle();
      await h.kill();
      final second = FakePublisher();
      h.transfers.registerPublisher(publisherId, second);
      await pumpEventQueue();
      expect(first.calls.single.idempotencyKey, 'client-1');
      expect(second.calls.single.idempotencyKey, 'client-1');
    },
  );

  test('a kill at each job state boundary comes back in that state and '
      'publishes once', () async {
    final transport = fakeTransport(holdParts: true);
    final preparation = FakeMediaPreparation();
    final h = await publishing([transport], preparation: preparation);
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'a',
          PublishSource.prepare(inputOf(10), const PreparationIntent.photo()),
        ),
      ]),
    );
    Future<PublishJobState> killed() async {
      await h.settle();
      await h.kill();
      await pumpEventQueue();
      return h.transfers.publishJob(job.id)!.snapshot.state;
    }

    await pumpEventQueue();
    expect(await killed(), const PublishJobState.preparing());

    preparation.last.complete();
    await pumpEventQueue();
    expect(await killed(), const PublishJobState.uploading());

    transport.holdParts = false;
    transport.ack(0);
    await pumpEventQueue();
    expect(await killed(), const PublishJobState.awaitingPublisher());

    final publisher = FakePublisher(hold: true);
    h.transfers.registerPublisher(publisherId, publisher);
    await pumpEventQueue();
    expect(await killed(), const PublishJobState.awaitingPublisher());
    final keys = {publisher.calls.single.idempotencyKey};

    final last = FakePublisher();
    h.transfers.registerPublisher(publisherId, last);
    await pumpEventQueue();
    keys.add(last.calls.single.idempotencyKey);
    expect(await killed(), const PublishJobState.completed(null));
    expect(keys, hasLength(1));
    expect(
      preparation.handles,
      hasLength(2),
      reason:
          'once killed while '
          'preparing, never after',
    );
    expect(transport.finishes, hasLength(1));
  });

  test('uploads the journal lost are queued again under the ids their item '
      'names, thumbnails included', () async {
    final transport = FakeUploadTransport(
      holdParts: true,
      capabilities: const UploadCapabilities(
        partSize: _partSize,
        bytesInFlight: 4 * part,
        resume: UploadResume.unlimited(),
        thumbnail: UploadThumbnail.separate,
        reuse: UploadReuse.lifetime(Duration(hours: 24)),
      ),
    );
    // Every start opens an empty transfer journal: as if the uploads'
    // records never reached storage while their item's did.
    final h = await publishing([transport], store: MemoryJournalStore.new);
    final publisher = FakePublisher();
    final job = h.transfers.publish(
      requestOf([
        itemOf(
          'v',
          PublishSource.prepared(
            preparedOf(30, kind: PreparedKind.video, thumbnail: true),
          ),
        ),
      ]),
    );
    await pumpEventQueue();
    final ids = {
      for (final upload in await h.transfers.watch().first) upload.id,
    };
    expect(ids, hasLength(2));
    await h.settle();
    transport.holdParts = false;
    await h.kill();
    h.transfers.registerPublisher(publisherId, publisher);
    await pumpEventQueue();
    expect({
      for (final upload in await h.transfers.watch().first) upload.id,
    }, ids);
    expect(publisher.calls.single.items['v']!.thumbnail, isNotNull);
    expect(
      h.transfers.publishJob(job.id)!.snapshot.state,
      const PublishJobState.completed(null),
    );
  });
}

int _partSize(int size) => part;
