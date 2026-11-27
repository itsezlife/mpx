import 'dart:math' as math;

import 'package:http_bytes_cache/http_bytes_cache.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/download/transfer_downloads.dart';
import 'package:mpx_transfer/src/engine/connection_slots.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/journal_store.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/publish/publish_journal.dart';
import 'package:mpx_transfer/src/publish/publish_progress.dart';
import 'package:mpx_transfer/src/reuse/reuse_table.dart';
import 'package:mpx_transfer/src/transfers.dart';
import 'package:mpx_transfer/src/upload/upload_engine.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';
import 'package:mpx_transfer/src/upload/upload_source.dart';
import 'package:mpx_transfer/src/upload/upload_source_files.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// A [Transfers] whose uploads run through the real upload engine over
/// the test's [transports] (a `FakeUploadTransport` most often), with a
/// journal in memory (or the store a test gives), for tests of uploads at
/// the facade.
///
/// Publish jobs (`transfers.publish`, `transfers.upload`) run over the
/// same engine, preparing through [preparation], with their records and
/// the reuse table in memory stores that outlive restarts too. [upload]
/// makes a bare upload job the way the package's own entry points do. [restart] closes the facade and
/// opens a new one, with a new engine, over the journal it left; [kill]
/// drops it without closing, as a killed process would. The transports
/// outlive both, as a remote end does.
final class UploadsHarness {
  UploadsHarness._({
    required this.lifecycle,
    required this.transports,
    required this.openStore,
    required this.now,
    required this.progressInterval,
    required this.retry,
    required this.laneSplit,
    required this.random,
    required this.wait,
    required this.client,
    required this.files,
    required this.preparation,
    required this.reusePolicy,
    required this.envelope,
    required this.envelopeConfig,
    required this.cache,
    required this.progressWeights,
    required this.downloads,
    required this.sourceCopies,
    required this.sourceDirectory,
  });

  /// Opens a harness over [transports]; the job's transport is the first
  /// one unless [upload] names another.
  ///
  /// [wait] waits each retry's backoff (a timer by default; a test passes
  /// one that returns at once, or runs in a fake-async zone). [random]
  /// draws the backoff's jitter. [client] sends part bodies, for a
  /// transport that sends them. [files] tells what each source file is at
  /// the start of a run (the platform's file system by default; a
  /// `FakeUploadSourceFiles` for sources that are not real files).
  /// [envelope] is the OS envelope, showing [envelopeConfig]. The other
  /// parts are those of [Transfers.open]; [cache] is the bytes cache
  /// publish jobs alias their server keys in (`downloads.store` unless
  /// given); [downloads], tracked downloads beside the uploads.
  /// [sourceCopies] makes the engine read page sources as on the web,
  /// copied there (give the same fake to every start, as OPFS outlives a
  /// reload); [sourceDirectory] is where the engine writes sources held in
  /// memory as files, as on the VM.
  static Future<UploadsHarness> open({
    required PlaybackLifecycleSource lifecycle,
    required List<UploadTransport> transports,
    JournalStore Function()? store,
    DateTime Function()? now,
    Duration progressInterval = Transfers.defaultProgressInterval,
    HttpBytesRetryBackoff retry = HttpBytesRetryBackoff.uploadPart,
    int laneSplit = UploadLane.defaultSplit,
    math.Random? random,
    Future<void> Function(Duration delay)? wait,
    HttpBytesClient? client,
    UploadSourceFiles? files,
    MediaPreparation? preparation,
    ReusePolicy reuse = const ReusePolicy(),
    TransferEnvelope? envelope,
    TransferEnvelopeConfig? envelopeConfig,
    IBytesStore? cache,
    PublishProgressWeights progressWeights = PublishProgressWeights.standard,
    TransferDownloads? downloads,
    UploadSourceCopies? sourceCopies,
    String? sourceDirectory,
  }) async {
    final memory = MemoryJournalStore();
    final harness = UploadsHarness._(
      lifecycle: lifecycle,
      transports: List.unmodifiable(transports),
      openStore: store ?? () => memory,
      now: now ?? DateTime.now,
      progressInterval: progressInterval,
      retry: retry,
      laneSplit: laneSplit,
      random: random ?? math.Random(0),
      wait: wait,
      client: client,
      files: files,
      preparation: preparation,
      reusePolicy: reuse,
      envelope: envelope,
      envelopeConfig: envelopeConfig,
      cache: cache,
      progressWeights: progressWeights,
      downloads: downloads,
      sourceCopies: sourceCopies,
      sourceDirectory: sourceDirectory,
    );
    await harness._start();
    return harness;
  }

  /// The app lifecycle the facade reads.
  final PlaybackLifecycleSource lifecycle;

  /// The transports the engine sends through.
  final List<UploadTransport> transports;

  /// Gives the journal's store at each start.
  final JournalStore Function() openStore;

  /// The clock.
  final DateTime Function() now;

  /// The shortest time between two progress writes.
  final Duration progressInterval;

  /// The backoff between two tries of a part.
  final HttpBytesRetryBackoff retry;

  /// The largest file the small lane takes.
  final int laneSplit;

  /// The backoff's jitter.
  final math.Random random;

  /// Waits each backoff; null for a timer.
  final Future<void> Function(Duration delay)? wait;

  /// Sends part bodies; null when no transport sends them.
  final HttpBytesClient? client;

  /// Tells what each source file is; null for the platform's.
  final UploadSourceFiles? files;

  /// Prepares publish job items; null for a facade without preparation.
  final MediaPreparation? preparation;

  /// The host's say over the reuse table.
  final ReusePolicy reusePolicy;

  /// The OS envelope; null for a platform without one.
  final TransferEnvelope? envelope;

  /// What [envelope] shows; null for none.
  final TransferEnvelopeConfig? envelopeConfig;

  /// The bytes cache server keys are aliased in; null for none.
  final IBytesStore? cache;

  /// How publish jobs weigh their progress.
  final PublishProgressWeights progressWeights;

  /// What tracked downloads fetch through; null for a facade without them.
  final TransferDownloads? downloads;

  /// Where page sources are copied, as on the web; null for the VM.
  final UploadSourceCopies? sourceCopies;

  /// Where the engine writes sources held in memory; null for none.
  final String? sourceDirectory;

  /// Where the publish jobs' records are kept across restarts.
  final MemoryJournalStore publishStore = MemoryJournalStore();

  /// Where the reuse table is kept across restarts.
  final MemoryJournalStore reuseStore = MemoryJournalStore();

  /// The facade under test; replaced by [restart] and [kill].
  late Transfers transfers;

  late TransferJournal _journal;
  late PublishJournal _publish;
  late ReuseTable _reuse;
  late UploadEngine _engine;

  /// The jobs the journal read back at the last start, before the engine
  /// resumed any.
  List<TransferJob> get replayed => List.unmodifiable(_replayed);
  List<TransferJob> _replayed = const [];

  /// Queues an upload of [source] through [transport] (the first of
  /// [transports] by default); answers the new job's id. The other parts
  /// are the job's and its upload's.
  TransferId upload(
    UploadSource source, {
    String? transport,
    String? tag,
    TransferDurability durability = TransferDurability.system,
    RequestPriority priority = RequestPriority.visible,
    UploadLane? lane,
    String? fileName,
    String? contentType,
    String? fingerprint,
  }) {
    final upload = _engine.describe(
      source,
      transport: transport ?? transports.first.id,
      lane: lane,
      fileName: fileName,
      contentType: contentType,
      fingerprint: fingerprint,
    );
    return transfers.enqueue(
      direction: TransferDirection.upload,
      durability: durability,
      tag: tag,
      priority: priority,
      total: upload.source.size,
      upload: upload,
    );
  }

  /// What the journal keeps of job [id]'s upload in memory now; null for
  /// an unknown job.
  JournalUpload? uploadOf(TransferId id) => _journal.record(id)?.upload;

  /// Completes when every journal write made so far is flushed; progress
  /// still waiting for its window is not.
  Future<void> settle() =>
      Future.wait([_journal.idle, _publish.idle, _reuse.idle]);

  /// Closes the facade and opens a new one, with a new engine, over the
  /// journal it left.
  Future<Transfers> restart() async {
    await transfers.dispose();
    return _start();
  }

  /// Drops the facade as a killed process would, then opens a new one over
  /// what was flushed.
  Future<Transfers> kill() {
    transfers.debugKill();
    return _start();
  }

  Future<Transfers> _start() async {
    _journal = await TransferJournal.open(
      openStore(),
      retention: Transfers.defaultRetention,
      progressInterval: progressInterval,
      now: now,
      resultCodecs: Transfers.resultCodecs,
    );
    _replayed = _journal.jobs.toList();
    _publish = await PublishJournal.open(
      publishStore,
      retention: Transfers.defaultRetention,
      now: now,
    );
    _reuse = await ReuseTable.open(reuseStore, policy: reusePolicy, now: now);
    _engine = UploadEngine(
      journal: _journal,
      transports: transports,
      slots: ConnectionSlots(),
      client: client,
      files: files,
      sourceCopies: sourceCopies,
      sourceDirectory: sourceDirectory,
      retry: retry,
      laneSplit: laneSplit,
      random: random,
      wait: wait,
      now: now,
    );
    final live = await Transfers.liveEnvelopesOf(envelope);
    return transfers = Transfers.engine(
      envelope: envelope,
      envelopeConfig: envelopeConfig,
      liveEnvelopes: live,
      cacheKeyOf: (key) => key.encoded,
      lifecycle: lifecycle,
      runner: _engine,
      journal: _journal,
      uploads: _engine,
      reuse: _reuse,
      publishJournal: _publish,
      preparation: preparation,
      cache: cache,
      progressWeights: progressWeights,
      downloads: downloads,
      sourceCopies: sourceCopies,
      now: now,
    );
  }
}
