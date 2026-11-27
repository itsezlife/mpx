import 'dart:async';

import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/download/transfer_downloads.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/journal/unload_warning.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/reuse/reuse_table.dart';
import 'package:mpx_transfer/src/testing/fake_transfer_envelope.dart';
import 'package:mpx_transfer/src/testing/fake_transfer_result.dart';
import 'package:mpx_transfer/src/testing/scripted_transfer_runner.dart';
import 'package:mpx_transfer/src/transfers.dart';

/// A [Transfers] over a journal in memory (or the store a test gives), its
/// bytes moved by a [ScriptedTransferRunner], for tests of the state model
/// and the journal at the facade.
///
/// [addUpload] and [addDownload] make jobs the way the package's own entry
/// points do. [restart] closes the facade and opens a new one over the
/// journal it left, as the next process start would; [kill] drops it
/// without closing, as a killed process would, and opens a new one over
/// what was flushed by then.
final class TransfersHarness {
  TransfersHarness._({
    required this.lifecycle,
    required this.cacheKeyOf,
    required this.envelope,
    required this.envelopeConfig,
    required this.retention,
    required this.progressInterval,
    required this.now,
    required this.openStore,
    required this.downloads,
    required this.openSourceCopies,
    required this.unloadWarning,
    required this.sourceCopyLimit,
    required this.openReuseStore,
    required this.reusePolicy,
  });

  /// Opens a harness reading the app's lifecycle from [lifecycle].
  ///
  /// [cacheKeyOf] maps a key to its cache key (the key's `encoded` form by
  /// default); [store] gives the journal's store at each start (one
  /// [MemoryJournalStore] for every start by default; for a store on disk,
  /// a new store over the same files each call). With [downloads], download
  /// jobs move their bytes through them, as [Transfers.open]'s do, and only
  /// uploads go through [runner]. [sourceCopies] gives the upload source
  /// copies at each start, as on the web (none by default, as on the VM);
  /// [unloadWarning] is the page's warning (none by default). [reuseStore]
  /// gives the reuse table's store at each start, as [store] does the
  /// journal's; [reuse] is the host's say over the table. [envelopeConfig]
  /// is what [envelope] shows ([FakeTransferEnvelope.config] unless given);
  /// [configureEnvelope] false leaves it unconfigured. The other parts are
  /// those of [Transfers.open].
  static Future<TransfersHarness> open({
    required PlaybackLifecycleSource lifecycle,
    String Function(MediaKey key)? cacheKeyOf,
    TransferEnvelope? envelope,
    TransferEnvelopeConfig? envelopeConfig,
    bool configureEnvelope = true,
    Duration retention = Transfers.defaultRetention,
    Duration progressInterval = Transfers.defaultProgressInterval,
    bool online = true,
    DateTime Function()? now,
    JournalStore Function()? store,
    TransferDownloads? downloads,
    FutureOr<UploadSourceCopies> Function()? sourceCopies,
    UnloadWarning? unloadWarning,
    int sourceCopyLimit = Transfers.defaultSourceCopyLimit,
    JournalStore Function()? reuseStore,
    ReusePolicy reuse = const ReusePolicy(),
  }) async {
    final memory = MemoryJournalStore();
    final reuseMemory = MemoryJournalStore();
    final harness = TransfersHarness._(
      lifecycle: lifecycle,
      cacheKeyOf: cacheKeyOf ?? ((key) => key.encoded),
      envelope: envelope,
      envelopeConfig: configureEnvelope
          ? envelopeConfig ?? FakeTransferEnvelope.config
          : null,
      retention: retention,
      progressInterval: progressInterval,
      now: now ?? DateTime.now,
      openStore: store ?? () => memory,
      downloads: downloads,
      openSourceCopies: sourceCopies,
      unloadWarning: unloadWarning,
      sourceCopyLimit: sourceCopyLimit,
      openReuseStore: reuseStore ?? () => reuseMemory,
      reusePolicy: reuse,
    );
    await harness._start(online);
    return harness;
  }

  /// The app lifecycle the facade reads.
  final PlaybackLifecycleSource lifecycle;

  /// The cache key mapping the facade derives download ids with.
  final String Function(MediaKey key) cacheKeyOf;

  /// The OS envelope, or null for a platform without one.
  final TransferEnvelope? envelope;

  /// What [envelope] shows; null when the host gave no config.
  final TransferEnvelopeConfig? envelopeConfig;

  /// How long completed jobs stay queryable.
  final Duration retention;

  /// The shortest time between two progress writes.
  final Duration progressInterval;

  /// The clock.
  final DateTime Function() now;

  /// Gives the journal's store at each start.
  final JournalStore Function() openStore;

  /// What download jobs fetch through, or null when [runner] moves them.
  final TransferDownloads? downloads;

  /// Gives the upload source copies at each start; null for none.
  final FutureOr<UploadSourceCopies> Function()? openSourceCopies;

  /// The page's warning before it is left; null for none.
  final UnloadWarning? unloadWarning;

  /// How many bytes of a job's sources are copied at most.
  final int sourceCopyLimit;

  /// Gives the reuse table's store at each start.
  final JournalStore Function() openReuseStore;

  /// The host's say over the reuse table.
  final ReusePolicy reusePolicy;

  /// The runner every job's bytes go through; it outlives [restart] and
  /// [kill], as the test that scripts it does.
  final ScriptedTransferRunner runner = ScriptedTransferRunner();

  /// The facade under test; replaced by [restart] and [kill].
  late Transfers transfers;

  late TransferJournal _journal;

  /// The jobs the journal read back at the last start, before the engine
  /// resumed any: what was flushed when the last facade ended.
  List<TransferJob> get replayed => List.unmodifiable(_replayed);
  List<TransferJob> _replayed = const [];

  /// Queues an upload: a new job with a new id each call, reading
  /// [sources].
  TransferId addUpload({
    String? tag,
    TransferDurability durability = TransferDurability.system,
    RequestPriority priority = RequestPriority.visible,
    int? total,
    List<SourceBytes> sources = const [],
  }) => transfers.enqueue(
    direction: TransferDirection.upload,
    durability: durability,
    tag: tag,
    priority: priority,
    total: total,
    sources: sources,
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

  /// Completes when every journal write made so far is flushed and every
  /// source copy begun has ended; progress still waiting for its window is
  /// not.
  Future<void> settle() async {
    await transfers.debugSourcesCopied;
    await _journal.idle;
    await transfers.reuse.idle;
  }

  /// Closes the facade, as the app shutting down would, and opens a new one
  /// over the journal it left; [online] is the connectivity at the new
  /// start.
  Future<Transfers> restart({bool online = true}) async {
    await transfers.dispose();
    return _start(online);
  }

  /// Drops the facade at this point, as a killed process would: progress
  /// still batched is lost and no write not yet begun is made. Then opens a
  /// new facade over what was flushed; [online] is the connectivity at the
  /// new start.
  Future<Transfers> kill({bool online = true}) {
    transfers.debugKill();
    return _start(online);
  }

  Future<Transfers> _start(bool online) async {
    _journal = await TransferJournal.open(
      openStore(),
      retention: retention,
      progressInterval: progressInterval,
      now: now,
      resultCodecs: const [...Transfers.resultCodecs, FakeTransferResult.codec],
    );
    _replayed = _journal.jobs.toList();
    final copies = await openSourceCopies?.call();
    final reuse = await ReuseTable.open(
      openReuseStore(),
      policy: reusePolicy,
      now: now,
    );
    final live = await Transfers.liveEnvelopesOf(envelope);
    return transfers = Transfers.engine(
      cacheKeyOf: cacheKeyOf,
      lifecycle: lifecycle,
      runner: runner,
      journal: _journal,
      downloads: downloads,
      envelope: envelope,
      envelopeConfig: envelopeConfig,
      liveEnvelopes: live,
      sourceCopies: copies,
      unloadWarning: unloadWarning,
      reuse: reuse,
      retention: retention,
      sourceCopyLimit: sourceCopyLimit,
      online: online,
      now: now,
    );
  }
}
