import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';
import 'package:mpx_transfer/testing.dart';

import '../support.dart';

const int _mib = 1024 * 1024;
const MethodChannel _channel = AndroidTransferEnvelope.defaultChannel;

/// The plugin's native side as the channel shows it: records every call and
/// answers attach and start as a test sets.
final class _FakeNative {
  final List<MethodCall> calls = [];
  List<Map<String, Object?>> records = [];
  List<String> live = [];
  Map<String, Object?> startAnswer = {'handle': 'android-1', 'kind': 'uidt'};
  PlatformException? startError;

  List<String> get methods => [for (final call in calls) call.method];

  Map<Object?, Object?> argumentsOf(String method) =>
      calls.lastWhere((call) => call.method == method).arguments
          as Map<Object?, Object?>;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'attach':
        return {'records': records, 'live': live};
      case 'start':
        if (startError case final error?) throw error;
        return startAnswer;
    }
    return null;
  }

  /// Sends [method] from the native side to Dart.
  Future<void> send(String method, Map<String, Object?> arguments) {
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _channel.name,
          _channel.codec.encodeMethodCall(MethodCall(method, arguments)),
          (_) => done.complete(),
        );
    return done.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingDiagnostics recorder;
  late _FakeNative native;
  late AndroidTransferEnvelope envelope;
  final now = DateTime.utc(2026, 11, 28, 12);

  setUp(() {
    recorder = RecordingDiagnostics.install();
    native = _FakeNative();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, native.handle);
    envelope = AndroidTransferEnvelope(now: () => now);
    addTearDown(() async {
      await envelope.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });
  });

  Future<TransfersHarness> open({
    TransferEnvelopeConfig config = const TransferEnvelopeConfig(
      title: 'Sending',
    ),
  }) async {
    final h = await harness(
      lifecycle: ManualPlaybackLifecycleSource(
        initial: AppLifecycleState.resumed,
      ),
      envelope: envelope,
      envelopeConfig: config,
    );
    // The harness opens without reading live handles; the engine's open
    // does, so attach as it would.
    await envelope.live();
    return h;
  }

  group('rule', () {
    test('the platform rule is long, the ring 2 MiB, sent at attach', () async {
      expect(envelope.startRule, TransferEnvelopeStartRule.long);
      expect(AndroidTransferEnvelope.defaultNativeLogBytes, 2 * _mib);
      expect(envelope.nativeLogBytes, 2 * _mib);
      await envelope.live();
      expect(native.methods, ['attach']);
      expect(native.argumentsOf('attach'), {'logBytes': 2 * _mib});
    });

    test('a job of 10 MiB runs in process, one byte more starts it', () async {
      final h = await open();
      h.addUpload(total: 10 * _mib);
      await pumpEventQueue();
      expect(native.methods, isNot(contains('start')));

      final long = h.addUpload(total: 10 * _mib + 1);
      await pumpEventQueue();
      expect(native.methods.where((m) => m == 'start'), hasLength(1));
      expect(native.argumentsOf('start')['jobs'], contains(long));
    });

    test('always starts it for a short job', () async {
      final always = await open(
        config: const TransferEnvelopeConfig(
          title: 't',
          startRule: TransferEnvelopeStartRule.always,
        ),
      );
      always.addUpload(total: 1);
      await pumpEventQueue();
      expect(native.methods, contains('start'));
    });

    test('never starts none, not even for a long job', () async {
      final h = await open(
        config: const TransferEnvelopeConfig(
          title: 't',
          startRule: TransferEnvelopeStartRule.never,
        ),
      );
      h.addUpload(total: 100 * _mib);
      await pumpEventQueue();
      expect(native.methods, ['attach']);
    });
  });

  group('calls', () {
    test('start sends the config and the progress, update mirrors it, a '
        'drain stops it', () async {
      final h = await open(
        config: TransferEnvelopeConfig(
          title: 'Sending',
          text: 'Your files',
          cancelAllLabel: 'Cancel all',
          icon: 'ic_upload',
          progressText: (progress) => '${progress.jobs.length} files',
        ),
      );
      final id = h.addUpload(total: 20 * _mib);
      await pumpEventQueue();
      expect(native.argumentsOf('start'), {
        'jobs': [id],
        'shownJob': id,
        'done': 0,
        'total': 20 * _mib,
        'title': 'Sending',
        'text': 'Your files',
        'cancelAllLabel': 'Cancel all',
        'progressText': '1 files',
        'icon': 'ic_upload',
      });
      expect(recorder.whereOp(EnvelopeOp.started).single.fields, {
        'handle': 'android-1',
        'kind': 'uidt',
        'adopted': false,
      });

      h.runner.progress(id, 5 * _mib, total: 20 * _mib);
      await pumpEventQueue();
      expect(native.argumentsOf('update')['done'], 5 * _mib);
      expect(native.argumentsOf('update')['progressText'], '1 files');

      h.runner.complete(id, const FakeTransferResult('a'));
      await pumpEventQueue();
      expect(native.methods.last, 'stop');
      expect(
        recorder.whereOp(EnvelopeOp.withdrawn).single.fields['why'],
        'drained',
      );
    });

    test(
      'calls reach the native side in the order the engine made them',
      () async {
        final h = await open();
        final id = h.addUpload(total: 20 * _mib);
        h.runner.complete(id, const FakeTransferResult('a'));
        await pumpEventQueue();
        expect(native.methods, ['attach', 'start', 'stop']);
      },
    );

    test(
      'a refusal runs the job in process with one degraded warning',
      () async {
        native.startAnswer = {'refused': 'securityException'};
        final h = await open();
        final id = h.addUpload(total: 20 * _mib);
        await pumpEventQueue();
        expect(
          recorder.whereOp(EnvelopeOp.refused).single,
          isMpxEvent(
            level: MpxEventLevel.warning,
            fields: {'code': 'securityException'},
          ),
        );
        expect(
          recorder.whereOp(EnvelopeOp.degraded).single,
          isMpxEvent(
            level: MpxEventLevel.warning,
            jobId: id,
            fields: {'from': 'system', 'to': 'inProcess', 'why': 'refused'},
          ),
        );
        expect(h.runner.isRunning(id), isTrue);
        expect(
          h.transfers.debugSnapshot().envelope!.state,
          EnvelopeDebugState.idle,
        );
      },
    );

    test('a platform error or no plugin is a refusal with its code', () async {
      native.startError = PlatformException(code: 'boom');
      expect(
        await envelope.start(
          const TransferEnvelopeProgress(jobs: {}, done: 0),
          const TransferEnvelopeConfig(title: 't'),
        ),
        const TransferEnvelopeStart.refused('boom'),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      expect(
        await envelope.start(
          const TransferEnvelopeProgress(jobs: {}, done: 0),
          const TransferEnvelopeConfig(title: 't'),
        ),
        const TransferEnvelopeStart.refused('platform'),
      );
    });

    test('live answers the handles the native side still holds', () async {
      native.live = ['android-9'];
      expect(await envelope.live(), {'android-9'});
    });
  });

  group('native events', () {
    test('a system end pauses the jobs inside with its cause', () async {
      final h = await open();
      final id = h.addUpload(total: 20 * _mib);
      await pumpEventQueue();
      await native.send('event', {'type': 'systemEnded', 'cause': 'timeLimit'});
      expect(
        recorder.whereOp(EnvelopeOp.systemEnded).single,
        isMpxEvent(
          level: MpxEventLevel.warning,
          jobId: id,
          fields: {'jobs': 1, 'cause': 'timeLimit'},
        ),
      );
      expect(
        await stateOf(h.transfers, id),
        isA<TransferState$Paused>().having(
          (state) => state.reason,
          'reason',
          PauseReason.systemInterrupted,
        ),
      );
    });

    test('cancel all cancels the jobs inside', () async {
      final h = await open();
      final id = h.addUpload(total: 20 * _mib);
      await pumpEventQueue();
      await native.send('event', {'type': 'userCancelledAll'});
      expect(recorder.whereOp(EnvelopeOp.userCancelledAll).single.fields, {
        'jobs': 1,
      });
      expect(await stateOf(h.transfers, id), isNull);
    });

    test("a tap reaches notificationTaps with the job's id", () async {
      final h = await open();
      final id = h.addUpload(total: 20 * _mib);
      final taps = <TransferId>[];
      final subscription = h.transfers.notificationTaps.listen(taps.add);
      addTearDown(subscription.cancel);
      await native.send('event', {'type': 'notificationTap', 'job': id});
      expect(taps, [id]);
      expect(
        recorder.whereOp(EnvelopeOp.notificationTap).single,
        isMpxEvent(level: MpxEventLevel.info, jobId: id),
      );
    });

    test('an event before the engine listens is kept for it', () async {
      await native.send('event', {'type': 'notificationTap', 'job': 'j-1'});
      final events = <TransferEnvelopeEvent>[];
      final subscription = envelope.events.listen(events.add);
      addTearDown(subscription.cancel);
      expect(events, [
        const TransferEnvelopeEvent.notificationTap(TransferId.parse('j-1')),
      ]);
    });

    test('a native record is reported as it is', () async {
      await native.send('record', {
        'time': now.millisecondsSinceEpoch,
        'level': 'trace',
        'op': 'progressPushed',
        'jobId': 'j-1',
        'fields': {'jobs': 2, 'fraction': 0.5},
      });
      expect(
        recorder.whereOp(EnvelopeOp.progressPushed).single,
        isMpxEvent(
          level: MpxEventLevel.trace,
          category: 'envelope',
          jobId: 'j-1',
          fields: {'jobs': 2, 'fraction': 0.5},
        ),
      );
    });

    test('the ring is merged at attach with its times and native, then '
        'nativeMerged', () async {
      final oldest = now.subtract(const Duration(minutes: 5));
      native.records = [
        {
          'time': oldest.millisecondsSinceEpoch,
          'level': 'warning',
          'op': 'systemEnded',
          'jobId': null,
          'fields': {'cause': 'lowMemory', 'processEnded': true},
        },
        {
          'time': now
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch,
          'level': 'info',
          'op': 'withdrawn',
          'jobId': 'j-1',
          'fields': {'why': 'detached'},
        },
      ];
      await envelope.live();
      final ended = recorder.whereOp(EnvelopeOp.systemEnded).single;
      expect(ended.time, oldest.toLocal());
      expect(ended.fields, {
        'cause': 'lowMemory',
        'processEnded': true,
        'native': true,
      });
      expect(
        recorder.whereOp(EnvelopeOp.withdrawn).single,
        isMpxEvent(jobId: 'j-1', fields: {'why': 'detached', 'native': true}),
      );
      expect(
        recorder.whereOp(EnvelopeOp.nativeMerged).single,
        isMpxEvent(
          level: MpxEventLevel.info,
          fields: {'records': 2, 'oldestAgeS': 300},
        ),
      );
      expect(recorder.events.last.op, EnvelopeOp.nativeMerged);
    });

    test('an empty ring merges nothing', () async {
      await envelope.live();
      expect(recorder.whereOp(EnvelopeOp.nativeMerged), isEmpty);
    });
  });
}
