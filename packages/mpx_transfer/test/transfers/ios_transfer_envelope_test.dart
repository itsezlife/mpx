import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_transfer/mpx_transfer.dart';

import '../support.dart';

const _channel = MethodChannel('test.mpx.transfer/envelope');

const TransferId _a = TransferId.parse('u-a');
const TransferId _b = TransferId.parse('u-b');

TransferEnvelopeProgress _progress(
  int done, {
  int? total = 100,
  Set<TransferId>? jobs,
}) => TransferEnvelopeProgress(jobs: jobs ?? {_a}, done: done, total: total);

const _config = TransferEnvelopeConfig(title: 'Sending', text: '2 files');

/// The native part on script: what each call answers, and every call made.
final class _Native {
  _Native() {
    _messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'attach' => attach,
        'arm' => {'handle': 'ios-${++_handles}', ...arm},
        'submit' => submit,
        _ => null,
      };
    });
    addTearDown(() => _messenger.setMockMethodCallHandler(_channel, null));
  }

  static TestDefaultBinaryMessenger get _messenger =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final List<MethodCall> calls = [];
  int _handles = 0;

  Map<String, Object?> attach = {'foreground': true, 'continued': true};
  Map<String, Object?> arm = {'foreground': true};
  Map<String, Object?> submit = {'submitted': true};

  List<MethodCall> named(String method) => [
    for (final call in calls)
      if (call.method == method) call,
  ];

  /// Sends [method] to the Dart side as the native part would.
  void send(String method, [Map<String, Object?> args = const {}]) {
    unawaited(
      _messenger.handlePlatformMessage(
        _channel.name,
        _channel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingDiagnostics recorder;
  late _Native native;

  setUp(() {
    recorder = RecordingDiagnostics.install();
    native = _Native();
  });

  /// An envelope started over [_a] in a fake-async zone at time zero.
  ({IosTransferEnvelope envelope, List<TransferEnvelopeEvent> events})
  startedIn(
    FakeAsync async, {
    TransferEnvelopeConfig config = _config,
    TransferEnvelopeProgress? progress,
  }) {
    final start = DateTime.utc(2026);
    final envelope = IosTransferEnvelope(
      channel: _channel,
      now: () => start.add(async.elapsed),
    );
    final events = <TransferEnvelopeEvent>[];
    envelope.events.listen(events.add);
    unawaited(envelope.start(progress ?? _progress(0), config));
    async.flushMicrotasks();
    return (envelope: envelope, events: events);
  }

  void background(FakeAsync async, {String? kind = 'bgTask'}) {
    native
      ..send('lifecycle', {'state': 'resignActive'})
      ..send('lifecycle', {'state': 'background', 'kind': ?kind});
    async.flushMicrotasks();
  }

  test('pins the defaults: submit 10 s after backgrounding, push every '
      'second, a 2 MiB native ring, armed for every system job', () {
    expect(
      const TransferEnvelopeConfig(title: 'x').submitAt,
      const TransferEnvelopeSubmitAt.afterDelay(Duration(seconds: 10)),
    );
    expect(
      IosTransferEnvelope.defaultProgressInterval,
      const Duration(seconds: 1),
    );
    expect(IosTransferEnvelope.defaultNativeLogBytes, 2 * 1024 * 1024);
    final envelope = IosTransferEnvelope(channel: _channel);
    expect(envelope.progressInterval, const Duration(seconds: 1));
    expect(envelope.nativeLogBytes, 2 * 1024 * 1024);
    expect(envelope.startRule, TransferEnvelopeStartRule.always);
    expect(
      IosTransferEnvelope.defaultChannel.name,
      'dev.mpx.transfer/envelope',
    );
  });

  test('a start attaches once, arms and answers the handle with nothing '
      'holding the process in the foreground', () async {
    final envelope = IosTransferEnvelope(channel: _channel);
    expect(await envelope.live(), isEmpty);
    final answer = await envelope.start(_progress(0), _config);
    expect(answer, const TransferEnvelopeStart.started('ios-1'));
    expect([for (final call in native.calls) call.method], ['attach', 'arm']);
    expect(native.calls.first.arguments, {'logBytes': 2 * 1024 * 1024});
  });

  test('without a native part nothing is live and a start is refused '
      'platform', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    final envelope = IosTransferEnvelope(channel: _channel);
    expect(await envelope.live(), isEmpty);
    expect(
      await envelope.start(_progress(0), _config),
      const TransferEnvelopeStart.refused('platform'),
    );
  });

  group('afterDelay (default)', () {
    test('the background task begins at backgrounding and the '
        'continued-processing task is submitted 10 s later', () {
      fakeAsync((async) {
        final (:envelope, :events) = startedIn(async);
        background(async);

        expect(
          recorder.whereOp(EnvelopeOp.started).single,
          isMpxEvent(
            level: MpxEventLevel.info,
            fields: {'kind': 'bgTask', 'handle': 'ios-1'},
          ),
        );
        expect(events, [
          TransferEnvelopeEvent.changed(
            kind: TransferEnvelopeKind.bgTask,
            submitDueAt: DateTime.utc(2026).add(const Duration(seconds: 10)),
          ),
        ]);

        async.elapse(const Duration(milliseconds: 9999));
        expect(native.named('submit'), isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(native.named('submit').single.arguments, {
          'handle': 'ios-1',
          'title': 'Sending',
          'subtitle': '2 files',
        });
        expect(envelope.startRule, TransferEnvelopeStartRule.always);
      });
    });

    test('no submission when the jobs drained before the delay', () {
      fakeAsync((async) {
        final (:envelope, events: _) = startedIn(async);
        background(async);
        async.elapse(const Duration(seconds: 5));
        envelope.stop();
        async.elapse(const Duration(seconds: 20));
        expect(native.named('submit'), isEmpty);
        expect(native.named('disarm'), hasLength(1));
      });
    });

    test('no submission when the app is back in the foreground before '
        'the delay; the next background starts the delay again', () {
      fakeAsync((async) {
        final (envelope: _, :events) = startedIn(async);
        background(async);
        async.elapse(const Duration(seconds: 4));
        native.send('lifecycle', {'state': 'active'});
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 20));
        expect(native.named('submit'), isEmpty);
        expect(native.named('withdraw'), hasLength(1));
        expect(
          recorder.whereOp(EnvelopeOp.withdrawn).single,
          isMpxEvent(fields: {'kind': 'bgTask', 'why': 'foreground'}),
        );
        expect(events.last, const TransferEnvelopeEvent.changed());

        background(async);
        async.elapse(const Duration(seconds: 10));
        expect(native.named('submit'), hasLength(1));
      });
    });
  });

  test('onResignActive submits at once, before the app is in the '
      'background', () {
    fakeAsync((async) {
      startedIn(
        async,
        config: const TransferEnvelopeConfig(
          title: 'Sending',
          submitAt: TransferEnvelopeSubmitAt.onResignActive(),
        ),
      );
      native.send('lifecycle', {'state': 'resignActive'});
      async.flushMicrotasks();
      expect(native.named('submit').single.arguments, {
        'handle': 'ios-1',
        'title': 'Sending',
        'subtitle': '',
      });
      native.send('lifecycle', {'state': 'background', 'kind': 'bgTask'});
      async
        ..flushMicrotasks()
        ..elapse(const Duration(seconds: 30));
      expect(native.named('submit'), hasLength(1));
    });
  });

  test('a start in the background with onResignActive submits at once', () {
    fakeAsync((async) {
      native.arm = {'foreground': false, 'kind': 'bgTask'};
      final envelope = IosTransferEnvelope(channel: _channel);
      TransferEnvelopeStart? answer;
      unawaited(
        envelope
            .start(
              _progress(0),
              const TransferEnvelopeConfig(
                title: 'Sending',
                submitAt: TransferEnvelopeSubmitAt.onResignActive(),
              ),
            )
            .then((value) => answer = value),
      );
      async.flushMicrotasks();
      expect(
        answer,
        const TransferEnvelopeStart.started(
          'ios-1',
          kind: TransferEnvelopeKind.bgTask,
        ),
      );
      expect(native.named('submit'), hasLength(1));
      // The engine reports the kind a start answers.
      expect(recorder.whereOp(EnvelopeOp.started), isEmpty);
    });
  });

  group('continued-processing task', () {
    test('pushes progress at once and then every second it changed, never '
        'lower, with the config text', () {
      fakeAsync((async) {
        final (:envelope, :events) = startedIn(
          async,
          config: TransferEnvelopeConfig(
            title: 'Sending',
            progressText: (p) => '${p.jobs.length} files',
          ),
          progress: _progress(10),
        );
        background(async);
        async.elapse(const Duration(seconds: 10));
        native.send('held', {'handle': 'ios-1', 'kind': 'continuedProcessing'});
        async.flushMicrotasks();

        expect(
          recorder.whereOp(EnvelopeOp.started).last,
          isMpxEvent(
            fields: {'kind': 'continuedProcessing', 'handle': 'ios-1'},
          ),
        );
        expect(
          events.last,
          const TransferEnvelopeEvent.changed(
            kind: TransferEnvelopeKind.continuedProcessing,
          ),
        );
        expect(native.named('progress').single.arguments, {
          'handle': 'ios-1',
          'fraction': 0.1,
          'subtitle': '1 files',
        });

        async.elapse(const Duration(seconds: 1));
        expect(native.named('progress'), hasLength(1), reason: 'unchanged');

        envelope.update(_progress(30, total: 200, jobs: {_a, _b}));
        async.elapse(const Duration(milliseconds: 999));
        expect(native.named('progress'), hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(native.named('progress').last.arguments, {
          'handle': 'ios-1',
          'fraction': 0.15,
          'subtitle': '2 files',
        });

        // A job joined: 40 of 400 is lower than shown, so the shown stays.
        envelope.update(
          _progress(
            40,
            total: 400,
            jobs: {_a, _b, const TransferId.parse('u-c')},
          ),
        );
        async.elapse(const Duration(seconds: 1));
        expect(native.named('progress').last.arguments, {
          'handle': 'ios-1',
          'fraction': 0.15,
          'subtitle': '3 files',
        });

        envelope.update(_progress(50, total: null));
        async.elapse(const Duration(seconds: 1));
        expect(native.named('progress').last.arguments, {
          'handle': 'ios-1',
          'fraction': null,
          'subtitle': '1 files',
        });

        expect(
          [
            for (final event in recorder.whereOp(EnvelopeOp.progressPushed))
              event.fields,
          ],
          [
            {'fraction': 0.1, 'jobs': 1},
            {'fraction': 0.15, 'jobs': 2},
            {'fraction': 0.15, 'jobs': 3},
            {'jobs': 1},
          ],
        );
        expect(
          recorder.whereOp(EnvelopeOp.progressPushed).first.level,
          MpxEventLevel.trace,
        );
      });
    });

    test('is withdrawn in the foreground, and pushing stops', () {
      fakeAsync((async) {
        final (:envelope, :events) = startedIn(async);
        background(async);
        async.elapse(const Duration(seconds: 10));
        native.send('held', {'handle': 'ios-1', 'kind': 'continuedProcessing'});
        async.flushMicrotasks();
        native.send('lifecycle', {'state': 'active'});
        async.flushMicrotasks();

        expect(native.named('withdraw').single.arguments, isNull);
        expect(
          recorder.whereOp(EnvelopeOp.withdrawn).single,
          isMpxEvent(
            level: MpxEventLevel.info,
            fields: {'kind': 'continuedProcessing', 'why': 'foreground'},
          ),
        );
        expect(events.last, const TransferEnvelopeEvent.changed());
        final pushes = native.named('progress').length;
        envelope.update(_progress(90));
        async.elapse(const Duration(seconds: 5));
        expect(native.named('progress'), hasLength(pushes));
      });
    });

    test('a submission still waiting for its task is withdrawn too', () {
      fakeAsync((async) {
        startedIn(async);
        background(async);
        async.elapse(const Duration(seconds: 10));
        native.send('lifecycle', {'state': 'active'});
        async.flushMicrotasks();
        expect(native.named('withdraw'), hasLength(1));
      });
    });

    test('the system ending it pauses the jobs (systemEnded), whatever '
        'ended it', () {
      fakeAsync((async) {
        final (envelope: _, :events) = startedIn(async);
        background(async);
        async.elapse(const Duration(seconds: 10));
        native
          ..send('held', {'handle': 'ios-1', 'kind': 'continuedProcessing'})
          ..send('event', {
            'type': 'systemEnded',
            'handle': 'ios-1',
            'cause': 'stop',
          });
        async.flushMicrotasks();
        expect(
          events.last,
          const TransferEnvelopeEvent.systemEnded(
            cause: TransferEnvelopeEndCause.stop,
          ),
        );

        // Disarmed: later calls about that envelope change nothing.
        final count = events.length;
        native
          ..send('event', {
            'type': 'systemEnded',
            'handle': 'ios-1',
            'cause': 'expiry',
          })
          ..send('lifecycle', {'state': 'active'});
        async
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 5));
        expect(events, hasLength(count));
        expect(native.named('withdraw'), isEmpty);
        expect(native.named('progress'), hasLength(1));
      });
    });
  });

  test('a refused submission degrades to the background task, then its '
      'end pauses the jobs', () {
    fakeAsync((async) {
      native.submit = {'submitted': false, 'code': 'immediateRunIneligible'};
      final (envelope: _, :events) = startedIn(async);
      background(async);
      async.elapse(const Duration(seconds: 10));

      expect(
        recorder.whereOp(EnvelopeOp.refused).single,
        isMpxEvent(
          level: MpxEventLevel.warning,
          fields: {
            'kind': 'continuedProcessing',
            'code': 'immediateRunIneligible',
          },
        ),
      );
      expect(
        recorder.whereOp(EnvelopeOp.degraded).single,
        isMpxEvent(
          level: MpxEventLevel.warning,
          fields: {
            'from': 'continuedProcessing',
            'to': 'bgTask',
            'why': 'submitFailed',
          },
        ),
      );
      expect(
        events.last,
        const TransferEnvelopeEvent.changed(kind: TransferEnvelopeKind.bgTask),
      );

      // Asked once per background.
      async.elapse(const Duration(seconds: 30));
      expect(native.named('submit'), hasLength(1));

      native.send('event', {
        'type': 'systemEnded',
        'handle': 'ios-1',
        'cause': 'expiry',
      });
      async.flushMicrotasks();
      expect(
        events.last,
        const TransferEnvelopeEvent.systemEnded(
          cause: TransferEnvelopeEndCause.expiry,
        ),
      );
    });
  });

  test('a submission that throws is refused with code error', () {
    fakeAsync((async) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(_channel, (call) async {
        native.calls.add(call);
        return switch (call.method) {
          'attach' => native.attach,
          'arm' => {'handle': 'ios-1', 'foreground': true},
          'submit' => throw PlatformException(code: 'boom', message: '/x'),
          _ => null,
        };
      });
      startedIn(async);
      background(async);
      async.elapse(const Duration(seconds: 10));
      final refused = recorder.whereOp(EnvelopeOp.refused).single;
      expect(refused.fields, {'kind': 'continuedProcessing', 'code': 'error'});
      expect(refused.error, isNull);
      expect(recorder.whereOp(EnvelopeOp.degraded), hasLength(1));
    });
  });

  test('below iOS 26 the background task alone holds the process', () {
    fakeAsync((async) {
      native.attach = {'foreground': true, 'continued': false};
      final (envelope: _, :events) = startedIn(async);
      background(async);
      async.elapse(const Duration(minutes: 1));
      expect(native.named('submit'), isEmpty);
      expect(
        events.single,
        const TransferEnvelopeEvent.changed(kind: TransferEnvelopeKind.bgTask),
      );
      expect(
        recorder.whereOp(EnvelopeOp.started).single.fields['kind'],
        'bgTask',
      );
    });
  });

  test('a background task the system would not give is reported refused', () {
    fakeAsync((async) {
      native.attach = {'foreground': true, 'continued': false};
      startedIn(async);
      native.send('lifecycle', {'state': 'background', 'refused': 'invalid'});
      async.flushMicrotasks();
      expect(
        recorder.whereOp(EnvelopeOp.refused).single,
        isMpxEvent(
          level: MpxEventLevel.warning,
          fields: {'kind': 'bgTask', 'code': 'invalid'},
        ),
      );
      expect(recorder.whereOp(EnvelopeOp.started), isEmpty);
    });
  });

  test('native records kept while detached are emitted with their time and '
      'native: true, then nativeMerged', () async {
    final now = DateTime.utc(2026, 1, 1, 12);
    native.attach = {
      'foreground': true,
      'continued': true,
      'records': [
        {
          'time': now
              .subtract(const Duration(seconds: 90))
              .millisecondsSinceEpoch,
          'level': 'info',
          'op': 'started',
          'fields': {'kind': 'bgTask', 'handle': 'ios-7'},
        },
        {
          'time': now
              .subtract(const Duration(seconds: 60))
              .millisecondsSinceEpoch,
          'level': 'warning',
          'op': 'systemEnded',
          'fields': {'kind': 'bgTask', 'cause': 'expiry', 'remainingS': 0},
        },
        {'time': 0, 'level': 'info', 'op': 'noSuchOp'},
      ],
    };
    final envelope = IosTransferEnvelope(channel: _channel, now: () => now);
    expect(await envelope.live(), isEmpty);

    final started = recorder.whereOp(EnvelopeOp.started).single;
    expect(
      started.time.isAtSameMomentAs(now.subtract(const Duration(seconds: 90))),
      isTrue,
    );
    expect(started.fields, {
      'kind': 'bgTask',
      'handle': 'ios-7',
      'native': true,
    });
    final ended = recorder.whereOp(EnvelopeOp.systemEnded).single;
    expect(ended.level, MpxEventLevel.warning);
    expect(ended.fields['native'], true);
    expect(
      recorder.whereOp(EnvelopeOp.nativeMerged).single,
      isMpxEvent(
        level: MpxEventLevel.info,
        fields: {'records': 2, 'oldestAgeS': 90},
      ),
    );
    expect(recorder.events.last.op, EnvelopeOp.nativeMerged);
  });

  test('an envelope the native part still holds is live and adopted', () {
    fakeAsync((async) {
      native.attach = {
        'foreground': false,
        'continued': true,
        'live': ['ios-9'],
        'kind': 'bgTask',
      };
      final envelope = IosTransferEnvelope(channel: _channel);
      Set<String>? live;
      unawaited(envelope.live().then((value) => live = value));
      async.flushMicrotasks();
      expect(live, {'ios-9'});
      envelope.adopt('ios-9', _progress(0), _config);
      async.elapse(const Duration(seconds: 10));
      expect(native.named('submit').single.arguments, {
        'handle': 'ios-9',
        'title': 'Sending',
        'subtitle': '2 files',
      });
    });
  });

  test('through the engine: a system job arms it, and the end of the '
      'background task pauses the job systemInterrupted', () async {
    final lifecycle = ManualPlaybackLifecycleSource(
      initial: AppLifecycleState.resumed,
    );
    final envelope = IosTransferEnvelope(channel: _channel);
    final h = await harness(lifecycle: lifecycle, envelope: envelope);
    final id = h.addUpload(total: 10);
    await pumpEventQueue();
    expect(native.named('arm'), hasLength(1));
    expect(
      recorder.whereOp(EnvelopeOp.started).single,
      isMpxEvent(fields: {'handle': 'ios-1', 'adopted': false}),
    );

    lifecycle.emit(AppLifecycleState.hidden);
    native
      ..send('lifecycle', {'state': 'background', 'kind': 'bgTask'})
      ..send('event', {
        'type': 'systemEnded',
        'handle': 'ios-1',
        'cause': 'expiry',
      });
    await pumpEventQueue();

    expect(
      await stateOf(h.transfers, id),
      const TransferState.paused(
        reason: PauseReason.systemInterrupted,
        total: 10,
      ),
    );
    expect(
      recorder.whereOp(EnvelopeOp.systemEnded).single,
      isMpxEvent(
        level: MpxEventLevel.warning,
        jobId: id,
        fields: {'jobs': 1, 'cause': 'expiry'},
      ),
    );
  });
}
