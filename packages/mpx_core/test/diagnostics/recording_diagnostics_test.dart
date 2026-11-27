import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

enum _TestOp implements DiagnosticOp {
  queued,
  sent,
  failed;

  @override
  String get category => 'test';
}

enum _OtherOp implements DiagnosticOp {
  opened;

  @override
  String get category => 'other';
}

void main() {
  MpxDiagnosticsContract.run(RecordingDiagnostics.new);

  group('RecordingDiagnostics', () {
    late RecordingDiagnostics diagnostics;

    setUp(() {
      diagnostics = RecordingDiagnostics()
        ..emit(
          MpxEventLevel.info,
          _TestOp.queued,
          jobId: 'j1',
          itemId: 'a',
          tag: 't',
          fields: () => const {'items': 2},
        )
        ..emit(
          MpxEventLevel.trace,
          _TestOp.sent,
          jobId: 'j1',
          itemId: 'b',
          mediaKey: const MediaKey.remote('k1'),
        )
        ..emit(MpxEventLevel.debug, _OtherOp.opened)
        ..emit(MpxEventLevel.error, _TestOp.failed, jobId: 'j2', itemId: 'a');
    });

    test('records every event in order, at every level', () {
      expect(MpxEventLevel.values.every(diagnostics.isEnabled), isTrue);
      expect(diagnostics.events.map((event) => event.op), [
        _TestOp.queued,
        _TestOp.sent,
        _OtherOp.opened,
        _TestOp.failed,
      ]);
    });

    test('finds events by category, op and level', () {
      expect(diagnostics.whereCategory('test').map((e) => e.op), [
        _TestOp.queued,
        _TestOp.sent,
        _TestOp.failed,
      ]);
      expect(diagnostics.whereCategory('other').single.op, _OtherOp.opened);
      expect(diagnostics.whereOp(_TestOp.sent), hasLength(1));
      expect(
        diagnostics.whereLevel(MpxEventLevel.trace).single.op,
        _TestOp.sent,
      );
      expect(diagnostics.errors.single.op, _TestOp.failed);
    });

    test('finds events by ids, every given id matching', () {
      expect(diagnostics.whereIds(itemId: 'a').map((e) => e.op), [
        _TestOp.queued,
        _TestOp.failed,
      ]);
      expect(diagnostics.whereIds(jobId: 'j1', itemId: 'a').map((e) => e.op), [
        _TestOp.queued,
      ]);
      expect(
        diagnostics.whereIds(mediaKey: const MediaKey.remote('k1')).single.op,
        _TestOp.sent,
      );
      expect(diagnostics.whereIds(tag: 't').single.op, _TestOp.queued);
      expect(diagnostics.whereIds(jobId: 'none'), isEmpty);
    });

    test('clear forgets the recorded events', () {
      diagnostics.clear();
      expect(diagnostics.events, isEmpty);
    });
  });

  group('isMpxEvent', () {
    final event = MpxEvent(
      time: DateTime.utc(2026),
      level: MpxEventLevel.warning,
      op: _TestOp.failed,
      jobId: '9',
      fields: const {'host': 'example.org', 'status': 404},
    );

    test('matches the given parts and ignores the rest', () {
      expect(event, isMpxEvent(op: _TestOp.failed));
      expect(
        event,
        isMpxEvent(
          level: MpxEventLevel.warning,
          category: 'test',
          op: _TestOp.failed,
          jobId: '9',
          fields: containsPair('status', 404),
        ),
      );
    });

    test('reports a mismatch', () {
      expect(event, isNot(isMpxEvent(op: _TestOp.sent)));
      expect(event, isNot(isMpxEvent(level: MpxEventLevel.error)));
      expect(event, isNot(isMpxEvent(jobId: '8')));
      expect(event, isNot(isMpxEvent(fields: {'status': 404})));
    });
  });

  group('RecordingDiagnostics.install', () {
    late MpxDiagnostics before;

    setUpAll(() => before = MpxDiagnostics.current);

    test('installs a recorder as the process-wide policy', () {
      final previous = MpxDiagnostics.current;
      // Tear-downs run last-registered first: the install's restore, then
      // this check.
      addTearDown(() => expect(MpxDiagnostics.current, same(previous)));
      final installed = RecordingDiagnostics.install();

      expect(MpxDiagnostics.current, same(installed));
      MpxDiagnostics.current.emit(MpxEventLevel.info, _TestOp.queued);
      expect(installed.events, hasLength(1));
    });

    test('left the previous policy in place for the next test', () {
      expect(MpxDiagnostics.current, same(before));
    });
  });
}
