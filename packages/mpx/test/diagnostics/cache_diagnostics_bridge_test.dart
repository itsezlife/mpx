import 'package:flutter_test/flutter_test.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx/mpx.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

void main() {
  setUp(() {
    final previous = BytesDiagnostics.current;
    addTearDown(() => BytesDiagnostics.current = previous);
    BytesDiagnostics.current = CacheDiagnosticsBridge.policy;
  });

  test('a bytes-cache warning arrives as a cache event without its '
      'message', () {
    final diagnostics = RecordingDiagnostics.install();
    final stackTrace = StackTrace.current;

    BytesDiagnostics.current.report(
      BytesLogEvent(
        level: BytesLogLevel.warning,
        message: 'stale used for https://cdn.test/private?token=secret',
        op: BytesLogOp.resolveStaleUsed,
        stackTrace: stackTrace,
      ),
    );

    final event = diagnostics.events.single;
    expect(
      event,
      isMpxEvent(
        level: MpxEventLevel.warning,
        category: 'cache',
        op: CacheOp.resolveStaleUsed,
        fields: {'bytesOp': 'resolve_stale_used'},
      ),
    );
    expect(event.stackTrace, same(stackTrace));
    expect(event.toString(), isNot(contains('secret')));
    expect(event.toString(), isNot(contains('cdn.test')));
  });

  test('keeps the level of each bytes event', () {
    final diagnostics = RecordingDiagnostics.install();
    for (final level in BytesLogLevel.values) {
      CacheDiagnosticsBridge.forward(
        BytesLogEvent(level: level, message: '', op: BytesLogOp.indexWipe),
      );
    }
    expect(diagnostics.events.map((event) => event.level), [
      MpxEventLevel.debug,
      MpxEventLevel.warning,
      MpxEventLevel.error,
    ]);
  });

  test('names every known bytes operation, and an unknown one by its '
      'value', () {
    const known = [
      BytesLogOp.writeThrough,
      BytesLogOp.indexWipe,
      BytesLogOp.openDegraded,
      BytesLogOp.cacheKeyAuthorization,
      BytesLogOp.resolveStaleUsed,
      BytesLogOp.resolveRevalidated,
      BytesLogOp.resolveUnconditional,
      BytesLogOp.revalidateBackground,
      BytesLogOp.quotaEvict,
      BytesLogOp.quotaTrim,
      BytesLogOp.rangedCommit,
      BytesLogOp.nativeFetch,
      BytesLogOp.uploadStarted,
      BytesLogOp.uploadRetry,
      BytesLogOp.uploadGaveUp,
    ];
    expect(known.map(CacheOp.of).toSet(), hasLength(known.length));
    expect(known.map(CacheOp.of), isNot(contains(CacheOp.other)));

    final diagnostics = RecordingDiagnostics.install();
    CacheDiagnosticsBridge.forward(
      const BytesLogEvent(
        level: BytesLogLevel.error,
        message: '',
        op: BytesLogOp('future_op'),
      ),
    );
    expect(
      diagnostics.events.single,
      isMpxEvent(op: CacheOp.other, fields: {'bytesOp': 'future_op'}),
    );
  });

  test("carries the bytes event's fields, an upload retry's attempt and "
      'delay among them', () {
    final diagnostics = RecordingDiagnostics.install();

    CacheDiagnosticsBridge.forward(
      const BytesLogEvent(
        level: BytesLogLevel.warning,
        message: 'upload POST https://upload.test try 2 failed',
        op: BytesLogOp.uploadRetry,
        fields: {
          'attempt': 2,
          'delayMs': 1500,
          'status': 503,
          'code': 'service_unavailable',
        },
      ),
    );

    expect(
      diagnostics.events.single,
      isMpxEvent(
        level: MpxEventLevel.warning,
        op: CacheOp.uploadRetry,
        fields: {
          'attempt': 2,
          'delayMs': 1500,
          'status': 503,
          'code': 'service_unavailable',
          'bytesOp': 'upload_retry',
        },
      ),
    );
  });

  test('reports nothing while the mpx policy is silent', () {
    expect(MpxDiagnostics.current, isA<MpxDiagnosticsSilent>());
    expect(
      () => CacheDiagnosticsBridge.forward(
        const BytesLogEvent(
          level: BytesLogLevel.error,
          message: '',
          op: BytesLogOp.writeThrough,
        ),
      ),
      returnsNormally,
    );
  });
}
