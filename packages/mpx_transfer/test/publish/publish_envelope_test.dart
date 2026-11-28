import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../upload/upload_support.dart';
import 'publish_support.dart';

void main() {
  late ManualPlaybackLifecycleSource lifecycle;
  late FakeTransferEnvelope envelope;
  late UploadsHarness h;

  Future<void> open({
    TransferEnvelopeStartRule rule = TransferEnvelopeStartRule.always,
  }) async {
    lifecycle = ManualPlaybackLifecycleSource(
      initial: AppLifecycleState.resumed,
    );
    envelope = FakeTransferEnvelope(startRule: rule);
    addTearDown(envelope.close);
    h = await publishing(
      [fakeTransport(holdParts: true)],
      lifecycle: lifecycle,
      envelope: envelope,
      envelopeConfig: FakeTransferEnvelope.config,
    );
    h.transfers.registerPublisher(publisherId, FakePublisher());
  }

  Future<List<PublishJobSnapshot>> jobs() => h.transfers.watchJobs().first;

  test(
    'a publish job uploads system by default, inside the envelope',
    () async {
      await open();
      h.transfers.publish(
        requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();
      final upload = (await h.transfers.watch().first).single;
      expect(upload.durability, TransferDurability.system);
      expect(envelope.current!.jobs, {upload.id});
    },
  );

  test(
    'long rule: a video starts the envelope, a small photo does not',
    () async {
      await open(rule: TransferEnvelopeStartRule.long);
      h.transfers.publish(
        requestOf([itemOf('p', PublishSource.prepared(preparedOf(10)))]),
      );
      await pumpEventQueue();
      expect(envelope.starts, isEmpty);
      h.transfers.publish(
        requestOf([
          itemOf(
            'v',
            PublishSource.prepared(preparedOf(10, kind: PreparedKind.video)),
          ),
        ]),
      );
      await pumpEventQueue();
      expect(envelope.starts, hasLength(1));
      expect(envelope.current!.jobs, hasLength(2), reason: 'the photo joins');
    },
  );

  test('ended by the system, the owner sees the job paused and it resumes '
      'in the foreground', () async {
    await open();
    final job = h.transfers.publish(
      requestOf([itemOf('a', PublishSource.prepared(preparedOf(10)))]),
    );
    await pumpEventQueue();
    lifecycle.emit(AppLifecycleState.hidden);
    envelope.emit(const TransferEnvelopeEvent.systemEnded());
    await pumpEventQueue();
    expect(
      (await jobs()).single.state,
      const PublishJobState.paused(PauseReason.systemInterrupted),
    );
    lifecycle.emit(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(job.snapshot.state, const PublishJobState.uploading());
  });

  test('cancel all removes the publish jobs in the envelope', () async {
    await open();
    final job = h.transfers.publish(
      requestOf([
        itemOf('a', PublishSource.prepared(preparedOf(10))),
        itemOf('b', PublishSource.prepared(preparedOf(10))),
      ], tag: 'chat:1:m'),
    );
    await pumpEventQueue();
    final lists = <List<PublishJobId>>[];
    h.transfers.watchJobs().listen(
      (jobs) => lists.add([for (final job in jobs) job.id]),
    );
    var ended = false;
    job.watch().listen((_) {}, onDone: () => ended = true);
    await pumpEventQueue();
    expect(lists.last, [job.id]);

    envelope.emit(const TransferEnvelopeEvent.userCancelledAll());
    await pumpEventQueue();

    expect(lists.last, isEmpty);
    expect(ended, isTrue);
    expect(h.transfers.publishJob(job.id), isNull);
    expect(await h.transfers.watch().first, isEmpty);

    await h.settle();
    await h.kill();
    expect(h.transfers.publishJob(job.id), isNull, reason: 'gone after a kill');
  });
}
