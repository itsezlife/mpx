import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show BytesCacheKey;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

import '../support.dart' show photo;
import '../upload/upload_support.dart';
import 'publish_support.dart';
import 'tracked_support.dart';

void main() {
  TrackedTransfersContract.run(() async {
    final h = await TrackedHarness.open();
    final source = keyOf('contract');
    return TrackedTransfersHarness(
      transfers: h.tracked,
      content: photo,
      advance: h.step,
      interrupt: (key) async {
        if (key == source) {
          h.transfers.debugSimulateSystemInterruption();
        } else {
          h.transfers.connectivityChanged(online: false);
          h.fetcher
            ..online = false
            ..failAll();
        }
        await pumpEventQueue();
      },
      resumeInterrupted: (key) async {
        h.fetcher.online = true;
        h.transfers.connectivityChanged(online: true);
        await pumpEventQueue();
      },
      uploadSource: source,
      startUpload: () => h.publish(['contract']),
      publish: h.answer,
    );
  });

  late RecordingDiagnostics recorder;
  late TrackedHarness h;

  setUp(() async {
    recorder = RecordingDiagnostics.install();
    h = await TrackedHarness.open();
  });

  test('a bound key walks waiting, sending, sent, then none once the alias '
      'applies, its local picture kept', () async {
    final key = keyOf('w1');
    final seen = h.record(key);

    final job = await h.publish(['w1']);
    await h.stepUntil(() => h.valueOf(key) == AssetTransfer.sent);
    expect(job.snapshot.state, const PublishJobState.publishing());

    expect(seen.first, AssetTransfer.none);
    expect(seen[1], isA<AssetTransfer$Waiting>());
    expect(seen.last, AssetTransfer.sent);
    final sending = seen.sublist(2, seen.length - 1);
    expect(sending, isNotEmpty);
    expect(sending, everyElement(isA<AssetTransfer$Sending>()));
    final sent = [
      for (final value in sending) (value as AssetTransfer$Sending).sent,
    ];
    expect(sent, orderedEquals([...sent]..sort()));
    expect((sending.last as AssetTransfer$Sending).total, 3 * part);

    await h.answer();

    expect(job.snapshot.aliasesApplied, isTrue);
    expect(seen.last, AssetTransfer.none);
    expect(
      h.store.store.contains(BytesCacheKey(key.encoded)),
      isTrue,
      reason: 'the local picture stays',
    );
    expect(
      await h.store.store.read(BytesCacheKey(serverKeyOf('w1').encoded)),
      Uint8List.fromList(const [1, 2, 3]),
    );
  });

  test('an upload on its own reads sent at once into none: it has no '
      'publish to wait for', () async {
    final key = keyOf('solo');
    final seen = h.record(key);
    h.transport.holdParts = false;

    h.transfers.upload(
      itemOf('solo', PublishSource.prepared(preparedOf(2 * part))),
    );
    await pumpEventQueue();
    await h.uploads.settle();
    await pumpEventQueue();

    expect(seen.last, AssetTransfer.none);
    expect(seen.whereType<AssetTransfer$Sending>(), isNotEmpty);
  });

  test('a system pause holds the ring where it was, and cancel still '
      'works', () async {
    final key = keyOf('p1');
    final job = await h.publish(['p1']);
    await h.step();
    await h.step();
    final held = h.valueOf(key);
    expect(held, isA<AssetTransfer$Sending>());

    expect(h.transfers.debugSimulateSystemInterruption(), greaterThan(0));
    await pumpEventQueue();
    expect(
      job.snapshot.state,
      const PublishJobState.paused(PauseReason.systemInterrupted),
    );
    expect(h.valueOf(key), held);
    await h.step();
    expect(h.valueOf(key), held);

    h.tracked.cancel(key);
    await pumpEventQueue();
    expect(h.valueOf(key), AssetTransfer.none);
    expect(job.snapshot.items, isEmpty);
  });

  test('a user pause reads awaitingUser; download resumes the upload, not '
      'a download', () async {
    final key = keyOf('u1');
    await h.publish(['u1']);
    await h.step();
    final upload = (await h.transfers.watch().first).firstWhere(
      (job) => job.key == key,
    );

    h.transfers.pause(upload.id);
    await pumpEventQueue();
    expect(h.valueOf(key), isA<AssetTransfer$AwaitingUser>());

    h.tracked.download(key);
    await pumpEventQueue();
    await h.step();
    expect(h.valueOf(key), isA<AssetTransfer$Sending>());
    expect(
      (await h.transfers.watch().first).where(
        (job) => job.direction == TransferDirection.download,
      ),
      isEmpty,
    );
  });

  test('a failed upload reads failed; download retries the item', () async {
    final key = keyOf('f1');
    h.transport.failOpen(
      error: const UploadTransportException('refused', status: 403),
    );
    final job = await h.publish(['f1']);
    await pumpEventQueue();
    expect(
      h.valueOf(key),
      isA<AssetTransfer$Failed>().having(
        (failed) => failed.kind,
        'kind',
        AssetFailureKind.permanent,
      ),
    );
    expect(job.snapshot.state, isA<PublishJobState$Failed>());

    h.tracked.download(key);
    await pumpEventQueue();
    await h.stepUntil(() => h.valueOf(key) == AssetTransfer.sent);
  });

  group('cancel from the cell', () {
    test('drops that item, which the owner sees in watchJobs, and the rest '
        'publish', () async {
      final job = await h.publish(['a', 'b']);
      final listed = <List<PublishJobSnapshot>>[];
      final watching = h.transfers
          .watchJobs(const PublishJobFilter(tagPrefix: 'chat:1:'))
          .listen(listed.add);
      addTearDown(watching.cancel);
      await h.step();
      expect(h.valueOf(keyOf('a')), isA<AssetTransfer$Sending>());

      h.tracked.cancel(keyOf('a'));
      // A burst of taps: the item went with the first.
      h.tracked.cancel(keyOf('a'));
      await pumpEventQueue();

      expect(h.valueOf(keyOf('a')), AssetTransfer.none);
      expect(listed.last.single.items.map((item) => item.itemId), ['b']);
      expect(
        (await h.transfers.watch().first).where((j) => j.key == keyOf('a')),
        isEmpty,
      );
      expect(recorder.whereOp(PublishOp.itemRemoved), [
        isMpxEvent(
          jobId: job.id,
          itemId: 'a',
          mediaKey: keyOf('a'),
          tag: 'chat:1:m1',
          fields: {'by': 'cell'},
        ),
      ]);

      await h.stepUntil(() => h.valueOf(keyOf('b')) == AssetTransfer.sent);
      await h.answer();
      expect(h.publisher.calls.single.items.keys, ['b']);
      expect(h.valueOf(keyOf('b')), AssetTransfer.none);
    });

    test('of the last item leaves the job awaiting its owner', () async {
      final job = await h.publish(['only']);
      await h.step();

      h.tracked.cancel(keyOf('only'));
      await pumpEventQueue();

      final listed = await h.transfers
          .watchJobs(const PublishJobFilter(tagPrefix: 'chat:1:'))
          .first;
      expect(listed.single.id, job.id);
      expect(listed.single.state, const PublishJobState.awaitingOwner());
      expect(listed.single.items, isEmpty);
      expect(h.valueOf(keyOf('only')), AssetTransfer.none);
      expect(h.publisher.calls, isEmpty);
    });

    test('once sent, while the publish runs, drops the item too', () async {
      final job = await h.publish(['s1', 's2']);
      await h.stepUntil(() => h.valueOf(keyOf('s1')) == AssetTransfer.sent);

      h.tracked.cancel(keyOf('s1'));
      await pumpEventQueue();

      expect(job.snapshot.items.map((item) => item.itemId), ['s2']);
      expect(h.valueOf(keyOf('s1')), AssetTransfer.none);
    });
  });

  group('diagnostics', () {
    test('binding.mapped names the upload, its state and the value, once '
        'per change, with no path in fields', () async {
      final key = keyOf('d1');
      h.record(key);
      final job = await h.publish(['d1']);
      await h.stepUntil(() => h.valueOf(key) == AssetTransfer.sent);
      await h.answer();

      final mapped = recorder.whereOp(BindingOp.mapped);
      final upload = mapped.first.jobId;
      expect(upload, isA<TransferId>());
      expect(
        mapped,
        everyElement(
          isMpxEvent(
            level: MpxEventLevel.trace,
            jobId: upload,
            itemId: 'd1',
            mediaKey: key,
          ),
        ),
      );
      final transfers = [for (final e in mapped) e.fields['transfer']];
      expect(transfers.first, 'waiting');
      expect(transfers.skip(1).takeWhile((t) => t == 'sending'), isNotEmpty);
      expect(transfers.sublist(transfers.length - 2), ['sent', 'none']);
      expect(mapped.last.fields['state'], 'completed');
      for (final event in mapped) {
        expect(event.fields.values.join(' '), isNot(contains('/prepared')));
      }
      expect(job.snapshot.aliasesApplied, isTrue);
    });
  });
}
