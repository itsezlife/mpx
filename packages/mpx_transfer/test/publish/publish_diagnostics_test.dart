import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

void main() {
  late RecordingDiagnostics recorder;

  setUp(() => recorder = RecordingDiagnostics.install());

  test('a job reports its creation, each item stage, the wait for its '
      'publisher, the registration, the attempt and the outcome', () async {
    final h = await publishing([fakeTransport()]);
    final job = h.transfers.publish(
      requestOf([
        itemOf('a', PublishSource.prepared(preparedOf(10))),
        itemOf('r', const PublishSource.remote()),
      ], tag: 'chat:1:m'),
    );
    await pumpEventQueue();
    h.transfers.registerPublisher(
      publisherId,
      FakePublisher()..answerWith(
        PublishOutcome.published(serverKeys: const {'a': MediaKey.remote('s')}),
      ),
    );
    await pumpEventQueue();

    expect(recorder.whereCategory('publish'), [
      isMpxEvent(
        level: MpxEventLevel.info,
        op: PublishOp.jobCreated,
        jobId: job.id,
        tag: 'chat:1:m',
        fields: {
          'items': 2,
          'publisher': publisherId,
          'durability': 'system',
          'failurePolicy': 'wholeJob',
          'hold': false,
          'group': false,
          'idempotency': 'engine',
        },
      ),
      isMpxEvent(
        level: MpxEventLevel.debug,
        op: PublishOp.remoteItem,
        jobId: job.id,
        itemId: 'r',
        mediaKey: keyOf('r'),
      ),
      isMpxEvent(
        level: MpxEventLevel.debug,
        op: PublishOp.itemStage,
        itemId: 'r',
        fields: {'from': 'waiting', 'to': 'uploaded'},
      ),
      isMpxEvent(
        op: PublishOp.itemStage,
        jobId: job.id,
        itemId: 'a',
        mediaKey: keyOf('a'),
        fields: {'from': 'waiting', 'to': 'uploading'},
      ),
      isMpxEvent(
        op: PublishOp.itemStage,
        itemId: 'a',
        fields: {'from': 'uploading', 'to': 'uploaded'},
      ),
      isMpxEvent(
        level: MpxEventLevel.warning,
        op: PublishOp.awaitingPublisher,
        jobId: job.id,
        tag: 'chat:1:m',
        fields: {'publisher': publisherId},
      ),
      isMpxEvent(
        level: MpxEventLevel.info,
        op: PublishOp.publisherRegistered,
        fields: {'publisher': publisherId, 'jobsWaiting': 1},
      ),
      isMpxEvent(
        level: MpxEventLevel.info,
        op: PublishOp.attempt,
        jobId: job.id,
        tag: 'chat:1:m',
        fields: {'attempt': 1, 'stage': 'publish'},
      ),
      isMpxEvent(
        level: MpxEventLevel.info,
        op: PublishOp.outcome,
        jobId: job.id,
        fields: {'outcome': 'published', 'retryable': false, 'serverKeys': 1},
      ),
    ]);
  });

  test("the request's key is reported as such, never its value", () async {
    final h = await publishing([]);
    h.transfers.publish(requestOf(const [], idempotencyKey: 'secret-key'));
    await pumpEventQueue();
    expect(
      recorder.whereOp(PublishOp.jobCreated).single.fields['idempotency'],
      'request',
    );
    _expectNoContent(recorder, ['secret-key']);
  });

  test('a separate thumbnail upload is reported with its size', () async {
    final transport = FakeUploadTransport(
      capabilities: const UploadCapabilities(
        partSize: _partSize,
        bytesInFlight: 4 * part,
        thumbnail: UploadThumbnail.separate,
        reuse: UploadReuse.lifetime(Duration(hours: 1)),
      ),
    );
    final h = await publishing([transport]);
    h.transfers.publish(
      requestOf([
        itemOf('t', PublishSource.prepared(preparedOf(30, thumbnail: true))),
      ]),
    );
    await pumpEventQueue();
    final thumbnail = [
      for (final upload in await h.transfers.watch().first)
        if (h.uploadOf(upload.id)!.source.size == thumbnailSize) upload.id,
    ].single;
    expect(recorder.whereOp(TransportOp.thumbnailUpload), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        jobId: thumbnail,
        itemId: 't',
        fields: {'bytes': thumbnailSize},
      ),
    ]);
  });

  test('a failed item is an error with its stage and reason', () async {
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
    expect(recorder.errors, [
      isMpxEvent(
        op: PublishOp.itemStage,
        jobId: job.id,
        itemId: 'a',
        fields: {
          'from': 'preparing',
          'to': 'failed',
          'stage': 'prepare',
          'reason': 'noSpace',
        },
      ),
    ]);
  });

  test('a publisher that throws is an error outcome and fails the job at '
      'publish', () async {
    final h = await publishing([]);
    h.transfers.registerPublisher(
      publisherId,
      FakePublisher()..throwOnNext(StateError('payload 1,2,3')),
    );
    final job = h.transfers.publish(requestOf(const []));
    await pumpEventQueue();
    expect(recorder.errors, [
      isMpxEvent(
        op: PublishOp.outcome,
        jobId: job.id,
        fields: {'outcome': 'error', 'retryable': true, 'serverKeys': 0},
      ),
    ]);
    expect(recorder.errors.single.error, isNull);
    expect(
      job.snapshot.state,
      const PublishJobState.failed(
        stage: PublishStage.publish,
        reason: 'publisherError',
        retryable: true,
      ),
    );
  });

  test('no event carries a path, the payload or the key', () async {
    final h = await publishing([
      fakeTransport(),
    ], preparation: FakeMediaPreparation(onPrepare: (h) => h.complete()));
    h.transfers.registerPublisher(publisherId, FakePublisher());
    final input = inputOf(40);
    h.transfers.publish(
      requestOf(
        [
          itemOf(
            'p',
            PublishSource.prepare(input, const PreparationIntent.photo()),
          ),
        ],
        idempotencyKey: 'key-xyz',
        payload: const [77, 88],
      ),
    );
    await pumpEventQueue();
    expect(recorder.whereOp(PublishOp.outcome), hasLength(1));
    _expectNoContent(recorder, [input.path, 'key-xyz', '/inputs/']);
  });
}

void _expectNoContent(RecordingDiagnostics recorder, List<String> needles) {
  for (final event in recorder.events) {
    final text = '${event.fields}';
    for (final needle in needles) {
      expect(
        text.contains(needle),
        isFalse,
        reason: '${event.category}.${event.op.name} carries "$needle"',
      );
    }
  }
}

int _partSize(int size) => part;
