import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/src/journal/file_journal_store.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

/// Every state boundary of the state model, each reached through the
/// facade by bringing a new job to it; each answers the job's id.
final Map<String, TransferId Function(TransfersHarness h)> _boundaries = {
  'queued': (h) => h.addUpload(total: 100),
  'running': (h) {
    final id = h.addUpload(total: 100);
    h.runner.progress(id, 10, total: 100);
    return id;
  },
  'paused(user)': (h) {
    final id = h.addUpload(total: 100);
    h.runner.progress(id, 10, total: 100);
    h.transfers.pause(id);
    return id;
  },
  'paused(awaitingNetwork)': (h) {
    final id = h.addUpload();
    h.transfers.connectivityChanged(online: false);
    h.runner.fail(id, TransferFailureKind.network);
    return id;
  },
  'failed': (h) {
    final id = h.addUpload();
    h.runner
      ..progress(id, 3)
      ..fail(id, TransferFailureKind.server, retryable: false);
    return id;
  },
  'completed': (h) {
    final id = h.addUpload();
    h.runner.complete(id, const FakeTransferResult('ref'));
    return id;
  },
};

void main() {
  late DateTime now;

  setUp(() => now = DateTime.utc(2026, 11, 27));

  group('a kill at each state boundary', () {
    for (final MapEntry(key: name, value: setup) in _boundaries.entries) {
      test('brings a $name job back as it was flushed', () async {
        final h = await harness(now: () => now);
        final id = setup(h);
        final flushed = await jobsOf(h.transfers);
        await h.settle();
        await h.kill();

        expect(h.replayed, flushed);
        expect(h.replayed.single.id, id);
      });
    }

    test('brings a paused(systemInterrupted) job back as it was '
        'flushed', () async {
      final lifecycle = ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.hidden,
      );
      final envelope = FakeTransferEnvelope();
      addTearDown(envelope.close);
      final h = await harness(
        lifecycle: lifecycle,
        envelope: envelope,
        now: () => now,
      );
      final id = h.addUpload();
      envelope.emit(const TransferEnvelopeEvent.systemEnded());
      await h.settle();
      await h.kill();

      expect(h.replayed.single.id, id);
      expect(
        h.replayed.single.state,
        const TransferState.paused(reason: PauseReason.systemInterrupted),
      );
    });

    test('brings a paused(awaitingResume) job back as it was '
        'flushed', () async {
      final h = await harness(now: () => now);
      final id = h.addDownload(photo, resumeOnStart: false);
      await h.settle();
      await h.kill();
      await h.settle();
      await h.kill();

      expect(h.replayed.single.id, id);
      expect(
        h.replayed.single.state,
        const TransferState.paused(reason: PauseReason.awaitingResume),
      );
    });

    test('keeps a cancelled job gone', () async {
      final h = await harness(now: () => now);
      final id = h.addUpload();
      h.transfers.cancel(id);
      await h.settle();
      await h.kill();

      expect(h.replayed, isEmpty);
    });

    test('in the middle of a progress window keeps the state flushed '
        'before it', () async {
      final h = await harness(now: () => now);
      final id = h.addUpload(total: 100);
      h.runner.progress(id, 10, total: 100);
      await h.settle();
      h.runner.progress(id, 60, total: 100);
      await h.kill();

      expect(
        h.replayed.single.state,
        const TransferState.running(done: 10, total: 100),
      );
    });

    test('resumes what was moving, on the journal it read', () async {
      final h = await harness(now: () => now);
      final id = h.addUpload(total: 100);
      h.runner.progress(id, 10, total: 100);
      await h.settle();
      final restarted = await h.kill();

      expect(
        await stateOf(restarted, id),
        const TransferState.queued(total: 100),
      );
      expect(h.runner.starts.map((job) => job.id), [id, id]);
    });

    test('over files on disk, read by a new store', () async {
      final directory = Directory.systemTemp.createTempSync('mpx_journal_');
      addTearDown(() => directory.delete(recursive: true));
      final h = await harness(
        now: () => now,
        store: () => FileJournalStore(directory.path),
      );
      final queued = h.addUpload(tag: 'a');
      final completed = h.addUpload(tag: 'b');
      h.runner.complete(completed, const FakeTransferResult('ref'));
      final flushed = await jobsOf(h.transfers);
      await h.settle();
      await h.kill();

      expect(h.replayed, flushed);
      expect(h.replayed.map((job) => job.id), [queued, completed]);
    });
  });

  group('progress batching', () {
    test('defaults to 250 ms', () {
      expect(
        Transfers.defaultProgressInterval,
        const Duration(milliseconds: 250),
      );
    });

    test('writes progress at most once per 250 ms, and a kill loses at '
        'most that window', () {
      fakeAsync((async) {
        final recorder = RecordingDiagnostics.install();
        final start = DateTime.utc(2026, 11, 27);
        final h = harnessIn(async, now: () => start.add(async.elapsed));
        expect(h.transfers.progressInterval, const Duration(milliseconds: 250));
        final id = h.addUpload(total: 1000);
        h.runner.progress(id, 10, total: 1000);
        async.flushMicrotasks();
        recorder.clear();

        void progressAt(int done, Duration after) {
          async.elapse(after);
          h.runner.progress(id, done, total: 1000);
        }

        // Progress at 0, 100 and 200 ms after the first batched report.
        progressAt(20, Duration.zero);
        progressAt(30, const Duration(milliseconds: 100));
        progressAt(40, const Duration(milliseconds: 100));
        async.elapse(const Duration(milliseconds: 49));
        expect(recorder.whereOp(JournalOp.progressFlushed), isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(recorder.whereOp(JournalOp.progressFlushed), [
          isMpxEvent(
            level: MpxEventLevel.trace,
            category: 'journal',
            fields: allOf(
              containsPair('jobs', 1),
              containsPair('bytes', greaterThan(0)),
              containsPair('sinceLastMs', 250),
            ),
          ),
        ]);

        // The next window opens with the next report.
        progressAt(50, const Duration(milliseconds: 10));
        async.elapse(const Duration(milliseconds: 249));
        expect(recorder.whereOp(JournalOp.progressFlushed), hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(recorder.whereOp(JournalOp.progressFlushed), hasLength(2));

        // A kill inside the third window loses only it.
        progressAt(90, const Duration(milliseconds: 10));
        unawaited(h.kill());
        async.flushMicrotasks();
        expect(
          h.replayed.single.state,
          const TransferState.running(done: 50, total: 1000),
        );
        unawaited(h.transfers.dispose());
        async.flushMicrotasks();
      });
    });

    test('a state change takes the batched progress with it', () async {
      final h = await harness(now: () => now);
      final id = h.addUpload(total: 100);
      h.runner
        ..progress(id, 10, total: 100)
        ..progress(id, 70, total: 100);
      h.transfers.pause(id);
      await h.settle();
      await h.kill();

      expect(
        h.replayed.single.state,
        const TransferState.paused(
          reason: PauseReason.user,
          done: 70,
          total: 100,
        ),
      );
    });
  });
}
