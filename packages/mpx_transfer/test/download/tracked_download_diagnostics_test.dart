import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

import '../support.dart';
import 'download_support.dart';

void main() {
  late DownloadsHarness h;
  late RecordingDiagnostics diagnostics;

  setUp(() async {
    h = await DownloadsHarness.open();
    diagnostics = RecordingDiagnostics.install();
  });

  final id = TransferId.forDownload(photo.encoded);

  test('downloadRequested carries the origin, resumeOnStart and whether the '
      'key had a job', () async {
    h.tracked.download(photo, origin: TransferOrigin.auto);
    h.transfers.download(photo);
    h.transfers.download(photo, resumeOnStart: false);

    expect(diagnostics.whereOp(SchedulerOp.downloadRequested), [
      isMpxEvent(
        level: MpxEventLevel.debug,
        jobId: id,
        mediaKey: photo,
        fields: {'origin': 'auto', 'resumeOnStart': false, 'existing': false},
      ),
      isMpxEvent(
        jobId: id,
        mediaKey: photo,
        fields: {'origin': 'user', 'resumeOnStart': true, 'existing': true},
      ),
      isMpxEvent(
        fields: {'origin': 'user', 'resumeOnStart': false, 'existing': true},
      ),
    ]);
  });

  test('an auto download after a restart pauses awaitingResume and resumes '
      'from it when watched', () async {
    h.transfers.download(photo, origin: TransferOrigin.auto);
    await h.settle();
    await h.harness.kill();
    diagnostics.clear();

    h.tracked.watch(photo).addListener(() {});
    await h.settle();

    expect(diagnostics.whereOp(SchedulerOp.resumed), [
      isMpxEvent(
        level: MpxEventLevel.info,
        jobId: id,
        mediaKey: photo,
        fields: {'reason': 'awaitingResume'},
      ),
    ]);
  });

  test('paused awaitingResume is reported at the start', () async {
    h.transfers.download(photo, origin: TransferOrigin.auto);
    await h.settle();
    diagnostics.clear();

    await h.harness.kill();

    expect(diagnostics.whereOp(SchedulerOp.paused), [
      isMpxEvent(
        level: MpxEventLevel.info,
        jobId: id,
        mediaKey: photo,
        fields: {'reason': 'awaitingResume'},
      ),
    ]);
  });

  test('binding.mapped reports each change of a watched value with the job '
      'and its state', () async {
    h.tracked.watch(photo).addListener(() {});
    h.tracked.download(photo);
    await h.settle();
    await h.step();
    h.tracked.cancel(photo);
    h.tracked.download(photo);
    await h.settle();
    for (var i = 0; i < 3; i++) {
      await h.step();
    }

    final mapped = diagnostics.whereOp(BindingOp.mapped);
    expect(mapped.first, isMpxEvent(level: MpxEventLevel.trace, jobId: id));
    expect(
      [
        for (final event in mapped)
          (event.fields['state'], event.fields['transfer']),
      ],
      [
        ('queued', 'waiting'),
        ('running', 'receiving'),
        ('running', 'receiving'),
        ('paused.user', 'awaitingUser'),
        ('queued', 'waiting'),
        ('running', 'receiving'),
        ('running', 'receiving'),
        ('running', 'receiving'),
        ('running', 'receiving'),
        ('completed', 'none'),
      ],
    );
    expect(mapped, everyElement(isMpxEvent(mediaKey: photo)));
  });

  test('no event carries the cache key or a file path', () async {
    h.tracked.watch(photo).addListener(() {});
    h.tracked.download(photo);
    await h.settle();
    for (var i = 0; i < 4; i++) {
      await h.step();
    }
    final lease = await h.tracked.leaseFile(photo);
    await lease!.release();

    final fields = [
      for (final event in diagnostics.events) ...event.fields.values,
    ].whereType<String>();
    expect(fields, isNot(contains(contains(photo.encoded))));
    expect(fields, isNot(contains(contains(lease.path))));
  });
}
