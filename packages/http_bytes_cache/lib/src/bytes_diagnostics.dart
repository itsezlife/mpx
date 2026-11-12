import 'dart:developer' as developer;

import 'package:meta/meta.dart';

/// Soft-path reporting for the bytes resolve ladder.
///
/// Process-wide policy lives on [current], set by [BytesCache.open] /
/// [BytesCache.configure].
///
/// Host [BytesDiagnostics.onEvent] callbacks must not throw. If they do,
/// [report] swallows the error so a soft path (especially unawaited
/// write-through catch) cannot become an unhandled async error in the zone.
@immutable
sealed class BytesDiagnostics {
  const BytesDiagnostics();

  /// Active policy for open wipe and resolve write-through.
  static BytesDiagnostics current = const BytesDiagnostics.silent();

  /// No emission.
  const factory BytesDiagnostics.silent() = BytesDiagnosticsSilent;

  /// [developer.log] with name `image_bytes`.
  const factory BytesDiagnostics.developer() = BytesDiagnosticsDeveloper;

  /// Host owns routing (print, logger, Crashlytics, …).
  ///
  /// The callback must not throw. Throws are caught inside [report] so soft
  /// failure reporting cannot escalate into an unhandled async error.
  const factory BytesDiagnostics.onEvent(
    void Function(BytesLogEvent event) onEvent,
  ) = BytesDiagnosticsOnEvent;

  /// Emits [event] according to this policy.
  ///
  /// Swallowing a throwing host callback is intentional: diagnostics are
  /// best-effort. Without this, an unawaited write-through `.catchError` that
  /// calls [report] would surface the host throw as a second unhandled async
  /// error after the durable failure was already soft-failed.
  void report(BytesLogEvent event) {
    try {
      switch (this) {
        case BytesDiagnosticsSilent():
          return;
        case BytesDiagnosticsDeveloper():
          developer.log(
            event.message,
            name: 'image_bytes',
            stackTrace: event.stackTrace,
            level: switch (event.level) {
              BytesLogLevel.error => 1000,
              BytesLogLevel.warning => 900,
              BytesLogLevel.debug => 500,
            },
          );
        case BytesDiagnosticsOnEvent(:final onEvent):
          onEvent(event);
      }
    } on Object {
      // Host diagnostics must not escalate soft failures.
    }
  }
}

/// [BytesDiagnostics.silent].
final class BytesDiagnosticsSilent extends BytesDiagnostics {
  /// Shared silent policy.
  const BytesDiagnosticsSilent();
}

/// [BytesDiagnostics.developer].
final class BytesDiagnosticsDeveloper extends BytesDiagnostics {
  /// Shared developer-log policy.
  const BytesDiagnosticsDeveloper();
}

/// [BytesDiagnostics.onEvent].
final class BytesDiagnosticsOnEvent extends BytesDiagnostics {
  /// Forwards every event to [onEvent].
  const BytesDiagnosticsOnEvent(this.onEvent);

  /// Host callback.
  final void Function(BytesLogEvent event) onEvent;
}

/// Severity for [BytesLogEvent].
enum BytesLogLevel {
  /// Development notice (for example cacheKey set with Authorization headers).
  debug,

  /// Recoverable path that still completed (for example stale-on-network-error).
  warning,

  /// Unexpected durable failure after a successful network fetch.
  error,
}

/// Soft-path tag for [BytesLogEvent.op].
extension type const BytesLogOp(String value) implements String {
  /// Cache write after a successful resolve.
  static const writeThrough = BytesLogOp('write_through');

  /// Corrupt / unrecognized index wipe on open.
  static const indexWipe = BytesLogOp('index_wipe');

  /// Durable open failed; host received Memory / NoOp instead of throwing.
  static const openDegraded = BytesLogOp('open_degraded');

  /// [BytesRequest.cacheKey] set while request headers include
  /// `Authorization`. Override wins for durable and coalesce identity; mint
  /// distinct keys per tenant if you need both.
  static const cacheKeyAuthorization = BytesLogOp('cache_key_authorization');

  /// Cached bytes returned after `$Network`, `$Timeout`, or `$Server` failed
  /// the GET. Resolve succeeds; the failure shows up here only when diagnostics
  /// are audible.
  static const resolveStaleUsed = BytesLogOp('resolve_stale_used');

  /// Stale hit with validators got HTTP 304; cached bytes reused and meta
  /// soft-refreshed. Debug only when diagnostics are audible.
  static const resolveRevalidated = BytesLogOp('resolve_revalidated');

  /// Ladder already held non-empty bytes but issued an unconditional GET
  /// (stale without validators, or 412 fallback). Cold misses stay quiet.
  /// Debug only when diagnostics are audible.
  static const resolveUnconditional = BytesLogOp('resolve_unconditional');

  /// A registered quota's eviction callback threw. The store counts it as
  /// freeing nothing and moves on to other quotas.
  static const quotaEvict = BytesLogOp('quota_evict');

  /// A trim the store ran on its own (after a registered quota's usage
  /// report) failed.
  static const quotaTrim = BytesLogOp('quota_trim');
}

/// Soft-path report from the bytes resolve ladder (failures and audible resolve
/// paths such as revalidated / stale-used / unconditional).
@immutable
final class BytesLogEvent {
  /// Builds an event for hosts and [BytesDiagnostics.developer].
  const BytesLogEvent({
    required this.level,
    required this.message,
    required this.op,
    this.stackTrace,
  });

  /// Warning vs error.
  final BytesLogLevel level;

  /// Human-readable detail (includes key / error text when relevant).
  final String message;

  /// Soft-path tag (see [BytesLogOp]).
  final BytesLogOp op;

  /// Present when the failure carried a stack.
  final StackTrace? stackTrace;
}
