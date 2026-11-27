import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';

/// The bytes cache's operations as diagnostics operations, category `cache`:
/// one per `BytesLogOp`, so a log filters the cache's events as it does the
/// rest of mpx's.
enum CacheOp implements DiagnosticOp {
  /// A cache write after a successful resolve failed.
  writeThrough,

  /// A corrupt or unrecognized index was wiped on open.
  indexWipe,

  /// The durable store failed to open; an in-memory one stands in.
  openDegraded,

  /// A request's cache key was set while its headers carry credentials.
  cacheKeyAuthorization,

  /// Cached bytes were returned after the network failed.
  resolveStaleUsed,

  /// A stale entry was revalidated by the origin and kept.
  resolveRevalidated,

  /// Bytes already held were fetched again unconditionally.
  resolveUnconditional,

  /// A background revalidation failed; the stale entry stays.
  revalidateBackground,

  /// A registered quota's eviction callback threw.
  quotaEvict,

  /// A trim the store ran on its own failed.
  quotaTrim,

  /// A deferred commit of ranged writes failed.
  rangedCommit,

  /// A fetch a native reader asked for failed.
  nativeFetch,

  /// An operation this version does not know yet; `fields.bytesOp` names
  /// it.
  other;

  @override
  String get category => 'cache';

  /// The operation of [op].
  static CacheOp of(BytesLogOp op) => switch (op) {
    BytesLogOp.writeThrough => writeThrough,
    BytesLogOp.indexWipe => indexWipe,
    BytesLogOp.openDegraded => openDegraded,
    BytesLogOp.cacheKeyAuthorization => cacheKeyAuthorization,
    BytesLogOp.resolveStaleUsed => resolveStaleUsed,
    BytesLogOp.resolveRevalidated => resolveRevalidated,
    BytesLogOp.resolveUnconditional => resolveUnconditional,
    BytesLogOp.revalidateBackground => revalidateBackground,
    BytesLogOp.quotaEvict => quotaEvict,
    BytesLogOp.quotaTrim => quotaTrim,
    BytesLogOp.rangedCommit => rangedCommit,
    BytesLogOp.nativeFetch => nativeFetch,
    _ => other,
  };
}

/// Routes the bytes cache's events into `MpxDiagnostics.current`.
///
/// `mpx_core` and `http_bytes_cache` do not depend on each other, so the
/// composition root joins their diagnostics: [policy] is a
/// `BytesDiagnostics` that turns each `BytesLogEvent` into an `MpxEvent` of
/// category `cache` ([CacheOp]), the bytes operation in `fields.bytesOp`,
/// with its level and stack trace. The event's message is dropped, since it
/// can carry cache keys and URLs. `MpxStack.create` installs [policy] as
/// `BytesDiagnostics.current`; a host that opens the bytes cache itself
/// installs it the same way.
abstract final class CacheDiagnosticsBridge {
  /// The bytes cache's policy that forwards into `MpxDiagnostics.current`.
  static const BytesDiagnostics policy = BytesDiagnostics.onEvent(forward);

  /// Reports [event] through `MpxDiagnostics.current`.
  static void forward(BytesLogEvent event) {
    MpxDiagnostics.current.emit(
      switch (event.level) {
        BytesLogLevel.debug => MpxEventLevel.debug,
        BytesLogLevel.warning => MpxEventLevel.warning,
        BytesLogLevel.error => MpxEventLevel.error,
      },
      CacheOp.of(event.op),
      fields: () => {'bytesOp': MpxEvent.clip(event.op.value)},
      stackTrace: event.stackTrace,
    );
  }
}
