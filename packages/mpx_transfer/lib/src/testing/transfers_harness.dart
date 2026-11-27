import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/engine/transfer_store.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/testing/scripted_transfer_runner.dart';
import 'package:mpx_transfer/src/transfers.dart';

/// A [Transfers] over the in-memory engine, its bytes moved by a
/// [ScriptedTransferRunner], for tests of the state model at the facade.
///
/// [addUpload] and [addDownload] make jobs the way the package's own entry
/// points do, and [restart] builds a new facade over the jobs the last one
/// left, as the next process start would.
final class TransfersHarness {
  /// A harness reading the app's lifecycle from [lifecycle].
  ///
  /// [cacheKeyOf] maps a key to its cache key (the key's `encoded` form by
  /// default); the other parts are those of the [Transfers] constructor.
  TransfersHarness({
    required this.lifecycle,
    String Function(MediaKey key)? cacheKeyOf,
    this.envelope,
    this.retention = Transfers.defaultRetention,
    bool online = true,
    DateTime Function()? now,
  }) : cacheKeyOf = cacheKeyOf ?? ((key) => key.encoded),
       now = now ?? DateTime.now {
    transfers = _build(online);
  }

  /// The app lifecycle the facade reads.
  final PlaybackLifecycleSource lifecycle;

  /// The cache key mapping the facade derives download ids with.
  final String Function(MediaKey key) cacheKeyOf;

  /// The OS envelope, or null for a platform without one.
  final TransferEnvelope? envelope;

  /// How long completed jobs stay queryable.
  final Duration retention;

  /// The clock.
  final DateTime Function() now;

  /// The runner every job's bytes go through; it outlives [restart], as the
  /// test that scripts it does.
  final ScriptedTransferRunner runner = ScriptedTransferRunner();

  final MemoryTransferStore _store = MemoryTransferStore();

  /// The facade under test; replaced by [restart].
  late Transfers transfers;

  /// Queues an upload: a new job with a new id each call.
  TransferId addUpload({
    String? tag,
    TransferDurability durability = TransferDurability.system,
    RequestPriority priority = RequestPriority.visible,
    int? total,
  }) => transfers.enqueue(
    direction: TransferDirection.upload,
    durability: durability,
    tag: tag,
    priority: priority,
    total: total,
  );

  /// Queues the download of [key], or answers the id of the job [key]
  /// already has.
  TransferId addDownload(
    MediaKey key, {
    String? tag,
    TransferDurability durability = TransferDurability.inProcess,
    RequestPriority priority = RequestPriority.visible,
    int? total,
    bool resumeOnStart = true,
  }) => transfers.enqueue(
    direction: TransferDirection.download,
    durability: durability,
    key: key,
    tag: tag,
    priority: priority,
    total: total,
    resumeOnStart: resumeOnStart,
  );

  /// Ends the facade, as the process ending would, and builds a new one over
  /// the jobs it left; [online] is the connectivity at the new start.
  Transfers restart({bool online = true}) {
    transfers.dispose();
    return transfers = _build(online);
  }

  Transfers _build(bool online) => Transfers.engine(
    cacheKeyOf: cacheKeyOf,
    lifecycle: lifecycle,
    runner: runner,
    store: _store,
    envelope: envelope,
    retention: retention,
    online: online,
    now: now,
  );
}
