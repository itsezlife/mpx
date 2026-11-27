import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import 'upload_support.dart';

/// The progress window of these tests.
const Duration _window = Duration(milliseconds: 20);

/// Longer than [_window], so the window before it has been written.
const Duration _pastWindow = Duration(milliseconds: 80);

/// 1.5 h for a file up to 20 bytes, 24 h above: a window by size, as a
/// transport declares one.
Duration _bySize(int size) =>
    size <= 20 ? const Duration(minutes: 90) : const Duration(hours: 24);

void main() {
  late RecordingDiagnostics recorder;
  late DateTime now;
  late FakeUploadSourceFiles files;

  setUp(() {
    recorder = RecordingDiagnostics.install();
    now = DateTime.utc(2026, 11, 27, 12);
    files = FakeUploadSourceFiles();
  });

  /// An upload of [size] bytes in parts of 10, one at a time, through a
  /// transport resuming as [resume], killed once part 0 is acknowledged and
  /// written. Every state the job takes is kept in the returned list.
  Future<
    ({
      UploadsHarness h,
      FakeUploadTransport transport,
      TransferId id,
      String path,
      List<TransferState> states,
    })
  >
  interrupted({
    int size = 30,
    UploadResume resume = const UploadResume.unlimited(),
    DateTime? expiresAt,
  }) async {
    final transport = fakeTransport(
      partSize: 10,
      bytesInFlight: 10,
      resume: resume,
      holdParts: true,
    )..resumeExpiresAt = expiresAt;
    final h = await uploads(
      [transport],
      now: () => now,
      progressInterval: _window,
      files: files,
    );
    const path = '/uploads/resumed.bin';
    files.put(path, size: size);
    final id = h.upload(UploadSource.finished(path, size: size), tag: 'item');
    await pumpEventQueue();
    transport.ack(0);
    await pumpEventQueue();
    await Future<void>.delayed(_pastWindow);
    await h.settle();
    expect(h.uploadOf(id)!.parts.keys, [0]);
    return (
      h: h,
      transport: transport,
      id: id,
      path: path,
      states: <TransferState>[],
    );
  }

  /// Kills [h] and follows job [id] in the new run, keeping every state.
  Future<void> killAndFollow(
    UploadsHarness h,
    TransferId id,
    List<TransferState> states,
  ) async {
    recorder.clear();
    final transfers = await h.kill();
    final subscription = transfers.watch().listen((jobs) {
      for (final job in jobs) {
        if (job.id == id) states.add(job.state);
      }
    });
    addTearDown(subscription.cancel);
    await pumpEventQueue();
  }

  Iterable<int> sentAfterKill(FakeUploadTransport transport, int before) =>
      transport.sent.skip(before).map((part) => part.index);

  Matcher decision(String outcome, int offset, {MpxEventLevel? level}) =>
      equals([
        isMpxEvent(
          level: level ?? MpxEventLevel.info,
          op: TransportOp.resumeDecision,
          fields: {'outcome': outcome, 'offset': offset},
        ),
      ]);

  test('an unchanged source within the window reopens with the token and '
      'continues after the high-water mark', () async {
    final run = await interrupted(resume: const UploadResume.window(_bySize));
    final sent = run.transport.sent.length;
    run.transport.holdParts = false;
    now = now.add(const Duration(hours: 23));
    await killAndFollow(run.h, run.id, run.states);

    expect(run.transport.opens.last.resumeToken, 'fake-token-1');
    expect(sentAfterKill(run.transport, sent), [1, 2]);
    expect(
      recorder.whereOp(TransportOp.resumeDecision),
      decision('resumed', 10),
    );
    expect(recorder.whereOp(TransportOp.resumeDecision).single.jobId, run.id);
    expect(
      await stateOf(run.h.transfers, run.id),
      TransferState.completed(RemoteRef('fake-1')),
    );
  });

  test('a changed source restarts from zero under the same job, never '
      'failed', () async {
    final run = await interrupted();
    final sent = run.transport.sent.length;
    files.touch(run.path);
    await killAndFollow(run.h, run.id, run.states);

    // Opened anew, and the parts of the old file are gone from the journal.
    expect(run.transport.opens.last.resumeToken, isNull);
    final upload = run.h.uploadOf(run.id)!;
    expect(upload.parts, isEmpty);
    expect(upload.highWaterMark, 0);
    expect(upload.resumeToken, 'fake-token-2');
    expect(
      recorder.whereOp(TransportOp.resumeDecision),
      decision('sourceChanged', 0),
    );

    run.transport
      ..holdParts = false
      ..ack(0);
    await pumpEventQueue();
    expect(sentAfterKill(run.transport, sent), [0, 1, 2]);
    final job = (await run.h.transfers.watch().first).single;
    expect(job.id, run.id);
    expect(job.tag, 'item');
    expect(job.state, isA<TransferState$Completed>());
    expect(run.states.whereType<TransferState$Failed>(), isEmpty);
  });

  test(
    'a source rewritten to another size is uploaded at its new size',
    () async {
      final run = await interrupted();
      final sent = run.transport.sent.length;
      run.transport.holdParts = false;
      files.touch(run.path, size: 35);
      await killAndFollow(run.h, run.id, run.states);

      expect(sentAfterKill(run.transport, sent), [0, 1, 2, 3]);
      expect(run.transport.opens.last.info.size, 35);
      expect(run.transport.finishes.single.finalSize, 35);
      expect(
        await stateOf(run.h.transfers, run.id),
        isA<TransferState$Completed>(),
      );
    },
  );

  group('a window by size', () {
    test(
      'past its window, a small file restarts from zero, never failed',
      () async {
        final run = await interrupted(
          size: 20,
          resume: const UploadResume.window(_bySize),
        );
        final sent = run.transport.sent.length;
        run.transport.holdParts = false;
        now = now.add(const Duration(hours: 2));
        await killAndFollow(run.h, run.id, run.states);

        expect(run.transport.opens.last.resumeToken, isNull);
        expect(sentAfterKill(run.transport, sent), [0, 1]);
        expect(
          recorder.whereOp(TransportOp.resumeDecision),
          decision('windowExpired', 0),
        );
        expect(
          await stateOf(run.h.transfers, run.id),
          isA<TransferState$Completed>(),
        );
        expect(run.states.whereType<TransferState$Failed>(), isEmpty);
      },
    );

    test('the same time keeps a big file within its window', () async {
      final run = await interrupted(resume: const UploadResume.window(_bySize));
      run.transport.holdParts = false;
      now = now.add(const Duration(hours: 2));
      await killAndFollow(run.h, run.id, run.states);
      expect(
        recorder.whereOp(TransportOp.resumeDecision),
        decision('resumed', 10),
      );
    });

    test('the window counts from the last progress written', () async {
      final run = await interrupted(
        size: 20,
        resume: const UploadResume.window(_bySize),
      );
      run.transport.holdParts = false;
      now = now.add(const Duration(minutes: 90));
      await killAndFollow(run.h, run.id, run.states);
      expect(
        recorder.whereOp(TransportOp.resumeDecision),
        decision('windowExpired', 0),
      );
    });
  });

  group("the remote end's expiry carried with the token", () {
    test('before it, the upload reopens', () async {
      final run = await interrupted(
        resume: const UploadResume.serverExpiry(),
        expiresAt: now.add(const Duration(hours: 1)),
      );
      expect(
        run.h.uploadOf(run.id)!.resumeExpiresAt,
        now.add(const Duration(hours: 1)),
      );
      run.transport.holdParts = false;
      now = now.add(const Duration(minutes: 59));
      await killAndFollow(run.h, run.id, run.states);
      expect(run.transport.opens.last.resumeToken, 'fake-token-1');
      expect(
        recorder.whereOp(TransportOp.resumeDecision),
        decision('resumed', 10),
      );
    });

    test('past it, the upload restarts from zero, never failed', () async {
      final run = await interrupted(
        resume: const UploadResume.serverExpiry(),
        expiresAt: now.add(const Duration(hours: 1)),
      );
      final sent = run.transport.sent.length;
      run.transport.holdParts = false;
      now = now.add(const Duration(hours: 1));
      await killAndFollow(run.h, run.id, run.states);

      expect(run.transport.opens.last.resumeToken, isNull);
      expect(sentAfterKill(run.transport, sent), [0, 1, 2]);
      expect(
        recorder.whereOp(TransportOp.resumeDecision),
        decision('windowExpired', 0),
      );
      expect(
        await stateOf(run.h.transfers, run.id),
        isA<TransferState$Completed>(),
      );
      expect(run.states.whereType<TransferState$Failed>(), isEmpty);
    });

    test('a remote end that no longer has the upload restarts it from '
        'zero', () async {
      final run = await interrupted(resume: const UploadResume.serverExpiry());
      run.transport
        ..holdParts = false
        ..acceptsResume = false;
      await killAndFollow(run.h, run.id, run.states);

      expect(run.transport.opens.last.resumeToken, 'fake-token-1');
      expect(
        recorder.whereOp(TransportOp.resumeDecision),
        decision('windowExpired', 0),
      );
      expect(
        await stateOf(run.h.transfers, run.id),
        isA<TransferState$Completed>(),
      );
      expect(run.states.whereType<TransferState$Failed>(), isEmpty);
    });
  });

  test('a transport without resume restarts from zero', () async {
    final run = await interrupted(resume: const UploadResume.none());
    final sent = run.transport.sent.length;
    run.transport.holdParts = false;
    await killAndFollow(run.h, run.id, run.states);

    expect(run.transport.opens.map((open) => open.resumeToken), [null, null]);
    expect(sentAfterKill(run.transport, sent), [0, 1, 2]);
    expect(
      recorder.whereOp(TransportOp.resumeDecision),
      decision('noResume', 0),
    );
    expect(
      await stateOf(run.h.transfers, run.id),
      isA<TransferState$Completed>(),
    );
    expect(run.states.whereType<TransferState$Failed>(), isEmpty);
  });

  test('a source gone fails the job with its source lost, retryable; once '
      'the file is back a retry uploads it', () async {
    final run = await interrupted();
    run.transport.holdParts = false;
    files.delete(run.path);
    await killAndFollow(run.h, run.id, run.states);

    expect(
      await stateOf(run.h.transfers, run.id),
      isA<TransferState$Failed>()
          .having((state) => state.kind, 'kind', TransferFailureKind.sourceLost)
          .having((state) => state.retryable, 'retryable', isTrue),
    );
    expect(
      recorder.whereOp(TransportOp.resumeDecision),
      decision('sourceLost', 0, level: MpxEventLevel.error),
    );
    expect(run.transport.opens, hasLength(1), reason: 'nothing reopened');

    files.put(run.path, size: 30);
    expect(run.h.transfers.retry(run.id), isTrue);
    await pumpEventQueue();
    expect(
      await stateOf(run.h.transfers, run.id),
      isA<TransferState$Completed>(),
    );
  });

  test('a source gone before the first run fails the job with its source '
      'lost and no resume decision', () async {
    final h = await uploads([fakeTransport()], files: files);
    final id = h.upload(
      const UploadSource.finished('/uploads/none.bin', size: 5),
    );
    await pumpEventQueue();

    expect(
      await stateOf(h.transfers, id),
      isA<TransferState$Failed>().having(
        (state) => state.kind,
        'kind',
        TransferFailureKind.sourceLost,
      ),
    );
    expect(recorder.whereOp(TransportOp.resumeDecision), isEmpty);
    expect(recorder.whereOp(TransportOp.partGaveUp), [
      isMpxEvent(
        level: MpxEventLevel.error,
        jobId: id,
        fields: {'step': 'open', 'attempts': 0, 'code': 'source_lost'},
      ),
    ]);
  });

  test('a first run judges nothing', () async {
    final h = await uploads([fakeTransport()], files: files);
    files.put('/uploads/first.bin', size: 5);
    final id = h.upload(
      const UploadSource.finished('/uploads/first.bin', size: 5),
    );
    await pumpEventQueue();
    expect(await stateOf(h.transfers, id), isA<TransferState$Completed>());
    expect(recorder.whereOp(TransportOp.resumeDecision), isEmpty);
  });

  test('no resume decision carries the path or the token', () async {
    final run = await interrupted();
    run.transport.holdParts = false;
    files.touch(run.path);
    await killAndFollow(run.h, run.id, run.states);
    for (final event in recorder.whereCategory('transport')) {
      for (final value in event.fields.values) {
        expect('$value', isNot(contains('/uploads/')));
        expect('$value', isNot(contains('fake-token')));
      }
    }
  });
}
