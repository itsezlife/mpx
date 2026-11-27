import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:http_bytes_cache/testing.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

import '../support.dart';
import 'download_support.dart';

void main() {
  TrackedTransfersContract.run(() async {
    final downloads = await DownloadsHarness.open();
    return TrackedTransfersHarness(
      transfers: downloads.tracked,
      content: photo,
      advance: downloads.step,
      interrupt: (key) async {
        downloads.transfers.connectivityChanged(online: false);
        downloads.fetcher
          ..online = false
          ..failAll();
        await downloads.settle();
      },
      resumeInterrupted: (key) async {
        downloads.fetcher.online = true;
        downloads.transfers.connectivityChanged(online: true);
        await downloads.settle();
      },
    );
  });

  late DownloadsHarness h;

  setUp(() async => h = await DownloadsHarness.open());

  group('one job per key', () {
    test('two watchers of one key make one job and one fetch', () async {
      final first = h.tracked.watch(photo);
      final second = h.tracked.watch(photo);
      var heardFirst = 0;
      var heardSecond = 0;
      first.addListener(() => heardFirst++);
      second.addListener(() => heardSecond++);

      h.tracked.download(photo, origin: TransferOrigin.auto);
      h.tracked.download(photo);
      final id = h.transfers.download(photo);
      await h.settle();

      expect(identical(first, second), isTrue);
      expect(await jobsOf(h.transfers), [
        isA<TransferJob>().having((job) => job.id, 'id', id),
      ]);
      expect(h.fetcher.contentRequests, hasLength(1));
      expect(heardFirst, greaterThan(0));
      expect(heardSecond, heardFirst);
    });

    test('the id is the one derived from the cache key', () async {
      final id = h.transfers.download(photo);

      expect(id, TransferId.forDownload(photo.encoded));
    });

    test('a completed download whose content the cache let go downloads '
        'again; one it still holds does not', () async {
      h.transfers.download(photo);
      await h.settle();
      for (var i = 0; i < 4; i++) {
        await h.step();
      }
      expect(
        (await h.jobOf(photo))!.state,
        isA<TransferState$Completed>().having(
          (state) => state.result,
          'result',
          const DownloadedContent(bytes: 400),
        ),
      );

      h.transfers.download(photo);
      await h.settle();
      expect(h.fetcher.contentRequests, hasLength(1));

      await h.store.store.evict(BytesCacheKey(photo.encoded));
      h.fetcher.landed.clear();
      h.transfers.download(photo);
      await h.settle();

      expect(h.fetcher.contentRequests, hasLength(2));
      expect(h.valueOf(photo), const AssetTransfer.receiving(0, 400));
    });
  });

  group('cancel', () {
    test(
      'pauses for the user; download resumes from the landed bytes',
      () async {
        h.tracked.download(photo);
        await h.settle();
        await h.step();
        await h.step();

        h.tracked.cancel(photo);
        await h.settle();

        expect(h.valueOf(photo), const AssetTransfer.awaitingUser(400, 200));
        expect(
          (await h.jobOf(photo))!.state,
          const TransferState.paused(
            reason: PauseReason.user,
            done: 200,
            total: 400,
          ),
        );
        expect(h.fetcher.transfers, 0);

        h.tracked.download(photo);
        await h.settle();

        expect(h.fetcher.contentRequests, hasLength(2));
        expect(h.valueOf(photo), const AssetTransfer.receiving(200, 400));
        await h.step();
        await h.step();
        expect(h.valueOf(photo), AssetTransfer.none);
        expect(h.store.store.contains(BytesCacheKey(photo.encoded)), isTrue);
      },
    );

    test('of a key with no job or a completed one changes nothing', () async {
      h.tracked.cancel(photo);
      expect(await jobsOf(h.transfers), isEmpty);

      h.tracked.download(photo);
      await h.settle();
      for (var i = 0; i < 4; i++) {
        await h.step();
      }
      h.tracked.cancel(photo);

      expect((await h.jobOf(photo))!.state, isA<TransferState$Completed>());
      expect(h.valueOf(photo), AssetTransfer.none);
    });
  });

  group('after a kill mid-download', () {
    Future<void> startAndKill(
      TransferOrigin origin, {
      bool? resumeOnStart,
    }) async {
      h.transfers.download(photo, origin: origin, resumeOnStart: resumeOnStart);
      await h.settle();
      await h.step();
      await h.harness.settle();
      await h.harness.kill();
      await h.settle();
    }

    test('a user download resumes from the cache\'s data', () async {
      await startAndKill(TransferOrigin.user);

      expect(h.fetcher.contentRequests, hasLength(2));
      expect(h.valueOf(photo), const AssetTransfer.receiving(100, 400));
      for (var i = 0; i < 3; i++) {
        await h.step();
      }
      expect(h.valueOf(photo), AssetTransfer.none);
    });

    test('an auto download waits in awaitingResume until a watcher '
        'attaches', () async {
      await startAndKill(TransferOrigin.auto);

      expect(h.fetcher.contentRequests, hasLength(1));
      expect(
        (await h.jobOf(photo))!.state,
        isA<TransferState$Paused>().having(
          (state) => state.reason,
          'reason',
          PauseReason.awaitingResume,
        ),
      );
      final watched = h.tracked.watch(photo);
      expect(watched.value, isA<AssetTransfer$AwaitingUser>());

      final seen = <AssetTransfer>[];
      watched.addListener(() => seen.add(watched.value));
      await h.settle();

      expect(h.fetcher.contentRequests, hasLength(2));
      expect(seen.first, const AssetTransfer.waiting(400));
      expect(watched.value, const AssetTransfer.receiving(100, 400));
      for (var i = 0; i < 3; i++) {
        await h.step();
      }
      expect(watched.value, AssetTransfer.none);
    });

    test('resumeOnStart overrides the origin: an auto download that asks '
        'to resume does', () async {
      await startAndKill(TransferOrigin.auto, resumeOnStart: true);

      expect(h.fetcher.contentRequests, hasLength(2));
      expect(h.valueOf(photo), const AssetTransfer.receiving(100, 400));
    });

    test('resumeOnStart overrides the origin: a user download that asks '
        'not to waits', () async {
      await startAndKill(TransferOrigin.user, resumeOnStart: false);

      expect(h.fetcher.contentRequests, hasLength(1));
      expect(h.valueOf(photo), const AssetTransfer.awaitingUser(400));
    });

    test('a user call for an auto download makes it resume at start', () async {
      h.transfers.download(photo, origin: TransferOrigin.auto);
      h.tracked.download(photo);
      await h.settle();
      await h.step();
      await h.harness.settle();
      await h.harness.kill();
      await h.settle();

      expect((await h.jobOf(photo))!.resumeOnStart, isTrue);
      expect(h.fetcher.contentRequests, hasLength(2));
    });
  });

  group('leaseFile', () {
    test('returns the path of the complete bytes; release frees it', () async {
      h.tracked.download(photo);
      await h.settle();
      await h.step();
      expect(await h.tracked.leaseFile(photo), isNull, reason: 'not whole');
      for (var i = 0; i < 3; i++) {
        await h.step();
      }

      final lease = (await h.tracked.leaseFile(photo))!;
      expect(lease.path, startsWith(FakeBytesBlobStore.root));
      final payloads = h.store.blobs.payloads;
      expect(payloads, hasLength(1));

      // Leased, the file outlives an eviction; released, it goes.
      await h.store.store.evict(BytesCacheKey(photo.encoded));
      expect(payloads, hasLength(1));
      await lease.release();
      expect(payloads, isEmpty);
      expect(lease.isReleased, isTrue);
    });
  });

  group('priority', () {
    test('raised while the request waits in the queue, it is asked again at '
        'the new priority', () async {
      h.fetcher.queue = true;
      final id = h.transfers.download(photo, priority: RequestPriority.preload);
      await h.settle();
      expect(h.fetcher.contentRequests.single.priority, AssetPriority.preload);

      expect(h.transfers.setPriority(id, RequestPriority.visible), isTrue);
      await h.settle();

      final requests = h.fetcher.contentRequests;
      expect(requests, hasLength(2));
      expect(requests.first.cancellation.isCancelled, isTrue);
      expect(requests.last.priority, AssetPriority.visible);
      expect(h.fetcher.transfers, 1);
    });

    test('once bytes move, the request keeps its slot', () async {
      final id = h.transfers.download(photo);
      await h.settle();
      await h.step();

      expect(h.transfers.setPriority(id, RequestPriority.background), isTrue);
      await h.settle();

      expect(h.fetcher.contentRequests, hasLength(1));
      expect((await h.jobOf(photo))!.priority, RequestPriority.background);
    });
  });
}
