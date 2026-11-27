import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

void main() {
  late RecordingDiagnostics recorder;
  late TransfersHarness h;
  late List<bool> seen;

  setUp(() async {
    recorder = RecordingDiagnostics.install();
    h = await harness();
    seen = [];
    h.transfers.systemActive.addListener(
      () => seen.add(h.transfers.systemActive.value),
    );
  });

  bool active() => h.transfers.systemActive.value;

  test('is false with no job', () {
    expect(active(), isFalse);
  });

  test('turns true when a system job is queued and when it runs', () {
    final id = h.addUpload();
    expect(active(), isTrue);
    h.runner.progress(id, 5);
    expect(active(), isTrue);
    expect(seen, [true]);
  });

  test('stays true across two jobs, false when the last ends', () {
    final a = h.addUpload();
    final b = h.addUpload();
    h.runner.complete(a, const FakeTransferResult('a'));
    expect(active(), isTrue);
    h.runner.complete(b, const FakeTransferResult('b'));
    expect(active(), isFalse);
    expect(seen, [true, false]);
  });

  test('turns false when the last job pauses, true again on resume', () {
    final id = h.addUpload();
    h.transfers.pause(id);
    expect(active(), isFalse);
    h.transfers.resume(id);
    expect(active(), isTrue);
  });

  test('turns false when the last job fails, true again on retry', () {
    final id = h.addUpload();
    h.runner.fail(id, TransferFailureKind.server);
    expect(active(), isFalse);
    h.transfers.retry(id);
    expect(active(), isTrue);
  });

  test('turns false when the last job is cancelled', () {
    final id = h.addUpload();
    h.transfers.cancel(id);
    expect(active(), isFalse);
  });

  test('an in-process job never sets it', () {
    final id = h.addDownload(photo);
    h.runner.progress(id, 5);
    expect(active(), isFalse);
    h.runner.complete(id, const FakeTransferResult('file'));
    final up = h.addUpload(durability: TransferDurability.inProcess);
    h.runner.progress(up, 1);
    expect(active(), isFalse);
    expect(seen, isEmpty);
  });

  test('an in-process job beside a system job does not hold it', () {
    final system = h.addUpload();
    h.addDownload(photo);
    h.runner.complete(system, const FakeTransferResult('x'));
    expect(active(), isFalse);
  });

  test('scheduler events carry the durability that explains the change', () {
    final id = h.addUpload();
    h.runner.progress(id, 1);
    h.transfers.pause(id);
    h.transfers.resume(id);
    h.runner.fail(id, TransferFailureKind.server);
    h.transfers.retry(id);
    h.runner.complete(id, const FakeTransferResult('x'));
    final other = h.addUpload();
    h.transfers.cancel(other);
    for (final op in [
      SchedulerOp.jobQueued,
      SchedulerOp.jobStarted,
      SchedulerOp.paused,
      SchedulerOp.resumed,
      SchedulerOp.failed,
      SchedulerOp.completed,
      SchedulerOp.cancelled,
    ]) {
      final events = recorder.whereOp(op);
      expect(events, isNotEmpty, reason: '$op');
      for (final event in events) {
        expect(event.fields['durability'], 'system', reason: '$op');
      }
    }
  });

  test('a restart over a running system job reads true at once', () async {
    h.addUpload();
    await h.settle();
    await h.kill();
    expect(h.transfers.systemActive.value, isTrue);
  });
}
