import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

enum _TestOp implements DiagnosticOp {
  queued,
  failed;

  @override
  String get category => 'test';
}

typedef _Line = ({
  String message,
  String name,
  int level,
  Object? error,
  StackTrace? stackTrace,
  DateTime? time,
});

void main() {
  // Every test of the process restores the policy it changes, so the
  // default is still in place here, wherever this file runs.
  test('the process-wide policy is silent by default', () {
    expect(MpxDiagnostics.current, isA<MpxDiagnosticsSilent>());
  });

  group('MpxDiagnostics.silent', () {
    MpxDiagnosticsContract.run(MpxDiagnostics.silent);

    test('is enabled at no level and builds no fields', () {
      const diagnostics = MpxDiagnostics.silent();
      expect(MpxEventLevel.values.any(diagnostics.isEnabled), isFalse);
      diagnostics.emit(
        MpxEventLevel.error,
        _TestOp.failed,
        fields: () => fail('a silent policy built fields'),
      );
    });
  });

  group('MpxDiagnostics.developer', () {
    MpxDiagnosticsContract.run(
      () => const MpxDiagnostics.developer(log: _noLog),
    );

    test('logs each event under mpx, led by its category and op', () {
      final lines = <_Line>[];
      final diagnostics = MpxDiagnostics.developer(
        log:
            (
              message, {
              required name,
              required level,
              error,
              stackTrace,
              time,
            }) => lines.add((
              message: message,
              name: name,
              level: level,
              error: error,
              stackTrace: stackTrace,
              time: time,
            )),
      );
      final error = StateError('boom');
      final stackTrace = StackTrace.current;
      final time = DateTime.utc(2026, 11, 27);

      diagnostics.report(
        MpxEvent(
          time: time,
          level: MpxEventLevel.warning,
          op: _TestOp.failed,
          jobId: 'j1',
          itemId: 'i1',
          mediaKey: const MediaKey.remote('k1'),
          tag: 't1',
          fields: const {'attempt': 2, 'retryable': true, 'code': 'timeout'},
          error: error,
          stackTrace: stackTrace,
        ),
      );

      expect(lines, hasLength(1));
      final line = lines.single;
      expect(line.name, 'mpx');
      expect(line.level, 900);
      expect(
        line.message,
        'test.failed jobId=j1 itemId=i1 '
        'mediaKey=${const MediaKey.remote('k1').encoded} tag=t1 '
        'attempt=2 retryable=true code=timeout',
      );
      expect(line.error, same(error));
      expect(line.stackTrace, same(stackTrace));
      expect(line.time, time);
    });
  });

  group('MpxDiagnostics.onEvent', () {
    MpxDiagnosticsContract.run(() => MpxDiagnostics.onEvent((_) {}));
    MpxDiagnosticsContract.run(
      () => MpxDiagnostics.onEvent((_) {}, minLevel: MpxEventLevel.warning),
    );
    MpxDiagnosticsContract.run(
      () => MpxDiagnostics.onEvent((_) => throw StateError('sink')),
    );

    test('hands the host every part of the event', () {
      final received = <MpxEvent>[];
      final diagnostics = MpxDiagnostics.onEvent(received.add);
      final error = ArgumentError('bad');
      final stackTrace = StackTrace.current;

      diagnostics.emit(
        MpxEventLevel.info,
        _TestOp.queued,
        jobId: 'j',
        itemId: 'i',
        mediaKey: const MediaKey.external('e'),
        tag: 'chat:1',
        fields: () => const {'bytes': 1024, 'ms': 12.5, 'lane': 'media'},
        error: error,
        stackTrace: stackTrace,
      );

      expect(
        received.single,
        isMpxEvent(
          level: MpxEventLevel.info,
          category: 'test',
          op: _TestOp.queued,
          jobId: 'j',
          itemId: 'i',
          mediaKey: const MediaKey.external('e'),
          tag: 'chat:1',
          fields: {'bytes': 1024, 'ms': 12.5, 'lane': 'media'},
          error: same(error),
        ),
      );
      expect(received.single.stackTrace, same(stackTrace));
    });

    test('forwards from its minimum level up', () {
      final received = <MpxEvent>[];
      final diagnostics = MpxDiagnostics.onEvent(
        received.add,
        minLevel: MpxEventLevel.warning,
      );
      for (final level in MpxEventLevel.values) {
        diagnostics.emit(level, _TestOp.queued);
      }
      expect(received.map((event) => event.level), [
        MpxEventLevel.warning,
        MpxEventLevel.error,
      ]);
      expect(diagnostics.isEnabled(MpxEventLevel.info), isFalse);
    });

    test('swallows a sink that throws', () {
      final diagnostics = MpxDiagnostics.onEvent(
        (_) => throw StateError('sink'),
      );
      expect(
        () => diagnostics.emit(MpxEventLevel.error, _TestOp.failed),
        returnsNormally,
      );
    });
  });

  group('MpxEvent', () {
    MpxEvent event(Map<String, Object> fields) => MpxEvent(
      time: DateTime.utc(2026),
      level: MpxEventLevel.debug,
      op: _TestOp.queued,
      fields: fields,
    );

    test('takes its category from its op', () {
      expect(event(const {}).category, 'test');
      expect(BindingOp.trackedDownload.category, 'binding');
      expect(BindingOp.values.map((op) => op.category).toSet(), {'binding'});
    });

    test('holds numbers, booleans and short strings only', () {
      expect(
        () => event(const {'n': 1, 'x': 0.5, 'b': false, 's': 'short'}),
        returnsNormally,
      );
      expect(
        () => event({'s': 'x' * (MpxEvent.maxStringFieldLength + 1)}),
        throwsAssertionError,
      );
      expect(() => event({'e': _TestOp.queued}), throwsAssertionError);
      expect(
        () => event({
          'l': const [1],
        }),
        throwsAssertionError,
      );
      expect(
        () => event({
          'm': const {'a': 1},
        }),
        throwsAssertionError,
      );
    });

    test('clip cuts a string to what a field holds', () {
      final long = 'y' * 100;
      expect(MpxEvent.clip(long), hasLength(MpxEvent.maxStringFieldLength));
      expect(MpxEvent.clip('short'), 'short');
      expect(() => event({'s': MpxEvent.clip(long)}), returnsNormally);
    });

    test('keeps a copy of its fields that cannot change', () {
      final fields = <String, Object>{'n': 1};
      final made = event(fields);
      fields['n'] = 2;
      expect(made.fields, {'n': 1});
      expect(() => made.fields['n'] = 3, throwsUnsupportedError);
    });

    test('is equal by value', () {
      expect(event(const {'n': 1}), event(const {'n': 1}));
      expect(event(const {'n': 1}).hashCode, event(const {'n': 1}).hashCode);
      expect(event(const {'n': 1}), isNot(event(const {'n': 2})));
    });
  });

  group('MpxTrace', () {
    test('is off without the mpx.trace define and only runs the body', () {
      expect(MpxTrace.enabled, isFalse);
      expect(MpxTrace.sync(_TestOp.queued, () => 7), 7);
    });

    test('runs an async body and passes its error on', () async {
      expect(await MpxTrace.async(_TestOp.queued, () async => 'done'), 'done');
      await expectLater(
        MpxTrace.async<void>(_TestOp.failed, () async => throw StateError('x')),
        throwsStateError,
      );
    });

    test('names a section mpx.<category>.<op>', () {
      expect(MpxTrace.sectionName(_TestOp.queued), 'mpx.test.queued');
      expect(MpxTrace.sectionName(BindingOp.mapped), 'mpx.binding.mapped');
    });
  });
}

void _noLog(
  String message, {
  required String name,
  required int level,
  Object? error,
  StackTrace? stackTrace,
  DateTime? time,
}) {}
