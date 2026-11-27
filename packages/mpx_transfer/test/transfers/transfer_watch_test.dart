import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

import '../support.dart';

void main() {
  group('watch filters', () {
    late List<TransferId> ids;
    late Transfers transfers;

    // upload system 'a' queued, upload inProcess 'b' running,
    // download inProcess 'a' paused, download system 'b' failed.
    setUp(() {
      final h = harness();
      transfers = h.transfers;
      ids = [
        h.addUpload(tag: 'a'),
        h.addUpload(tag: 'b', durability: TransferDurability.inProcess),
        h.addDownload(photo, tag: 'a'),
        h.addDownload(video, tag: 'b', durability: TransferDurability.system),
      ];
      h.runner
        ..progress(ids[1], 1)
        ..fail(ids[3], TransferFailureKind.server);
      transfers.pause(ids[2]);
    });

    Future<List<TransferId>> idsOf(TransferFilter filter) async => [
      for (final job in await jobsOf(transfers, filter)) job.id,
    ];

    test('nothing given: every job, oldest first', () async {
      expect(await idsOf(const TransferFilter()), ids);
    });

    test('by direction', () async {
      expect(
        await idsOf(const TransferFilter(direction: TransferDirection.upload)),
        [ids[0], ids[1]],
      );
      expect(
        await idsOf(
          const TransferFilter(direction: TransferDirection.download),
        ),
        [ids[2], ids[3]],
      );
    });

    test('by state', () async {
      expect(
        await idsOf(TransferFilter(state: (s) => s is TransferState$Queued)),
        [ids[0]],
      );
      expect(
        await idsOf(TransferFilter(state: (s) => s is TransferState$Running)),
        [ids[1]],
      );
      expect(
        await idsOf(
          TransferFilter(
            state: (s) =>
                s is TransferState$Paused && s.reason == PauseReason.user,
          ),
        ),
        [ids[2]],
      );
      expect(
        await idsOf(TransferFilter(state: (s) => s is TransferState$Failed)),
        [ids[3]],
      );
    });

    test('by tag', () async {
      expect(await idsOf(const TransferFilter(tag: 'a')), [ids[0], ids[2]]);
      expect(await idsOf(const TransferFilter(tag: 'c')), isEmpty);
    });

    test('by durability', () async {
      expect(
        await idsOf(
          const TransferFilter(durability: TransferDurability.system),
        ),
        [ids[0], ids[3]],
      );
    });

    test('every part given must match', () async {
      expect(
        await idsOf(
          const TransferFilter(
            direction: TransferDirection.download,
            tag: 'b',
            durability: TransferDurability.system,
          ),
        ),
        [ids[3]],
      );
    });
  });

  group('watch stream', () {
    test('sends the list again when a matching job changes', () async {
      final h = harness();
      final seen = <List<TransferState>>[];
      final sub = h.transfers
          .watch(const TransferFilter(tag: 'mine'))
          .listen((jobs) => seen.add([for (final job in jobs) job.state]));
      addTearDown(sub.cancel);
      await pumpEventQueue();

      final id = h.addUpload(tag: 'mine', total: 10);
      h.addUpload(tag: 'other');
      h.runner.progress(id, 5, total: 10);
      h.transfers.cancel(id);
      await pumpEventQueue();

      expect(seen, [
        <TransferState>[],
        [const TransferState.queued(total: 10)],
        [const TransferState.running(done: 5, total: 10)],
        <TransferState>[],
      ]);
    });

    test('ends at dispose', () async {
      final h = harness();
      final done = Completer<void>();
      h.transfers.watch().listen(null, onDone: done.complete);
      h.transfers.dispose();
      await done.future;
    });
  });

  group('retention', () {
    test('defaults to 24 hours', () {
      expect(Transfers.defaultRetention, const Duration(hours: 24));
    });

    void completedFor(Duration retention, Duration kept) {
      fakeAsync((async) {
        final start = DateTime.utc(2026, 11, 27);
        final h = harness(
          retention: retention,
          now: () => start.add(async.elapsed),
        );
        final seen = <int>[];
        final sub = h.transfers.watch().listen((jobs) => seen.add(jobs.length));
        final id = h.addUpload();
        h.runner.complete(id, const TestResult('ref'));
        async.flushMicrotasks();
        expect(seen.last, 1);

        async
          ..elapse(kept - const Duration(seconds: 1))
          ..flushMicrotasks();
        expect(seen.last, 1, reason: 'still within its retention');

        async
          ..elapse(const Duration(seconds: 1))
          ..flushMicrotasks();
        expect(seen.last, 0, reason: 'retention ended');
        unawaited(sub.cancel());
        h.transfers.dispose();
      });
    }

    test('keeps a completed job queryable for 24 h by default', () {
      completedFor(Transfers.defaultRetention, const Duration(hours: 24));
    });

    test('takes the retention given', () {
      completedFor(const Duration(hours: 2), const Duration(hours: 2));
    });

    test('keeps a failed job past it', () {
      fakeAsync((async) {
        final start = DateTime.utc(2026, 11, 27);
        final h = harness(now: () => start.add(async.elapsed));
        final id = h.addUpload();
        h.runner.fail(id, TransferFailureKind.server);
        async.elapse(const Duration(hours: 48));
        List<TransferJob>? jobs;
        h.transfers.watch().first.then((value) => jobs = value);
        async.flushMicrotasks();
        expect(jobs, hasLength(1));
        h.transfers.dispose();
      });
    });

    test('drops a completed job past it at the next start', () {
      var now = DateTime.utc(2026, 11, 27);
      final h = harness(now: () => now);
      final id = h.addUpload();
      h.runner.complete(id, const TestResult('ref'));
      h.transfers.dispose();
      now = now.add(const Duration(hours: 25));

      final restarted = h.restart();
      expect(restarted.debugSnapshot().jobs, isEmpty);
      return expectLater(jobsOf(restarted), completion(isEmpty));
    });
  });

  group('debugSnapshot', () {
    test('holds the jobs not completed and connectivity', () {
      final h = harness();
      final open = h.addUpload(tag: 't');
      final done = h.addUpload();
      h.runner.complete(done, const TestResult('ref'));
      h.transfers.connectivityChanged(online: false);

      final snapshot = h.transfers.debugSnapshot();

      expect([for (final job in snapshot.jobs) job.id], [open]);
      expect(snapshot.jobs.single.tag, 't');
      expect(snapshot.online, isFalse);
    });
  });
}
