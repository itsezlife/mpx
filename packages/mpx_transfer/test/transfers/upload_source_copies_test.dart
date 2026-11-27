import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

SourceBytes _source(int size) => MemorySourceBytes(Uint8List(size));

void main() {
  late RecordingDiagnostics recorder;
  late FakeUploadSourceCopies copies;
  late DateTime now;

  setUp(() {
    recorder = RecordingDiagnostics.install();
    copies = FakeUploadSourceCopies();
    now = DateTime.utc(2026, 11, 27);
  });

  /// A harness as on the web: [copies] outlive every start, as OPFS
  /// outlives a reload.
  Future<TransfersHarness> web({
    int limit = Transfers.defaultSourceCopyLimit,
    UploadSourceCopies? keeping,
    UnloadWarning? unloadWarning,
  }) async {
    final built = await TransfersHarness.open(
      lifecycle: ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.resumed,
      ),
      now: () => now,
      sourceCopies: () => keeping ?? copies,
      sourceCopyLimit: limit,
      unloadWarning: unloadWarning,
    );
    addTearDown(() => built.transfers.dispose());
    return built;
  }

  test('the copy limit is 500 MiB by default, the sum of a job', () async {
    expect(Transfers.defaultSourceCopyLimit, 500 * 1024 * 1024);
    final directory = Directory.systemTemp.createTempSync('mpx_limit_');
    addTearDown(() => directory.delete(recursive: true));
    final transfers = await Transfers.open(
      cacheKeyOf: (key) => key.encoded,
      lifecycle: ManualPlaybackLifecycleSource(),
      directory: directory.path,
    );
    addTearDown(transfers.dispose);
    expect(transfers.sourceCopyLimit, 500 * 1024 * 1024);
  });

  test('a job whose sources fit the limit is copied and resumes after a '
      'reload', () async {
    final h = await web(limit: 10);
    final id = h.addUpload(sources: [_source(4), _source(6)], total: 10);
    h.runner.progress(id, 3, total: 10);
    await h.settle();

    expect(copies.holds(id), isTrue);
    expect(recorder.whereOp(JournalOp.sourceCopied), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        jobId: id,
        fields: {'bytes': 10, 'ms': 0},
      ),
    ]);

    recorder.clear();
    final reloaded = await h.kill();
    expect(await stateOf(reloaded, id), const TransferState.queued(total: 10));
    expect(h.runner.isRunning(id), isTrue);
    expect(recorder.whereOp(JournalOp.sourceLost), isEmpty);
    expect(recorder.errors, isEmpty);
    expect((await copies.read(id, 1))!.size, 6);
  });

  test('a job over the limit is not copied and comes back failed with its '
      'source lost', () async {
    final h = await web(limit: 10);
    final id = h.addUpload(sources: [_source(6), _source(5)]);
    await h.settle();

    expect(copies.holds(id), isFalse);
    expect(recorder.whereOp(JournalOp.sourceOverLimit), [
      isMpxEvent(
        level: MpxEventLevel.warning,
        jobId: id,
        fields: {'bytes': 11, 'limit': 10},
      ),
    ]);
    // In this run the job goes on from the page's sources.
    expect(await stateOf(h.transfers, id), const TransferState.queued());

    final reloaded = await h.kill();
    expect(
      await stateOf(reloaded, id),
      const TransferState.failed(
        kind: TransferFailureKind.sourceLost,
        retryable: false,
      ),
    );
    expect(h.runner.isRunning(id), isFalse);
    expect(recorder.whereOp(JournalOp.sourceLost), [
      isMpxEvent(level: MpxEventLevel.error, jobId: id, fields: isEmpty),
    ]);

    // Already lost: the next reload says nothing more.
    recorder.clear();
    await h.kill();
    expect(recorder.whereOp(JournalOp.sourceLost), isEmpty);
  });

  test('a job of exactly the limit is copied', () async {
    final h = await web(limit: 10);
    final id = h.addUpload(sources: [_source(10)]);
    await h.settle();
    expect(copies.holds(id), isTrue);
    expect(recorder.whereOp(JournalOp.sourceOverLimit), isEmpty);
  });

  test('with nowhere to copy (no OPFS) every upload comes back failed with '
      'its source lost, whatever it was doing', () async {
    final h = await web(keeping: const NoUploadSourceCopies());
    final running = h.addUpload(sources: [_source(1)], total: 1);
    h.runner.progress(running, 0, total: 1);
    final paused = h.addUpload(sources: [_source(1)]);
    h.transfers.pause(paused);
    final failed = h.addUpload(sources: [_source(1)]);
    h.runner.fail(failed, TransferFailureKind.server);
    final download = h.addDownload(photo);
    await h.settle();
    expect(recorder.whereOp(JournalOp.sourceCopied), isEmpty);

    final reloaded = await h.kill();
    for (final id in [running, paused, failed]) {
      expect(
        await stateOf(reloaded, id),
        isA<TransferState$Failed>().having(
          (state) => state.kind,
          'kind',
          TransferFailureKind.sourceLost,
        ),
      );
    }
    // A download has no source; it resumes as before.
    expect(await stateOf(reloaded, download), const TransferState.queued());
    expect(
      recorder.whereOp(JournalOp.sourceLost).map((e) => e.jobId),
      unorderedEquals([running, paused, failed]),
    );
  });

  test('a copy a reload cuts short comes back failed with its source '
      'lost', () async {
    final h = await web();
    copies.holdCopies();
    final id = h.addUpload(sources: [_source(4)]);
    await h.transfers.dispose();
    copies.cutCopies();
    await h.kill();

    expect(copies.holds(id), isFalse);
    expect(
      await stateOf(h.transfers, id),
      isA<TransferState$Failed>().having(
        (state) => state.kind,
        'kind',
        TransferFailureKind.sourceLost,
      ),
    );
    expect(recorder.whereOp(JournalOp.sourceCopied), isEmpty);
  });

  test('a copy the storage refuses is reported, and the job runs on from '
      'the page', () async {
    final h = await web();
    copies.refuseCopies = true;
    final id = h.addUpload(sources: [_source(4)]);
    await h.settle();

    expect(recorder.whereOp(JournalOp.writeFailed), [
      isMpxEvent(
        level: MpxEventLevel.error,
        jobId: id,
        fields: {'code': 'refused'},
      ),
    ]);
    expect(await stateOf(h.transfers, id), const TransferState.queued());
    await h.kill();
    expect(recorder.whereOp(JournalOp.sourceLost).single.jobId, id);
  });

  test('copies are deleted when the job completes or is cancelled', () async {
    final h = await web();
    final done = h.addUpload(sources: [_source(1)]);
    final cancelled = h.addUpload(sources: [_source(1)]);
    final kept = h.addUpload(sources: [_source(1)]);
    await h.settle();

    h.runner.complete(done, const FakeTransferResult('r'));
    h.transfers.cancel(cancelled);
    await h.settle();
    expect(copies.deleted, [done, cancelled]);
    expect(copies.held, [kept]);
  });

  test('copies no journaled job needs are deleted at the next '
      'start', () async {
    final h = await web();
    final done = h.addUpload(sources: [_source(1)]);
    await h.settle();
    h.runner.complete(done, const FakeTransferResult('r'));
    // Kept by a run killed before it could delete them.
    await copies.copy(const TransferId.parse('u-orphan'), [_source(1)]);
    await h.kill();

    expect(copies.deleted, [done, const TransferId.parse('u-orphan')]);
    expect(copies.held, isEmpty);
  });

  test('a job cancelled while its sources copy keeps no copy', () async {
    final h = await web();
    copies.holdCopies();
    final id = h.addUpload(sources: [_source(4)]);
    h.transfers.cancel(id);
    copies.releaseCopies();
    await h.settle();

    expect(copies.holds(id), isFalse);
    expect(recorder.whereOp(JournalOp.sourceCopied), isEmpty);
  });

  test('without source copies (the VM) an upload resumes after a kill and '
      'nothing is copied', () async {
    final h = await harness(now: () => now);
    final id = h.addUpload(sources: [_source(4)]);
    await h.settle();
    final restarted = await h.kill();

    expect(await stateOf(restarted, id), const TransferState.queued());
    expect(
      recorder.whereCategory('journal').map((e) => e.op),
      isNot(
        anyOf(
          contains(JournalOp.sourceCopied),
          contains(JournalOp.sourceOverLimit),
          contains(JournalOp.sourceLost),
        ),
      ),
    );
  });

  group('the unload warning', () {
    test('is armed while a job is queued or running and disarmed when '
        'none is', () async {
      final warning = FakeUnloadWarning();
      final h = await web(unloadWarning: warning);
      expect(warning.isArmed, isFalse);

      final a = h.addUpload();
      expect(warning.isArmed, isTrue);
      h.runner.progress(a, 1);
      final b = h.addDownload(photo);
      h.transfers.pause(a);
      expect(warning.isArmed, isTrue, reason: 'b is still queued');
      h.runner.complete(b, const FakeTransferResult('r'));
      expect(warning.isArmed, isFalse);

      h.transfers.resume(a);
      expect(warning.isArmed, isTrue);
      h.runner.fail(a, TransferFailureKind.server);
      expect(warning.isArmed, isFalse);
      expect((warning.arms, warning.disarms), (2, 2));
    });

    test('is disarmed when the engine is disposed', () async {
      final warning = FakeUnloadWarning();
      final h = await web(unloadWarning: warning);
      h.addUpload();
      expect(warning.isArmed, isTrue);
      await h.transfers.dispose();
      expect(warning.isArmed, isFalse);
    });

    test('is armed again after a reload that resumes a job', () async {
      final warning = FakeUnloadWarning();
      final h = await web(unloadWarning: warning);
      h.addUpload(sources: [_source(1)]);
      await h.settle();
      await h.kill();
      expect(warning.isArmed, isTrue);
    });
  });
}
