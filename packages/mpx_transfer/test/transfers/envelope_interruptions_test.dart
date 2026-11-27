import 'dart:ui' show AppLifecycleState;

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../download/download_support.dart';
import '../support.dart';

const int _mib = 1024 * 1024;

void main() {
  late RecordingDiagnostics recorder;
  late ManualPlaybackLifecycleSource lifecycle;
  late FakeTransferEnvelope envelope;

  setUp(() {
    recorder = RecordingDiagnostics.install();
    lifecycle = ManualPlaybackLifecycleSource(
      initial: AppLifecycleState.resumed,
    );
    envelope = FakeTransferEnvelope();
    addTearDown(envelope.close);
  });

  Future<TransfersHarness> open({
    TransferEnvelopeConfig? config,
    bool configure = true,
    bool withEnvelope = true,
  }) => harness(
    lifecycle: lifecycle,
    envelope: withEnvelope ? envelope : null,
    envelopeConfig: config,
    configureEnvelope: configure,
  );

  List<String?> whys(EnvelopeOp op) => [
    for (final event in recorder.whereOp(op)) event.fields['why'] as String?,
  ];

  group('start and stop', () {
    test('a system job starts it with the host config, an in-process job '
        'does not', () async {
      const config = TransferEnvelopeConfig(
        title: 'Sending',
        text: '2 files',
        cancelAllLabel: 'Cancel all',
        icon: 'ic_upload',
      );
      final h = await open(config: config);
      h.addDownload(photo);
      expect(envelope.starts, isEmpty);
      expect(whys(EnvelopeOp.notStarted), ['inProcess']);

      final id = h.addUpload(total: 10);
      expect(envelope.starts.single.jobs, {id});
      expect(envelope.configs.single, same(config));
      expect(
        recorder.whereOp(EnvelopeOp.startRequested).single,
        isMpxEvent(
          level: MpxEventLevel.debug,
          jobId: id,
          fields: {'jobs': 1, 'rule': 'always'},
        ),
      );
      await pumpEventQueue();
      expect(
        recorder.whereOp(EnvelopeOp.started).single,
        isMpxEvent(
          level: MpxEventLevel.info,
          fields: {'handle': 'fake-1', 'kind': 'uidt', 'adopted': false},
        ),
      );
    });

    test('stops when its jobs drain', () async {
      final h = await open();
      final a = h.addUpload();
      final b = h.addUpload();
      await pumpEventQueue();
      h.runner.complete(a, const FakeTransferResult('a'));
      expect(envelope.stops, 0);
      h.runner.complete(b, const FakeTransferResult('b'));
      expect(envelope.stops, 1);
      expect(whys(EnvelopeOp.withdrawn), ['drained']);
    });

    test('drained before its start answered, it is stopped and not taken '
        'up again', () async {
      envelope.holdStarts();
      final h = await open();
      final id = h.addUpload();
      h.runner.complete(id, const FakeTransferResult('a'));
      expect(envelope.stops, 1);
      envelope.answerStart();
      await pumpEventQueue();
      expect(
        h.transfers.debugSnapshot().envelope!.state,
        EnvelopeDebugState.idle,
      );
    });

    test('long rule: a short job runs without it and joins one a long job '
        'starts', () async {
      envelope = FakeTransferEnvelope(
        startRule: TransferEnvelopeStartRule.long,
      );
      addTearDown(envelope.close);
      final h = await open();
      final short = h.addUpload(total: 5 * _mib);
      expect(envelope.starts, isEmpty);
      expect(whys(EnvelopeOp.notStarted), ['short']);

      final long = h.addUpload(total: 11 * _mib);
      expect(envelope.starts.single.jobs, {short, long});
      expect(
        recorder.whereOp(EnvelopeOp.startRequested).single.fields['rule'],
        'long',
      );
    });

    test('the long threshold is 10 MiB by default', () {
      expect(TransferEnvelopeConfig.defaultLongJobBytes, 10 * _mib);
      expect(const TransferEnvelopeConfig(title: 't').longJobBytes, 10 * _mib);
    });

    test('the host overrides the platform rule down to never', () async {
      final h = await open(
        config: const TransferEnvelopeConfig(
          title: 't',
          startRule: TransferEnvelopeStartRule.never,
        ),
      );
      h.addUpload(total: 100 * _mib);
      expect(envelope.starts, isEmpty);
      expect(whys(EnvelopeOp.notStarted), ['never']);
    });

    test('and up to always', () async {
      envelope = FakeTransferEnvelope(
        startRule: TransferEnvelopeStartRule.long,
      );
      addTearDown(envelope.close);
      final h = await open(
        config: const TransferEnvelopeConfig(
          title: 't',
          startRule: TransferEnvelopeStartRule.always,
        ),
      );
      h.addUpload(total: 1);
      expect(envelope.starts, hasLength(1));
    });

    test('without an envelope a system job reports the platform', () async {
      final h = await open(withEnvelope: false);
      h.addUpload();
      expect(whys(EnvelopeOp.notStarted), ['platform']);
    });

    test('unconfigured, system jobs run in process with one warning', () async {
      final h = await open(configure: false);
      final a = h.addUpload();
      final b = h.addUpload();
      expect(envelope.starts, isEmpty);
      expect(await stateOf(h.transfers, a), const TransferState.queued());
      expect(h.runner.isRunning(b), isTrue);
      expect(recorder.whereOp(EnvelopeOp.degraded), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          jobId: a,
          fields: {'from': 'system', 'to': 'inProcess', 'why': 'unconfigured'},
        ),
      ]);
      expect(
        h.transfers.debugSnapshot().envelope!.state,
        EnvelopeDebugState.unconfigured,
      );
    });

    test('a refused start runs its jobs in process with one warning and is '
        'not asked again for them', () async {
      envelope.refusal = 'securityException';
      final h = await open();
      final id = h.addUpload(total: 10);
      await pumpEventQueue();
      expect(recorder.whereOp(EnvelopeOp.refused), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          fields: {'code': 'securityException'},
        ),
      ]);
      expect(recorder.whereOp(EnvelopeOp.degraded), [
        isMpxEvent(
          level: MpxEventLevel.warning,
          jobId: id,
          fields: {'from': 'system', 'to': 'inProcess', 'why': 'refused'},
        ),
      ]);
      h.runner.progress(id, 5, total: 10);
      expect(envelope.starts, hasLength(1));
      expect(h.runner.isRunning(id), isTrue);
    });
  });

  group('system end', () {
    test('pauses every job inside systemInterrupted, deletes nothing, and '
        'resumes them in the foreground', () async {
      final h = await open();
      final a = h.addUpload(total: 10);
      final b = h.addUpload(total: 20);
      h.runner.progress(a, 4, total: 10);
      lifecycle.emit(AppLifecycleState.hidden);
      envelope.emit(
        const TransferEnvelopeEvent.systemEnded(
          cause: TransferEnvelopeEndCause.expiry,
        ),
      );

      final jobs = await jobsOf(h.transfers);
      expect(
        [for (final job in jobs) job.state],
        [
          const TransferState.paused(
            reason: PauseReason.systemInterrupted,
            done: 4,
            total: 10,
          ),
          const TransferState.paused(
            reason: PauseReason.systemInterrupted,
            total: 20,
          ),
        ],
      );
      expect(
        recorder.whereOp(EnvelopeOp.systemEnded).single,
        isMpxEvent(
          level: MpxEventLevel.warning,
          jobId: a,
          fields: {'jobs': 2, 'cause': 'expiry'},
        ),
      );
      expect(
        recorder
            .whereOp(SchedulerOp.paused)
            .map((event) => event.fields['reason']),
        ['systemInterrupted', 'systemInterrupted'],
      );

      lifecycle.emit(AppLifecycleState.resumed);
      expect(h.runner.isRunning(a), isTrue);
      expect(h.runner.isRunning(b), isTrue);
      expect(envelope.starts, hasLength(2));
    });

    test('holds a tracked download at its last receiving value', () async {
      final d = await DownloadsHarness.open(
        lifecycle: lifecycle,
        envelope: envelope,
      );
      d.transfers.download(photo, durability: TransferDurability.system);
      await d.settle();
      await d.step();
      expect(d.valueOf(photo), const AssetTransfer.receiving(100, 400));
      lifecycle.emit(AppLifecycleState.hidden);
      envelope.emit(const TransferEnvelopeEvent.systemEnded());
      expect(
        (await d.jobOf(photo))!.state,
        isA<TransferState$Paused>().having(
          (state) => state.reason,
          'reason',
          PauseReason.systemInterrupted,
        ),
      );
      expect(d.valueOf(photo), const AssetTransfer.receiving(100, 400));
    });
  });

  group('cancel all', () {
    test('removes every job in the envelope', () async {
      final h = await open();
      final a = h.addUpload();
      final b = h.addUpload();
      final local = h.addUpload(durability: TransferDurability.inProcess);
      final seen = <List<TransferId>>[];
      h.transfers.watch().listen(
        (jobs) => seen.add([for (final job in jobs) job.id]),
      );
      await pumpEventQueue();

      envelope.emit(const TransferEnvelopeEvent.userCancelledAll());
      await pumpEventQueue();

      expect(seen.last, [local]);
      expect(h.runner.isRunning(a), isFalse);
      expect(h.runner.isRunning(b), isFalse);
      expect(
        recorder.whereOp(EnvelopeOp.userCancelledAll).single,
        isMpxEvent(level: MpxEventLevel.info, jobId: a, fields: {'jobs': 2}),
      );
      expect(
        recorder
            .whereOp(SchedulerOp.cancelled)
            .map((event) => event.fields['by']),
        ['envelope', 'envelope'],
      );
      expect(envelope.stops, 0, reason: 'the user already ended it');
    });
  });

  test('a notification tap reaches the host with the job id', () async {
    final h = await open();
    final id = h.addUpload();
    final taps = <TransferId>[];
    h.transfers.notificationTaps.listen(taps.add);
    envelope.emit(TransferEnvelopeEvent.notificationTap(id));
    await pumpEventQueue();
    expect(taps, [id]);
    expect(
      recorder.whereOp(EnvelopeOp.notificationTap).single,
      isMpxEvent(level: MpxEventLevel.info, jobId: id),
    );
  });

  group('restart', () {
    test('a journaled handle with no live envelope resumes the job in a new '
        'one', () async {
      final h = await open();
      final id = h.addUpload(total: 10);
      await pumpEventQueue();
      await h.settle();
      envelope.leftovers.clear();
      await h.kill();

      expect(h.runner.isRunning(id), isTrue);
      expect(envelope.adopted, isEmpty);
      expect(envelope.starts, hasLength(2));
      expect(envelope.starts.last.jobs, {id});
    });

    test(
      'a journaled handle the native part still holds is taken over',
      () async {
        final h = await open();
        final id = h.addUpload(total: 10);
        await pumpEventQueue();
        await h.settle();
        await h.kill();

        expect(envelope.adopted, ['fake-1']);
        expect(envelope.starts, hasLength(1));
        expect(envelope.current!.jobs, {id});
        expect(recorder.whereOp(EnvelopeOp.started).last.fields, {
          'handle': 'fake-1',
          'adopted': true,
        });
        expect(h.transfers.debugSnapshot().envelope!.handle, 'fake-1');
      },
    );

    test('a live envelope no job names is stopped', () async {
      envelope.leftovers.add('stale');
      await open();
      expect(envelope.stops, 1);
    });

    test('after a force stop system uploads resume and an auto download '
        'waits', () async {
      final h = await open();
      final up = h.addUpload();
      final down = h.addDownload(photo, resumeOnStart: false);
      await h.settle();
      await h.kill();
      expect(h.runner.isRunning(up), isTrue);
      expect(
        await stateOf(h.transfers, down),
        const TransferState.paused(reason: PauseReason.awaitingResume),
      );
    });
  });

  group('simulated system interruption', () {
    test('pauses the jobs and stops the live envelope', () async {
      final h = await open();
      final a = h.addUpload();
      h.addUpload(durability: TransferDurability.inProcess);
      await pumpEventQueue();

      expect(h.transfers.debugSimulateSystemInterruption(), 1);
      expect(
        await stateOf(h.transfers, a),
        const TransferState.paused(reason: PauseReason.systemInterrupted),
      );
      expect(envelope.stops, 1);
      expect(
        recorder.whereOp(EnvelopeOp.systemEnded).single.fields['cause'],
        'simulated',
      );
      expect(h.transfers.debugSnapshot().envelope!.endedBySystem, 1);
    });

    test('pauses system jobs where there is no envelope', () async {
      final h = await open(withEnvelope: false);
      final id = h.addUpload();
      expect(h.transfers.debugSimulateSystemInterruption(), 1);
      expect(
        await stateOf(h.transfers, id),
        const TransferState.paused(reason: PauseReason.systemInterrupted),
      );
    });
  });

  test('debugSnapshot has the envelope section', () async {
    final h = await open();
    expect(
      h.transfers.debugSnapshot().envelope!.state,
      EnvelopeDebugState.idle,
    );
    final id = h.addUpload();
    expect(
      h.transfers.debugSnapshot().envelope!.state,
      EnvelopeDebugState.starting,
    );
    await pumpEventQueue();
    final due = DateTime.utc(2026, 1, 1);
    envelope.emit(
      TransferEnvelopeEvent.changed(
        kind: TransferEnvelopeKind.bgTask,
        submitDueAt: due,
      ),
    );
    final snapshot = h.transfers.debugSnapshot().envelope!;
    expect(snapshot.state, EnvelopeDebugState.started);
    expect(snapshot.handle, 'fake-1');
    expect(snapshot.kind, TransferEnvelopeKind.bgTask);
    expect(snapshot.jobs, {id});
    expect(snapshot.rule, TransferEnvelopeStartRule.always);
    expect(snapshot.submitAt, const TransferEnvelopeSubmitAt.afterDelay());
    expect(snapshot.submitDueAt, due);
    expect(snapshot.started, 1);
    expect(
      (await open(withEnvelope: false)).transfers.debugSnapshot().envelope,
      isNull,
    );
  });

  test('the submission waits 10 s after leaving the foreground by default', () {
    expect(
      const TransferEnvelopeConfig(title: 't').submitAt,
      const TransferEnvelopeSubmitAt.afterDelay(Duration(seconds: 10)),
    );
  });

  test(
    'downloads are in process by default; a host raises one to system',
    () async {
      final d = await DownloadsHarness.open(
        lifecycle: lifecycle,
        envelope: envelope,
      );
      final plain = d.transfers.download(photo);
      final raised = d.transfers.download(
        video,
        durability: TransferDurability.system,
      );
      final jobs = {
        for (final job in await jobsOf(d.transfers)) job.id: job.durability,
      };
      expect(jobs[plain], TransferDurability.inProcess);
      expect(jobs[raised], TransferDurability.system);
      expect(envelope.starts.single.jobs, {raised});
    },
  );

  test('no envelope event carries a path or a tag', () async {
    final h = await open();
    h.addUpload(tag: 'chat:1:m');
    await pumpEventQueue();
    envelope.emit(const TransferEnvelopeEvent.userCancelledAll());
    for (final event in recorder.whereCategory('envelope')) {
      for (final value in event.fields.values) {
        expect('$value', isNot(contains('/')));
        expect('$value', isNot(contains('chat:')));
      }
    }
  });
}
