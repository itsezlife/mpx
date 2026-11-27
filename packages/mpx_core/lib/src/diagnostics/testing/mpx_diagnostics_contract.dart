import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/src/diagnostics/mpx_diagnostics.dart';
import 'package:mpx_core/src/diagnostics/mpx_event.dart';

enum _ContractOp implements DiagnosticOp {
  probe;

  @override
  String get category => 'contract';
}

/// The behaviour every [MpxDiagnostics] policy must have, as a test suite to
/// run against one.
///
/// What a policy does with an event differs (nothing, a log line, the
/// host's callback); what call sites rely on does not: a level check that
/// agrees with delivery, fields built only for an enabled level and at most
/// once, and reporting that never throws.
abstract final class MpxDiagnosticsContract {
  /// Runs the contract against the policies [create] returns, one per test.
  static void run(MpxDiagnostics Function() create) {
    group('MpxDiagnostics contract', () {
      late MpxDiagnostics diagnostics;

      setUp(() => diagnostics = create());

      test('a level enabled stays enabled for every level above it', () {
        var enabled = false;
        for (final level in MpxEventLevel.values) {
          if (enabled) {
            expect(diagnostics.isEnabled(level), isTrue, reason: '$level');
          }
          enabled = diagnostics.isEnabled(level);
        }
      });

      test('emit builds fields once at an enabled level, never otherwise', () {
        for (final level in MpxEventLevel.values) {
          var built = 0;
          diagnostics.emit(
            level,
            _ContractOp.probe,
            fields: () {
              built++;
              return const {'n': 1};
            },
          );
          expect(built, diagnostics.isEnabled(level) ? 1 : 0, reason: '$level');
        }
      });

      test('report and emit never throw', () {
        for (final level in MpxEventLevel.values) {
          expect(
            () => diagnostics
              ..report(
                MpxEvent(
                  time: DateTime.utc(2026),
                  level: level,
                  op: _ContractOp.probe,
                  error: StateError('probe'),
                  stackTrace: StackTrace.current,
                ),
              )
              ..emit(level, _ContractOp.probe, jobId: 'j', tag: 't'),
            returnsNormally,
          );
        }
      });
    });
  }
}
