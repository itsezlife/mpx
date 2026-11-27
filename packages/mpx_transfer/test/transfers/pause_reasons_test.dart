import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

void main() {
  group('user', () {
    test('entered by pause, left by resume', () async {
      final h = harness();
      final id = h.addUpload(total: 10);
      h.runner.progress(id, 4, total: 10);

      h.transfers.pause(id);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.paused(
          reason: PauseReason.user,
          done: 4,
          total: 10,
        ),
      );

      h.transfers.resume(id);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.queued(total: 10),
      );
    });

    test('stays across connectivity and the foreground', () async {
      final lifecycle = ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.paused,
      );
      final h = harness(lifecycle: lifecycle);
      final id = h.addUpload();
      h.transfers.pause(id);

      h.transfers
        ..connectivityChanged(online: false)
        ..connectivityChanged(online: true);
      lifecycle.emit(AppLifecycleState.resumed);

      expect(
        await stateOf(h.transfers, id),
        const TransferState.paused(reason: PauseReason.user),
      );
    });
  });

  group('systemInterrupted', () {
    late ManualPlaybackLifecycleSource lifecycle;
    late FakeTransferEnvelope envelope;
    late TransfersHarness h;

    setUp(() {
      lifecycle = ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.resumed,
      );
      envelope = FakeTransferEnvelope();
      addTearDown(envelope.close);
      h = harness(lifecycle: lifecycle, envelope: envelope);
    });

    test('entered when the system ends the envelope', () async {
      final id = h.addUpload(total: 10);
      h.runner.progress(id, 3, total: 10);
      lifecycle.emit(AppLifecycleState.hidden);

      envelope.emit(const TransferEnvelopeEvent.systemEnded());

      expect(
        await stateOf(h.transfers, id),
        const TransferState.paused(
          reason: PauseReason.systemInterrupted,
          done: 3,
          total: 10,
        ),
      );
      expect(h.runner.isRunning(id), isFalse);
    });

    test('left when the app is in the foreground again', () async {
      final id = h.addUpload(total: 10);
      lifecycle.emit(AppLifecycleState.hidden);
      envelope.emit(const TransferEnvelopeEvent.systemEnded());

      lifecycle.emit(AppLifecycleState.inactive);
      expect(
        await stateOf(h.transfers, id),
        isA<TransferState$Paused>(),
        reason: 'visible but not focused is not the foreground',
      );

      lifecycle.emit(AppLifecycleState.resumed);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.queued(total: 10),
      );
      expect(h.runner.isRunning(id), isTrue);
    });

    test('touches no in-process job', () async {
      final system = h.addUpload();
      final local = h.addUpload(durability: TransferDurability.inProcess);
      envelope.emit(const TransferEnvelopeEvent.systemEnded());

      expect(await stateOf(h.transfers, system), isA<TransferState$Paused>());
      expect(await stateOf(h.transfers, local), const TransferState.queued());
    });

    test('left at a start in the foreground', () async {
      final id = h.addUpload();
      lifecycle.emit(AppLifecycleState.hidden);
      envelope.emit(const TransferEnvelopeEvent.systemEnded());
      // The process ends in the background; the next one starts in front.
      h.transfers.dispose();
      lifecycle.emit(AppLifecycleState.resumed);

      expect(await stateOf(h.restart(), id), const TransferState.queued());
    });

    test('kept at a start in the background', () async {
      final id = h.addUpload();
      lifecycle.emit(AppLifecycleState.hidden);
      envelope.emit(const TransferEnvelopeEvent.systemEnded());

      expect(
        await stateOf(h.restart(), id),
        const TransferState.paused(reason: PauseReason.systemInterrupted),
      );
    });
  });

  group('awaitingNetwork', () {
    test('entered by a network failure while offline', () async {
      final h = harness();
      final id = h.addUpload(total: 10);
      h.runner.progress(id, 5, total: 10);
      h.transfers.connectivityChanged(online: false);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.running(done: 5, total: 10),
        reason: 'going offline stops nothing by itself',
      );

      h.runner.fail(id, TransferFailureKind.network);

      expect(
        await stateOf(h.transfers, id),
        const TransferState.paused(
          reason: PauseReason.awaitingNetwork,
          done: 5,
          total: 10,
        ),
      );
    });

    test('not entered by another failure while offline', () async {
      final h = harness(online: false);
      final id = h.addUpload();
      h.runner.fail(id, TransferFailureKind.server);
      expect(await stateOf(h.transfers, id), isA<TransferState$Failed>());
    });

    test('left when connectivity comes back', () async {
      final h = harness(online: false);
      final id = h.addUpload(total: 10);
      h.runner.fail(id, TransferFailureKind.network);

      h.transfers.connectivityChanged(online: true);

      expect(
        await stateOf(h.transfers, id),
        const TransferState.queued(total: 10),
      );
      expect(h.runner.isRunning(id), isTrue);
    });
  });

  group('awaitingResume', () {
    test(
      'entered at start by a download that does not resume by itself',
      () async {
        final h = harness();
        final auto = h.addDownload(photo, total: 10, resumeOnStart: false);
        final user = h.addDownload(video);
        h.runner.progress(auto, 6, total: 10);

        final restarted = h.restart();

        expect(
          await stateOf(restarted, auto),
          const TransferState.paused(
            reason: PauseReason.awaitingResume,
            done: 6,
            total: 10,
          ),
        );
        expect(await stateOf(restarted, user), const TransferState.queued());
        expect(h.runner.isRunning(auto), isFalse);
        expect(h.runner.isRunning(user), isTrue);
      },
    );

    test('not entered by an upload, which always resumes', () async {
      final h = harness();
      final id = h.addUpload();
      expect(await stateOf(h.restart(), id), const TransferState.queued());
    });

    test('left by resume', () async {
      final h = harness();
      final id = h.addDownload(photo, resumeOnStart: false);
      final restarted = h.restart();

      expect(restarted.resume(id), isTrue);

      expect(await stateOf(restarted, id), const TransferState.queued());
      expect(h.runner.isRunning(id), isTrue);
    });
  });
}
