import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

void main() {
  late FakeTransferEnvelope envelope;
  late ManualPlaybackLifecycleSource lifecycle;
  late TransfersHarness h;

  setUp(() async {
    envelope = FakeTransferEnvelope();
    addTearDown(envelope.close);
    lifecycle = ManualPlaybackLifecycleSource(
      initial: AppLifecycleState.resumed,
    );
    h = await harness(envelope: envelope, lifecycle: lifecycle);
  });

  test('starts over the first system job', () {
    final id = h.addUpload(total: 100);
    expect(envelope.starts, [
      TransferEnvelopeProgress(jobs: {id}, done: 0, total: 100),
    ]);
  });

  test('never starts for in-process jobs', () {
    final id = h.addDownload(photo);
    h.runner
      ..progress(id, 5)
      ..complete(id, const FakeTransferResult('file'));
    expect(envelope.starts, isEmpty);
    expect(envelope.stops, 0);
  });

  test('mirrors progress summed over its jobs', () {
    final a = h.addUpload(total: 100);
    final b = h.addUpload(total: 50);
    h.runner
      ..progress(a, 30, total: 100)
      ..progress(b, 10, total: 50);
    expect(envelope.starts, hasLength(1));
    expect(
      envelope.current,
      TransferEnvelopeProgress(jobs: {a, b}, done: 40, total: 150),
    );
  });

  test('has no total while any job has none', () {
    final a = h.addUpload(total: 100);
    h.addUpload();
    h.runner.progress(a, 30, total: 100);
    expect(envelope.current!.total, isNull);
    expect(envelope.current!.done, 30);
  });

  test('stops when its jobs drain', () {
    final a = h.addUpload();
    final b = h.addUpload();
    h.runner.complete(a, const FakeTransferResult('a'));
    expect(envelope.stops, 0);
    expect(envelope.current!.jobs, {b});

    h.runner.fail(b, TransferFailureKind.server);
    expect(envelope.stops, 1);
    expect(envelope.isStarted, isFalse);
  });

  test('a paused job leaves it; resumed, it starts it again', () {
    final id = h.addUpload();
    h.transfers.pause(id);
    expect(envelope.stops, 1);

    h.transfers.resume(id);
    expect(envelope.starts, hasLength(2));
  });

  test('ended by the system, it is not stopped again', () {
    h.addUpload();
    lifecycle.emit(AppLifecycleState.hidden);
    envelope.emit(const TransferEnvelopeEvent.systemEnded());
    expect(envelope.stops, 0);
    expect(envelope.isStarted, isFalse);

    lifecycle.emit(AppLifecycleState.resumed);
    expect(envelope.starts, hasLength(2));
  });
}
