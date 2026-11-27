import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

void main() {
  late RecordingDiagnostics recorder;
  late TransfersHarness h;
  late DateTime now;

  setUp(() async {
    recorder = RecordingDiagnostics.install();
    now = DateTime.utc(2026, 11, 27);
    h = await harness(now: () => now);
  });

  test('jobQueued: direction, durability, priority and every id', () {
    final id = h.addDownload(photo, tag: 'chat:1:m1');
    expect(recorder.whereOp(SchedulerOp.jobQueued), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        category: 'scheduler',
        jobId: id,
        mediaKey: photo,
        tag: 'chat:1:m1',
        fields: {
          'direction': 'download',
          'durability': 'inProcess',
          'priority': 'visible',
        },
      ),
    ]);
  });

  test('jobStarted: once per attempt, with the time it waited', () {
    final id = h.addUpload(tag: 't');
    now = now.add(const Duration(milliseconds: 250));
    h.runner
      ..progress(id, 1)
      ..progress(id, 2);
    expect(recorder.whereOp(SchedulerOp.jobStarted), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        jobId: id,
        tag: 't',
        fields: {'durability': 'system', 'waitedMs': 250},
      ),
    ]);
  });

  test('paused and resumed: the reason entered and the reason left', () async {
    final id = h.addUpload(tag: 't');
    h.transfers
      ..pause(id)
      ..resume(id);
    expect(recorder.whereOp(SchedulerOp.paused), [
      isMpxEvent(
        level: MpxEventLevel.info,
        jobId: id,
        tag: 't',
        fields: {'reason': 'user', 'durability': 'system'},
      ),
    ]);
    expect(recorder.whereOp(SchedulerOp.resumed), [
      isMpxEvent(
        level: MpxEventLevel.info,
        jobId: id,
        tag: 't',
        fields: {'reason': 'user', 'durability': 'system'},
      ),
    ]);
  });

  test('paused for each reason', () async {
    final lifecycle = ManualPlaybackLifecycleSource(
      initial: AppLifecycleState.hidden,
    );
    final envelope = FakeTransferEnvelope();
    addTearDown(envelope.close);
    final h = await harness(lifecycle: lifecycle, envelope: envelope);

    final network = h.addUpload();
    h.transfers.connectivityChanged(online: false);
    h.runner.fail(network, TransferFailureKind.network);
    final system = h.addUpload();
    envelope.emit(const TransferEnvelopeEvent.systemEnded());
    final download = h.addDownload(photo, resumeOnStart: false);
    final user = h.addUpload();
    h.transfers.pause(user);
    final restarted = await h.restart(online: false);
    addTearDown(restarted.dispose);

    expect(
      {
        for (final event in recorder.whereOp(SchedulerOp.paused))
          event.jobId: event.fields['reason'],
      },
      {
        network: 'awaitingNetwork',
        system: 'systemInterrupted',
        user: 'user',
        download: 'awaitingResume',
      },
    );
    expect(recorder.errors, isEmpty);
  });

  test('priorityChanged: from and to', () {
    final id = h.addDownload(photo);
    h.transfers.setPriority(id, RequestPriority.preload);
    expect(recorder.whereOp(SchedulerOp.priorityChanged), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        jobId: id,
        mediaKey: photo,
        fields: {'from': 'visible', 'to': 'preload'},
      ),
    ]);
  });

  test('cancelled: by the user', () {
    final id = h.addUpload(tag: 't');
    h.transfers.cancel(id);
    expect(recorder.whereOp(SchedulerOp.cancelled), [
      isMpxEvent(
        level: MpxEventLevel.info,
        jobId: id,
        tag: 't',
        fields: {'by': 'user', 'durability': 'system'},
      ),
    ]);
  });

  test('failed: the one error, with kind, retryable and bytes', () {
    final id = h.addDownload(photo, tag: 't');
    h.runner
      ..progress(id, 7, total: 9)
      ..fail(id, TransferFailureKind.server, retryable: false);
    expect(recorder.errors, [
      isMpxEvent(
        op: SchedulerOp.failed,
        jobId: id,
        mediaKey: photo,
        tag: 't',
        fields: {
          'kind': 'server',
          'durability': 'inProcess',
          'retryable': false,
          'done': 7,
          'total': 9,
        },
      ),
    ]);
  });

  test('failed: no total when it is unknown', () {
    final id = h.addUpload();
    h.runner.fail(id, TransferFailureKind.local, retryable: false);
    expect(recorder.errors.single.fields.containsKey('total'), isFalse);
  });

  test('a retry queues the job again', () {
    final id = h.addUpload();
    h.runner.fail(id, TransferFailureKind.server);
    h.transfers.retry(id);
    expect(recorder.whereOp(SchedulerOp.jobQueued), hasLength(2));
  });

  test('completed: bytes and time since it was made', () {
    final id = h.addUpload(tag: 't');
    h.runner.progress(id, 100, total: 100);
    now = now.add(const Duration(seconds: 2));
    h.runner.complete(id, const FakeTransferResult('ref'));
    expect(recorder.whereOp(SchedulerOp.completed), [
      isMpxEvent(
        level: MpxEventLevel.info,
        jobId: id,
        tag: 't',
        fields: {'durability': 'system', 'bytes': 100, 'ms': 2000},
      ),
    ]);
  });

  test('connectivityChanged: online and the jobs it resumed', () {
    h.transfers.connectivityChanged(online: false);
    final id = h.addUpload();
    h.runner.fail(id, TransferFailureKind.network);
    h.transfers
      ..connectivityChanged(online: false)
      ..connectivityChanged(online: true);
    expect(recorder.whereOp(SchedulerOp.connectivityChanged), [
      isMpxEvent(
        level: MpxEventLevel.info,
        fields: {'online': false, 'jobsAffected': 0},
      ),
      isMpxEvent(
        level: MpxEventLevel.info,
        fields: {'online': true, 'jobsAffected': 1},
      ),
    ]);
  });

  test('envelope: requested, ended by the system, withdrawn', () async {
    final envelope = FakeTransferEnvelope();
    addTearDown(envelope.close);
    final h = await harness(envelope: envelope);
    final first = h.addUpload();
    envelope.emit(const TransferEnvelopeEvent.systemEnded());
    h.transfers.resume(first);
    h.runner.complete(first, const FakeTransferResult('ref'));

    expect(recorder.whereCategory('envelope'), [
      isMpxEvent(
        op: EnvelopeOp.startRequested,
        level: MpxEventLevel.debug,
        jobId: first,
        fields: {'jobs': 1},
      ),
      isMpxEvent(
        op: EnvelopeOp.systemEnded,
        level: MpxEventLevel.warning,
        jobId: first,
        fields: {'jobs': 1},
      ),
      isMpxEvent(op: EnvelopeOp.startRequested),
      isMpxEvent(
        op: EnvelopeOp.withdrawn,
        level: MpxEventLevel.info,
        fields: {'why': 'drained'},
      ),
    ]);
  });

  test('no field carries the cache key', () {
    const key = MediaKey.remote('https://cdn.example/secret.jpg');
    final id = h.addDownload(key);
    h.runner.fail(id, TransferFailureKind.network);
    for (final event in recorder.events) {
      for (final value in event.fields.values) {
        expect('$value', isNot(contains('secret')));
      }
      expect(event.jobId, isNot(contains('secret')));
    }
  });
}
