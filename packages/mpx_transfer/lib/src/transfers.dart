import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:http_bytes_cache/http_bytes_cache.dart'
    show BytesCacheKey, HttpBytesClient, IBytesStore, RequestPriority;
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/cancelled_by.dart';
import 'package:mpx_transfer/src/diagnostics/envelope_op.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/diagnostics/scheduler_op.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/diagnostics/transport_op.dart';
import 'package:mpx_transfer/src/download/download_runner.dart';
import 'package:mpx_transfer/src/download/downloaded_content.dart';
import 'package:mpx_transfer/src/download/transfer_downloads.dart';
import 'package:mpx_transfer/src/engine/transfer_runner.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_config.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope_setup.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_codec.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/platform_journal_store.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/journal/unload_warning.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/publish/publish_job.dart';
import 'package:mpx_transfer/src/publish/publish_jobs.dart';
import 'package:mpx_transfer/src/publish/publish_journal.dart';
import 'package:mpx_transfer/src/publish/publish_progress.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/publish/publish_state.dart';
import 'package:mpx_transfer/src/publish/publisher.dart';
import 'package:mpx_transfer/src/reuse/reuse_table.dart';
import 'package:mpx_transfer/src/tracked/tracked_content.dart';
import 'package:mpx_transfer/src/transfer_bytes_cache.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/resume_outcome.dart';
import 'package:mpx_transfer/src/upload/upload_engine.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// The one facade of the transfer engine: every transfer job, its verbs and
/// the query over them.
///
/// The composition root opens one ([open]) and keeps it for the app's life.
/// It passes [cacheKeyOf], the same `MediaKey` to cache key mapping its bytes
/// cache fetcher uses, so a download's [TransferId] is derived from the key
/// the bytes live under; the app lifecycle, whose return to the foreground
/// resumes jobs the system interrupted; and connectivity through
/// [connectivityChanged], fed from the device signal the asset cache scope
/// reads too.
///
/// A job is queued, running, paused, failed or completed
/// ([TransferState]); a cancel removes it. Every job is journaled: a state
/// change is written at once and progress at most every
/// [defaultProgressInterval], so after any kill the next [open] reads the
/// jobs back, and the queries answer from the journal at every durability
/// level. On the web the journal is in OPFS (in memory where the page has
/// none), an upload's sources are copied there at its creation up to
/// [sourceCopyLimit], and leaving the page asks first while a job is
/// queued or running. Every change is reported through `MpxDiagnostics.current`
/// (categories `journal`, `scheduler` and `envelope`).
///
/// Single-threaded on the UI isolate. Call [dispose] when the app shuts
/// down.
final class Transfers {
  /// The engine over an explicit [runner] and an opened [journal]: what the
  /// package's own runners and test support build on. With [downloads],
  /// download jobs move their bytes through them and [runner] moves the
  /// rest; without, [runner] moves every job. With [uploads] and
  /// [publishJournal], the facade runs publish jobs, preparing items
  /// through [preparation] and aliasing their server keys in [cache]'s
  /// store (`downloads.store` unless given). [envelope]'s `live` are the
  /// handles its envelope reported live at the start
  /// ([TransferEnvelope.live]). [pageSources] is the web's copies of page
  /// sources; null on the VM.
  @internal
  Transfers.engine({
    required TransferBytesCache cache,
    required PlaybackLifecycleSource lifecycle,
    required TransferRunner runner,
    required TransferJournal journal,
    TransferDownloads? downloads,
    ({TransferEnvelopeSetup setup, Set<String> live})? envelope,
    PageSourceCopies? pageSources,
    UploadEngine? uploads,
    ReuseTable? reuse,
    PublishJournal? publishJournal,
    MediaPreparation? preparation,
    PublishProgressWeights progressWeights = PublishProgressWeights.standard,
    this.retention = defaultRetention,
    bool online = true,
    DateTime Function() now = DateTime.now,
  }) : _cacheKeyOf = cache.keyOf,
       _lifecycle = lifecycle,
       _runner = runner,
       _downloadRunner = downloads == null ? null : DownloadRunner(downloads),
       _journal = journal,
       _envelope = envelope?.setup.envelope,
       _envelopeConfig = envelope?.setup.config,
       _sourceCopies = pageSources?.copies,
       _unloadWarning = pageSources?.unloadWarning,
       sourceCopyLimit = pageSources?.limit ?? defaultSourceCopyLimit,
       _uploads = uploads,
       _reuse = reuse,
       _online = online,
       _now = now,
       _lastLifecycle = lifecycle.state {
    if (uploads != null && publishJournal != null) {
      _publish = PublishJobs(
        journal: publishJournal,
        uploads: uploads,
        host: _PublishHost(
          this,
          journal: journal,
          cache: cache.store ?? downloads?.store,
          cacheKeyOf: cache.keyOf,
        ),
        reuse: reuse,
        preparation: preparation,
        progressWeights: progressWeights,
        now: now,
      );
    }
    if (downloads != null || _publish != null) {
      _tracked = TrackedContent(
        engine: this,
        journal: journal,
        downloads: downloads,
        publish: _publish,
      );
    }
    _lifecycle.addListener(_onLifecycle);
    _envelopeEvents = _envelope?.events.listen(_onEnvelopeEvent);
    _adoptLiveEnvelope(envelope?.live ?? const {});
    _restore();
    // After the uploads they own are queued again, so each job finds them.
    _publish?.restore();
  }

  /// Opens the engine of the composition root over the journal the last
  /// run left, and resumes its jobs.
  ///
  /// [directory] is the bytes cache's directory: on the VM the journal is
  /// kept in `mpx_transfer` below it, and a missing [directory] throws an
  /// [ArgumentError]; on the web it is ignored, and the journal is kept in
  /// `mpx_transfer` at the OPFS root, beside the bytes cache's store, or in
  /// memory where the page has no OPFS. [retention] is how long a
  /// completed job stays queryable ([defaultRetention] unless given).
  /// [sourceCopyLimit] is how many bytes of an upload job's sources the web
  /// copies at most ([defaultSourceCopyLimit] unless given).
  /// [progressInterval] is the shortest time between two progress writes
  /// ([defaultProgressInterval] unless given). [envelope] is the platform's
  /// OS envelope with what it shows; without one, `system` jobs run in
  /// process, and without its config no envelope starts either, reported
  /// once as `envelope` `degraded`. [online] is
  /// the connectivity at start; [now] reads the time. [downloads] is what
  /// tracked downloads fetch through ([download], [tracked]); without it the
  /// facade makes no download jobs. [reuse] is the host's say over the
  /// reuse table ([ReusePolicy], on with its default expiry unless given),
  /// which is kept beside the journal.
  ///
  /// Uploads and publish jobs go through [transports] (their ids unique),
  /// whose part bodies [client] sends: the bytes cache's client, whose
  /// worker streams them from the file. [preparation] prepares the items
  /// of publish jobs that need it; without one such a job is refused.
  /// [progressWeights] weigh a publish job's progress
  /// ([PublishProgressWeights.standard] unless given). Publish jobs are
  /// kept beside the journal too. [cache] is the bytes cache the
  /// composition root's fetcher reads: its key mapping names tracked
  /// downloads, and once a publisher answers published, each server key
  /// it gave is aliased to its item's local key in its store
  /// (`downloads.store` unless given). Without either store, no alias is
  /// made.
  ///
  /// A journal that cannot be read is reported (`journal` `writeFailed`)
  /// and the engine runs in memory for this run, with no jobs.
  static Future<Transfers> open({
    required TransferBytesCache cache,
    required PlaybackLifecycleSource lifecycle,
    String? directory,
    TransferDownloads? downloads,
    TransferEnvelopeSetup? envelope,
    Duration retention = defaultRetention,
    Duration progressInterval = defaultProgressInterval,
    int sourceCopyLimit = defaultSourceCopyLimit,
    ReusePolicy reuse = const ReusePolicy(),
    List<UploadTransport> transports = const [],
    HttpBytesClient? client,
    MediaPreparation? preparation,
    PublishProgressWeights progressWeights = PublishProgressWeights.standard,
    bool online = true,
    DateTime Function() now = DateTime.now,
  }) async {
    final platform = await $openJournalPlatform(directory);
    final journal = await TransferJournal.open(
      platform.store,
      retention: retention,
      progressInterval: progressInterval,
      now: now,
      resultCodecs: resultCodecs,
    );
    final table = await ReuseTable.open(
      platform.reuseStore,
      policy: reuse,
      now: now,
    );
    final publishJournal = await PublishJournal.open(
      platform.publishStore,
      retention: retention,
      now: now,
    );
    final uploads = UploadEngine(
      journal: journal,
      transports: transports,
      client: client,
      sourceCopies: platform.sourceCopies,
      sourceDirectory: platform.sourceDirectory,
      now: now,
    );
    final copies = platform.sourceCopies;
    return Transfers.engine(
      cache: cache,
      lifecycle: lifecycle,
      runner: uploads,
      journal: journal,
      downloads: downloads,
      envelope: envelope == null
          ? null
          : (setup: envelope, live: await liveEnvelopesOf(envelope.envelope)),
      reuse: table,
      uploads: uploads,
      publishJournal: publishJournal,
      preparation: preparation,
      progressWeights: progressWeights,
      pageSources: copies == null
          ? null
          : PageSourceCopies(
              copies,
              unloadWarning: platform.unloadWarning,
              limit: sourceCopyLimit,
            ),
      retention: retention,
      online: online,
      now: now,
    );
  }

  /// The handles [envelope] still holds from an earlier run; none when it
  /// cannot tell, which is reported (`envelope` `refused`, `code: live`).
  @internal
  static Future<Set<String>> liveEnvelopesOf(TransferEnvelope? envelope) async {
    if (envelope == null) return const {};
    try {
      return await envelope.live();
    } on Object catch (error, stackTrace) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        EnvelopeOp.refused,
        // The error stays out: a platform error may name app state.
        fields: () => {'code': 'live'},
        stackTrace: stackTrace,
      );
      return const {};
    }
  }

  /// How every kind of result the package's own jobs complete with is
  /// written into the journal.
  @internal
  static const List<TransferResultCodec> resultCodecs = [
    DownloadedContent.codec,
    RemoteRef.codec,
  ];

  /// How long a completed job stays queryable by default: 24 hours.
  static const Duration defaultRetention = Duration(hours: 24);

  /// The shortest time between two progress writes to the journal by
  /// default: 250 ms. A kill loses at most this much progress.
  static const Duration defaultProgressInterval =
      TransferJournal.defaultProgressInterval;

  /// How many bytes of an upload job's sources the web copies into OPFS
  /// at most by default: 500 MiB, the sum of the job's sources.
  static const int defaultSourceCopyLimit = 500 * 1024 * 1024;

  /// How long a completed job stays queryable after it completed.
  final Duration retention;

  /// How many bytes of an upload job's sources, together, the web copies
  /// into OPFS at the job's creation. A job over it runs from the page's
  /// file, and after a reload comes back failed with
  /// [TransferFailureKind.sourceLost].
  final int sourceCopyLimit;

  /// The shortest time between two progress writes to the journal.
  Duration get progressInterval => _journal.progressInterval;

  final String Function(MediaKey key) _cacheKeyOf;
  final PlaybackLifecycleSource _lifecycle;
  final TransferRunner _runner;
  final DownloadRunner? _downloadRunner;
  final TransferJournal _journal;
  final TransferEnvelope? _envelope;
  final TransferEnvelopeConfig? _envelopeConfig;
  final UploadSourceCopies? _sourceCopies;
  final UnloadWarning? _unloadWarning;
  final UploadEngine? _uploads;
  final ReuseTable? _reuse;
  final DateTime Function() _now;

  /// The source copies under way; see [debugSourcesCopied].
  final Set<Future<void>> _$copies = {};

  bool _online;
  AppLifecycleState? _lastLifecycle;
  bool _disposed = false;

  final ValueNotifier<bool> _systemActive = ValueNotifier(false);

  /// Whether any `system` job is queued or running: false while they are
  /// paused, failed or completed, and always false for `inProcess` jobs.
  ///
  /// For a host that confirms quitting while a transfer would be lost: on
  /// macOS, Windows and Linux there is no OS envelope, so a quit ends every
  /// job, and the host asks first while this is true. Defined on every
  /// platform, and read the same way on all.
  ValueListenable<bool> get systemActive => _systemActive;

  final Map<TransferId, _Run> _runs = {};
  final Map<TransferId, DateTime> _queuedAt = {};
  final List<_Watch> _watchers = [];
  PublishJobs? _publish;
  StreamSubscription<TransferEnvelopeEvent>? _envelopeEvents;
  final StreamController<TransferId> _notificationTaps =
      StreamController.broadcast();

  /// The envelope started or starting now; null when none is.
  _EnvelopeSession? _session;

  /// The jobs whose envelope the platform refused in this run: they run in
  /// process and start no envelope again, though they join one another job
  /// starts.
  final Set<TransferId> _declined = {};
  bool _reportedUnconfigured = false;

  /// Set while the jobs of an envelope the system or the user ended leave
  /// it one by one: the jobs not yet paused or cancelled must not start a
  /// new one.
  bool _envelopeHeld = false;
  int _envelopesStarted = 0;
  int _envelopesEndedBySystem = 0;
  Timer? _pruneTimer;
  TrackedContent? _tracked;

  /// A publish job changed: what the view by content key reads may have
  /// moved.
  void _publishChanged() => _tracked?.refresh();

  // --- Queries ---------------------------------------------------------------

  /// Snapshots of every transfer job [filter] passes, oldest first: the
  /// current list on listen, then the list again whenever it changes.
  ///
  /// A completed job stays in it for [retention], then leaves it; a
  /// cancelled job leaves it at once.
  Stream<List<TransferJob>> watch([
    TransferFilter filter = const TransferFilter(),
  ]) => Stream.multi((controller) {
    final watch = _Watch(filter, controller, _select(filter));
    controller.add(watch.last);
    if (_disposed) {
      unawaited(controller.close());
      return;
    }
    _watchers.add(watch);
    controller.onCancel = () => _watchers.remove(watch);
  });

  /// The jobs seen by content, as the core's [TrackedTransfers] seam: the
  /// composition root hands it to the asset cache scope
  /// (`AssetCacheScope(tracked:)`) and to savers.
  ///
  /// Its `watch(key)` maps a job's state onto the value a surface shows, in
  /// both directions: queued is waiting, running is receiving (a download)
  /// or sending (an upload of a publish job item whose local key is the
  /// key), paused by the user or waiting to resume after a restart is
  /// awaitingUser, paused by the system or for the network is the last
  /// receiving or sending value held, failed is failed, and completed is
  /// none for a download. An item whose uploads completed reads sent until
  /// its job published and aliased its server keys, then none. Watching a
  /// key whose download came back [PauseReason.awaitingResume] resumes it.
  /// `cancel(key)` pauses a download for the user, and removes an upload's
  /// item from its publish job (as a cell's, `itemRemoved` by: cell).
  /// `download(key)` resumes or retries a key's upload the user paused or
  /// that failed. `leaseFile(key)` lends the cached file once the content
  /// is whole.
  ///
  /// Throws a [StateError] when the facade was opened with neither
  /// downloads nor uploads to publish.
  TrackedTransfers get tracked =>
      _tracked ??
      (throw StateError(
        'Transfers was opened without downloads or uploads to publish.',
      ));

  /// The reuse table: sending the same media again without preparing or
  /// uploading it again. A publish job looks each item up in it before
  /// preparing and stores what the item's upload answered.
  ///
  /// Throws a [StateError] when the facade was built without one.
  ReuseTable get reuse =>
      _reuse ??
      (throw StateError('Transfers was built without a reuse table.'));

  /// The engine's state now, for a debug panel.
  TransfersDebugSnapshot debugSnapshot() => TransfersDebugSnapshot(
    jobs: [
      for (final job in _journal.jobs)
        if (job.state is! TransferState$Completed) job,
    ],
    online: _online,
    journal: _journal.debugSnapshot(),
    uploads: _uploads?.debugSnapshot(),
    connections: _uploads?.slots.debugSnapshot(),
    reuse: _reuse?.debugSnapshot(),
    publish: _publish?.debugSnapshot(),
    envelope: _envelopeDebugSnapshot(),
  );

  EnvelopeDebugSnapshot? _envelopeDebugSnapshot() {
    final envelope = _envelope;
    if (envelope == null) return null;
    final config = _envelopeConfig;
    final session = _session;
    return EnvelopeDebugSnapshot(
      state: switch (session) {
        _ when config == null => EnvelopeDebugState.unconfigured,
        null => EnvelopeDebugState.idle,
        _EnvelopeSession(handle: null) => EnvelopeDebugState.starting,
        _ => EnvelopeDebugState.started,
      },
      rule: config?.startRule ?? envelope.startRule,
      kind: session?.kind,
      handle: session?.handle,
      jobs: session?.progress.jobs ?? const {},
      submitAt: config?.submitAt,
      submitDueAt: session?.submitDueAt,
      started: _envelopesStarted,
      endedBySystem: _envelopesEndedBySystem,
    );
  }

  /// The jobs whose notification the user tapped, as the envelope's native
  /// part reports them: each tap sends the [TransferId] the notification
  /// showed, for the host to route (to the chat a message is sent in, to a
  /// downloads screen). A broadcast stream; taps before a listener are not
  /// kept.
  Stream<TransferId> get notificationTaps => _notificationTaps.stream;

  // --- Signals ---------------------------------------------------------------

  /// The device's connectivity changed to [online].
  ///
  /// Coming online resumes every job paused [PauseReason.awaitingNetwork].
  /// Going offline stops nothing by itself: a transfer that then fails on
  /// the network pauses instead of failing.
  void connectivityChanged({required bool online}) {
    if (_disposed || online == _online) return;
    _online = online;
    var affected = 0;
    if (online) {
      for (final job in _jobsPaused(PauseReason.awaitingNetwork)) {
        _resume(job);
        affected++;
      }
    }
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      SchedulerOp.connectivityChanged,
      fields: () => {'online': online, 'jobsAffected': affected},
    );
  }

  // --- Verbs -----------------------------------------------------------------

  /// Pauses job [id] for the user, keeping what it moved.
  ///
  /// Applies to a queued or running job, and to one paused for another
  /// reason (it then waits for [resume] alone). Answers whether the job
  /// changed: false for an unknown id, a job the user already paused, a
  /// failed or a completed one.
  bool pause(TransferId id) {
    final job = _job(id);
    if (job == null) return false;
    switch (job.state) {
      case TransferState$Queued() || TransferState$Running():
        _stopRun(id);
      case TransferState$Paused(reason: PauseReason.user):
        return false;
      case TransferState$Paused():
        break;
      case TransferState$Failed() || TransferState$Completed():
        return false;
    }
    _pause(job, PauseReason.user);
    return true;
  }

  /// Puts paused job [id] back in the queue, whatever paused it.
  ///
  /// Answers whether the job changed: false for an unknown id or a job that
  /// is not paused.
  bool resume(TransferId id) {
    final job = _job(id);
    if (job == null || job.state is! TransferState$Paused) return false;
    _resume(job);
    return true;
  }

  /// Puts failed job [id] back in the queue for another attempt.
  ///
  /// For an upload, [source] replaces what it reads: the host's way back
  /// from a lost source (the user picked the file again). On the VM, where
  /// an upload reads a file, a [SourceBytes.file] is read where it is and
  /// bytes in memory are written to a file of the engine's own first, so
  /// the job queues once they are; on the web, where an upload reads the
  /// page's source, it is copied as a new upload's source is. The upload
  /// then starts from zero, since parts sent from one source say nothing
  /// about another; the job and its id stay. A download ignores [source].
  ///
  /// Answers whether the job changed: false for an unknown id or a job that
  /// has not failed.
  bool retry(TransferId id, {SourceBytes? source}) {
    final job = _job(id);
    if (job == null || job.state is! TransferState$Failed) return false;
    final uploads = _uploads;
    if (source == null ||
        uploads == null ||
        _journal.record(id)?.upload == null) {
      _queue(job.copyWith(state: TransferState.queued(total: job.state.total)));
      return true;
    }
    if (uploads.readsPageSources) {
      uploads.keepPageSource(id, source);
      _copySources(id, [source]);
      _retryFrom(job, size: source.size);
    } else if (source case SourceBytes$File(:final path)) {
      _retryFrom(job, size: source.size, path: path);
    } else {
      unawaited(_writeThenRetry(uploads, job, source));
    }
    return true;
  }

  /// Queues failed upload [job] again from zero over a source of [size]
  /// bytes, at [path] when it is a file of its own.
  void _retryFrom(TransferJob job, {required int size, String? path}) {
    _journal.amendUpload(
      job.id,
      (upload) => upload.copyWith(
        source: JournalSource(
          path: path ?? upload.source.path,
          size: size,
          fingerprint: upload.source.fingerprint,
        ),
        parts: const {},
        highWaterMark: 0,
        clearResumeToken: true,
      ),
    );
    _queue(job.copyWith(state: TransferState.queued(total: size)));
  }

  /// On the VM: writes [source], bytes in memory, to a file of the engine's
  /// own, then queues failed upload [job] over it. A write the file system
  /// refuses is reported and leaves the job failed.
  Future<void> _writeThenRetry(
    UploadEngine uploads,
    TransferJob job,
    SourceBytes source,
  ) async {
    final String path;
    try {
      path = await uploads.writeSource(job.id.value, source);
    } on Object catch (_, stackTrace) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        JournalOp.writeFailed,
        jobId: job.id,
        fields: () => {'code': 'source_write'},
        stackTrace: stackTrace,
      );
      return;
    }
    final now = _job(job.id);
    if (_disposed || now == null || now.state is! TransferState$Failed) {
      return unawaited(uploads.releaseSources(job.id.value));
    }
    _retryFrom(now, size: source.size, path: path);
  }

  /// Cancels job [id]: its transfer stops and the job is removed. There is
  /// no cancelled state; watchers see the job leave.
  ///
  /// Applies in every state, a completed job included (it leaves the query
  /// before its retention ends). An upload of a publish job's item takes
  /// the item out of its job, which goes on with the rest
  /// (`PublishJob.removeItem`). Answers false for an unknown id.
  bool cancel(TransferId id) => _cancel(id, by: CancelledBy.user);

  /// [cancel], reported as made [by] the user or the job's owner.
  bool _cancel(TransferId id, {required CancelledBy by}) {
    final job = _job(id);
    if (job == null) return false;
    final owner = _journal.record(id)?.upload?.owner;
    _stopRun(id);
    _queuedAt.remove(id);
    _journal.remove(id);
    if (owner != null) {
      // A user's cancel of one upload drops its item from the job; the
      // job's own cancels only tell it.
      if (by == CancelledBy.user) {
        _publish?.uploadCancelled(owner);
      } else {
        _publish?.uploadChanged(job, owner);
      }
    }
    _deleteSources(id);
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      SchedulerOp.cancelled,
      jobId: id,
      mediaKey: job.key,
      tag: job.tag,
      fields: () => {'by': by.name, 'durability': job.durability.name},
    );
    _changed();
    return true;
  }

  /// Needs job [id]'s bytes at [priority] from now on.
  ///
  /// Answers whether the job changed: false for an unknown id, a completed
  /// job, or the priority it already has.
  bool setPriority(TransferId id, RequestPriority priority) {
    final job = _job(id);
    if (job == null ||
        job.state is TransferState$Completed ||
        job.priority == priority) {
      return false;
    }
    _put(job.copyWith(priority: priority));
    _runnerOf(job).reprioritize(id, priority);
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      SchedulerOp.priorityChanged,
      jobId: id,
      mediaKey: job.key,
      fields: () => {'from': job.priority.name, 'to': priority.name},
    );
    return true;
  }

  /// Starts, or joins, the tracked download of [key]'s content, and answers
  /// its job's id.
  ///
  /// One job per key, its id derived from the key's cache key: a second
  /// call while the job is queued or running returns it; a call for a job
  /// paused by the user or waiting to resume resumes it, for a failed one
  /// retries it, and for a completed one whose content the cache no longer
  /// holds whole downloads it again. The bytes stay in the bytes cache.
  ///
  /// [origin] sets whether the job resumes by itself after the process
  /// ended: a [TransferOrigin.user] download does, a [TransferOrigin.auto]
  /// one comes back paused [PauseReason.awaitingResume] until a surface
  /// watches its key. [resumeOnStart] overrides that for this job; a user
  /// call for a job an auto origin started makes it resume. [priority] places
  /// a new job in the cache's queue (later, [setPriority] moves it);
  /// [durability] and [tag] are those of a new job.
  ///
  /// Throws a [StateError] when the facade was opened without downloads.
  TransferId download(
    MediaKey key, {
    TransferOrigin origin = TransferOrigin.user,
    bool? resumeOnStart,
    RequestPriority priority = RequestPriority.visible,
    TransferDurability durability = TransferDurability.inProcess,
    String? tag,
  }) {
    final store = _downloadRunner?.downloads.store;
    if (store == null) {
      throw StateError('Transfers was opened without downloads.');
    }
    final cacheKey = _cacheKeyOf(key);
    final id = TransferId.forDownload(cacheKey);
    var job = _job(id);
    if (job case TransferJob(
      state: TransferState$Completed(),
    ) when !store.contains(BytesCacheKey(cacheKey))) {
      // The cache let the content go since: a new download.
      _journal.remove(id);
      job = null;
    }
    // A new job takes the origin's default; an existing one changes only for
    // an explicit flag or a user's call.
    final resumes = switch ((resumeOnStart, job)) {
      (final bool flag, _) => flag,
      (null, null) => origin == TransferOrigin.user,
      (null, final TransferJob existing) =>
        origin == TransferOrigin.user || existing.resumeOnStart,
    };
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      SchedulerOp.downloadRequested,
      jobId: id,
      mediaKey: key,
      fields: () => {
        'origin': origin.name,
        'resumeOnStart': resumes,
        'existing': job != null,
      },
    );
    if (job == null) {
      return enqueue(
        direction: TransferDirection.download,
        durability: durability,
        key: key,
        tag: tag,
        priority: priority,
        resumeOnStart: resumes,
      );
    }
    if (job.resumeOnStart != resumes) {
      _put(job = job.copyWith(resumeOnStart: resumes));
    }
    switch (job.state) {
      case TransferState$Paused(
        reason: PauseReason.user || PauseReason.awaitingResume,
      ):
        resume(id);
      case TransferState$Failed():
        retry(id);
      case TransferState$Queued() ||
          TransferState$Running() ||
          TransferState$Paused() ||
          TransferState$Completed():
        break;
    }
    return id;
  }

  // --- Publish jobs ----------------------------------------------------------

  /// Makes a publish job for [request]: its items are looked up in the
  /// reuse table, prepared and uploaded, then the publisher registered as
  /// `request.publisher` is called once with every item's remote
  /// references, the payload and one idempotency key, the request's or one
  /// the engine makes. The job is journaled, so it survives a restart, and
  /// its uploads are transfer jobs [watch] sees, with the request's tag.
  ///
  /// Throws a [PreparationUnavailable] when an item needs preparation and
  /// the facade was opened without a `MediaPreparation`, an [ArgumentError]
  /// for an item id given twice or a transport the facade does not have,
  /// and a [StateError] when the facade runs no uploads.
  PublishJob publish(PublishRequest request) => _publishJobs.publish(request);

  /// Uploads [item] on its own, with no publisher: a publish job of one
  /// item that completes once the item is uploaded, its remote reference in
  /// the item's state. [transport] is the transport's id (the facade's
  /// first unless given); [tag] and [durability] are the job's.
  ///
  /// Throws as [publish] does.
  PublishJob upload(
    PublishItem item, {
    String? transport,
    String? tag,
    TransferDurability durability = TransferDurability.system,
  }) => _publishJobs.upload(
    item,
    transport: transport,
    tag: tag,
    durability: durability,
  );

  /// Registers [publisher] under [id] (the host's name for it), replacing
  /// any registered before. Done at app start: a publish job whose
  /// publisher is not registered waits for it, after a restart too, and
  /// publishes once it is.
  ///
  /// Throws a [StateError] when the facade runs no uploads.
  void registerPublisher(String id, Publisher publisher) =>
      _publishJobs.registerPublisher(id, publisher);

  /// The publish job [id], for an owner that kept its id across a restart;
  /// null when there is no such job (a completed one leaves after
  /// [retention]).
  ///
  /// Throws a [StateError] when the facade runs no uploads.
  PublishJob? publishJob(PublishJobId id) => _publishJobs.job(id);

  /// Snapshots of every publish job [filter] passes, oldest first, for a
  /// surface that shows a host's jobs (a banner, a list of posts, the
  /// bubbles of one conversation by its tag prefix): the current list on
  /// listen, then the list again whenever one of its jobs changes, its
  /// progress included. After a restart the list is the journal's, the
  /// jobs waiting for their publisher among them; a completed job stays
  /// for [retention].
  ///
  /// Throws a [StateError] when the facade runs no uploads.
  Stream<List<PublishJobSnapshot>> watchJobs([
    PublishJobFilter filter = const PublishJobFilter(),
  ]) => _publishJobs.watchJobs(filter);

  PublishJobs get _publishJobs =>
      _publish ??
      (throw StateError('Transfers was built without uploads to publish.'));

  // --- Entry for the package's own paths -------------------------------------

  /// The cache key of [key]'s content: the composition root's mapping.
  @internal
  String cacheKeyOf(MediaKey key) => _cacheKeyOf(key);

  /// Job [id] now, or null when there is none.
  @internal
  TransferJob? jobOf(TransferId id) => _job(id);

  /// Makes a job and queues it, or for a download whose key already has a
  /// job, answers that job's id and changes nothing.
  ///
  /// The public entry points (downloads, uploads, publish jobs) build on
  /// this as they land.
  @internal
  TransferId enqueue({
    required TransferDirection direction,
    required TransferDurability durability,
    MediaKey? key,
    String? tag,
    RequestPriority priority = RequestPriority.visible,
    int? total,
    bool resumeOnStart = true,
    List<SourceBytes> sources = const [],
    JournalUpload? upload,
    TransferId? id,
  }) {
    assert(
      direction == TransferDirection.upload || key != null,
      'A download needs the key of the content it fetches.',
    );
    assert(
      direction == TransferDirection.upload || sources.isEmpty,
      'Only an upload has sources.',
    );
    assert(
      id == null || direction == TransferDirection.upload,
      "A download's id is derived from its key.",
    );
    final jobId = switch (direction) {
      TransferDirection.download => TransferId.forDownload(_cacheKeyOf(key!)),
      TransferDirection.upload => id ?? TransferId.issue(),
    };
    if (_job(jobId) != null) return jobId;
    final now = _now();
    final job = TransferJob(
      id: jobId,
      direction: direction,
      durability: durability,
      state: TransferState.queued(total: total),
      createdAt: now,
      updatedAt: now,
      tag: tag,
      key: key,
      priority: priority,
      resumeOnStart: resumeOnStart,
    );
    // An upload's facts ride in with its first state write, so the journal
    // never holds the job without them.
    if (upload != null) _journal.stage(JournalRecord(job: job, upload: upload));
    if (sources.firstOrNull case final source?) {
      _uploads?.keepPageSource(jobId, source);
    }
    _queue(job);
    if (direction == TransferDirection.upload) _copySources(jobId, sources);
    return jobId;
  }

  /// Completes once every source copy begun so far has ended.
  @internal
  Future<void> get debugSourcesCopied async {
    while (_$copies.isNotEmpty) {
      await Future.wait([..._$copies]);
    }
  }

  /// Stops listening to the lifecycle and the envelope, ends every query
  /// and stops every run; completes once the journal and the reuse table
  /// have written what they still held and closed. The jobs stay in the
  /// journal.
  Future<void> dispose() {
    _shutDown();
    return Future.wait([
      _journal.close(),
      ?_reuse?.close(),
      ?_publish?.journal.close(),
    ]);
  }

  /// Stops as a killed process would: everything [dispose] stops, but the
  /// journal writes nothing more, losing the progress it still batched.
  @internal
  void debugKill() {
    _shutDown();
    _journal.abandon();
    _reuse?.abandon();
    _publish?.journal.abandon();
  }

  void _shutDown() {
    if (_disposed) return;
    _disposed = true;
    _unloadWarning?.disarm();
    _lifecycle.removeListener(_onLifecycle);
    unawaited(_envelopeEvents?.cancel());
    unawaited(_notificationTaps.close());
    _pruneTimer?.cancel();
    _systemActive.dispose();
    _publish?.shutDown();
    [..._runs.keys].forEach(_stopRun);
    for (final watch in [..._watchers]) {
      unawaited(watch.controller.close());
    }
    _watchers.clear();
  }

  // --- Transitions -----------------------------------------------------------

  /// Puts [job], already in its queued state, in the store and starts it.
  void _queue(TransferJob job) {
    assert(job.state is TransferState$Queued, 'only a queued job starts');
    final queued = job.copyWith(updatedAt: _now());
    _queuedAt[queued.id] = queued.updatedAt;
    _put(queued);
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      SchedulerOp.jobQueued,
      jobId: queued.id,
      mediaKey: queued.key,
      tag: queued.tag,
      fields: () => {
        'direction': queued.direction.name,
        'lane': ?_laneOf(queued.id),
        'durability': queued.durability.name,
        'priority': queued.priority.name,
      },
    );
    _startRun(queued);
    _reportNoEnvelope(queued);
  }

  void _pause(TransferJob job, PauseReason reason) {
    _put(
      job.copyWith(
        state: TransferState.paused(
          reason: reason,
          done: job.state.done,
          total: job.state.total,
        ),
        updatedAt: _now(),
      ),
    );
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      SchedulerOp.paused,
      jobId: job.id,
      mediaKey: job.key,
      tag: job.tag,
      fields: () => {'reason': reason.name, 'durability': job.durability.name},
    );
  }

  /// Moves paused [job] back to queued and starts it.
  void _resume(TransferJob job) {
    final left = (job.state as TransferState$Paused).reason;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      SchedulerOp.resumed,
      jobId: job.id,
      mediaKey: job.key,
      tag: job.tag,
      fields: () => {'reason': left.name, 'durability': job.durability.name},
    );
    _queue(job.copyWith(state: TransferState.queued(total: job.state.total)));
  }

  void _onProgress(
    _Run run,
    int done, {
    required int? total,
    required bool estimated,
  }) {
    final job = _job(run.id);
    if (job == null) return;
    if (job.state is TransferState$Queued) {
      final queuedAt = _queuedAt.remove(job.id) ?? job.updatedAt;
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        SchedulerOp.jobStarted,
        jobId: job.id,
        tag: job.tag,
        fields: () => {
          'lane': ?_laneOf(job.id),
          'durability': job.durability.name,
          'waitedMs': _now().difference(queuedAt).inMilliseconds,
        },
      );
    }
    final next = job.copyWith(
      state: TransferState.running(
        done: done,
        total: total,
        estimated: estimated,
      ),
      updatedAt: _now(),
    );
    // Entering running is a state change, written at once; moving on while
    // running is progress, batched.
    if (job.state is TransferState$Running) {
      _journal.writeProgress(next);
      _changed();
      _toOwner(next);
    } else {
      _put(next);
    }
  }

  void _onComplete(_Run run, TransferResult result) {
    final job = _job(run.id);
    if (job == null) return;
    _endRun(run);
    final now = _now();
    _put(job.copyWith(state: TransferState.completed(result), updatedAt: now));
    _deleteSources(job.id);
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      SchedulerOp.completed,
      jobId: job.id,
      mediaKey: job.key,
      tag: job.tag,
      fields: () => {
        'durability': job.durability.name,
        'bytes': job.state.total ?? job.state.done,
        'ms': now.difference(job.createdAt).inMilliseconds,
      },
    );
  }

  void _onFail(_Run run, TransferFailureKind kind, {required bool retryable}) {
    final job = _job(run.id);
    if (job == null) return;
    _endRun(run);
    if (kind == TransferFailureKind.network && !_online) {
      _pause(job, PauseReason.awaitingNetwork);
      return;
    }
    final done = job.state.done;
    final total = job.state.total;
    _put(
      job.copyWith(
        state: TransferState.failed(
          kind: kind,
          retryable: retryable,
          done: done,
          total: total,
        ),
        updatedAt: _now(),
      ),
    );
    MpxDiagnostics.current.emit(
      MpxEventLevel.error,
      SchedulerOp.failed,
      jobId: job.id,
      mediaKey: job.key,
      tag: job.tag,
      fields: () => {
        'kind': kind.name,
        'durability': job.durability.name,
        'retryable': retryable,
        'done': done,
        'total': ?total,
      },
    );
  }

  void _onLifecycle() {
    final previous = _lastLifecycle;
    _lastLifecycle = _lifecycle.state;
    if (_disposed ||
        _lastLifecycle != AppLifecycleState.resumed ||
        previous == AppLifecycleState.resumed) {
      return;
    }
    _jobsPaused(PauseReason.systemInterrupted).forEach(_resume);
  }

  void _onEnvelopeEvent(TransferEnvelopeEvent event) {
    if (_disposed) return;
    switch (event) {
      case TransferEnvelopeEvent$SystemEnded(:final cause):
        final inside = _session?.progress.jobs ?? const <TransferId>{};
        _endBySystem(inside, cause);
      case TransferEnvelopeEvent$UserCancelledAll():
        _cancelEnvelope();
      case TransferEnvelopeEvent$NotificationTap(:final id):
        MpxDiagnostics.current.emit(
          MpxEventLevel.info,
          EnvelopeOp.notificationTap,
          jobId: id,
        );
        _notificationTaps.add(id);
      case TransferEnvelopeEvent$Changed(:final kind, :final submitDueAt):
        final session = _session;
        if (session == null) return;
        session
          ..kind = kind
          ..submitDueAt = submitDueAt;
    }
  }

  /// The system ended the envelope over [inside]: nothing is deleted, and
  /// each of those jobs still moving pauses [PauseReason.systemInterrupted]
  /// until the app is in the foreground again. Answers how many paused.
  int _endBySystem(
    Iterable<TransferId> inside,
    TransferEnvelopeEndCause cause,
  ) {
    // The system already ended it: nothing to stop, and a job resumed
    // later starts a new one.
    if (_session != null) _envelopesEndedBySystem++;
    _session = null;
    final interrupted = inside
        .map(_job)
        .nonNulls
        .where((job) => job.state.isActive)
        .toList();
    MpxDiagnostics.current.emit(
      MpxEventLevel.warning,
      EnvelopeOp.systemEnded,
      jobId: interrupted.firstOrNull?.id,
      fields: () => {'jobs': interrupted.length, 'cause': cause.name},
    );
    _envelopeHeld = true;
    try {
      for (final job in interrupted) {
        _stopRun(job.id);
        _pause(job, PauseReason.systemInterrupted);
      }
    } finally {
      _envelopeHeld = false;
    }
    _syncEnvelope();
    return interrupted.length;
  }

  /// The user cancelled every job in the envelope from the system's UI:
  /// each is cancelled, and a publish job one of them belongs to is
  /// cancelled whole, its other uploads with it, so its owner sees it
  /// leave.
  void _cancelEnvelope() {
    final inside = [...?_session?.progress.jobs];
    _session = null;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      EnvelopeOp.userCancelledAll,
      jobId: inside.firstOrNull,
      fields: () => {'jobs': inside.length},
    );
    final cancelled = <TransferId>{...inside};
    final owners = <PublishJobId>{
      for (final id in inside)
        if (_journal.record(id)?.upload?.owner case final owner?)
          PublishJobId.parse(owner.job),
    };
    for (final owner in owners) {
      cancelled.addAll(
        _publish?.cancel(owner, by: CancelledBy.envelope) ?? const [],
      );
    }
    _envelopeHeld = true;
    try {
      for (final id in cancelled) {
        _cancel(id, by: CancelledBy.envelope);
      }
    } finally {
      _envelopeHeld = false;
    }
    _syncEnvelope();
  }

  /// Debug builds only: acts as if the system ended the OS envelope now,
  /// for a debug panel's "simulate a system interruption".
  ///
  /// Every `system` job that is queued or running pauses
  /// [PauseReason.systemInterrupted], as the jobs of a real envelope do
  /// (on a platform without an envelope too), and the live envelope is
  /// stopped, as the system would have ended it. The jobs resume once the
  /// app comes back to the foreground. Answers how many jobs paused; in a
  /// release build does nothing and answers 0.
  int debugSimulateSystemInterruption() {
    var interrupted = 0;
    assert(() {
      interrupted = _simulateSystemInterruption();
      return true;
    }(), 'never fails: runs the simulation in debug builds only');
    return interrupted;
  }

  int _simulateSystemInterruption() {
    if (_disposed) return 0;
    final live = _session != null;
    final interrupted = _endBySystem([
      for (final job in _journal.jobs)
        if (job.durability == TransferDurability.system && job.state.isActive)
          job.id,
    ], TransferEnvelopeEndCause.simulated);
    if (live) _envelope?.stop();
    return interrupted;
  }

  // --- Runs ------------------------------------------------------------------

  TransferRunner _runnerOf(TransferJob job) => switch (job.direction) {
    TransferDirection.download => _downloadRunner ?? _runner,
    TransferDirection.upload => _runner,
  };

  void _startRun(TransferJob job) {
    _stopRun(job.id);
    final run = _Run(this, job.id, _runnerOf(job));
    _runs[job.id] = run;
    run.runner.start(job, run);
  }

  void _stopRun(TransferId id) {
    final run = _runs.remove(id);
    if (run == null) return;
    run.ended = true;
    run.runner.stop(id);
  }

  void _endRun(_Run run) {
    run.ended = true;
    if (identical(_runs[run.id], run)) _runs.remove(run.id);
  }

  // --- Store, watchers, envelope, retention -----------------------------------

  /// Takes over the envelope an earlier process left, when a job that was
  /// moving names one of [live] in its record: the native part kept it
  /// while Dart was gone. Any other live envelope has no job left and is
  /// stopped.
  void _adoptLiveEnvelope(Set<String> live) {
    final envelope = _envelope;
    if (envelope == null || live.isEmpty) return;
    final config = _envelopeConfig;
    String? handle;
    if (config != null) {
      for (final job in _journal.jobs) {
        if (job.durability != TransferDurability.system ||
            !job.state.isActive) {
          continue;
        }
        final named = _journal.record(job.id)?.envelopeHandle;
        if (named != null && live.contains(named)) {
          handle = named;
          break;
        }
      }
    }
    if (config == null || handle == null) {
      envelope.stop();
      MpxDiagnostics.current.emit(
        MpxEventLevel.info,
        EnvelopeOp.withdrawn,
        fields: () => {'why': 'drained'},
      );
      return;
    }
    final inside = _envelopeJobs();
    final progress = _progressOf(inside);
    _session = _EnvelopeSession(progress, handle: handle);
    _envelopesStarted++;
    envelope.adopt(handle, progress, config);
    final adopted = handle;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      EnvelopeOp.started,
      fields: () => {'handle': adopted, 'adopted': true},
    );
  }

  /// What a previous engine over the same journal left: a job that was moving
  /// starts again, except a download nobody asked to resume, which waits
  /// paused for its content to be shown again. A job the system interrupted
  /// starts again when the app is already in the foreground.
  void _restore() {
    _prune();
    _loseSources();
    for (final job in [..._journal.jobs]) {
      if (job.state case TransferState$Paused(
        reason: PauseReason.systemInterrupted,
      ) when _lifecycle.state == AppLifecycleState.resumed) {
        _resume(job);
        continue;
      }
      if (!job.state.isActive) continue;
      if (job.direction == TransferDirection.download && !job.resumeOnStart) {
        _pause(job, PauseReason.awaitingResume);
      } else {
        _queue(
          job.copyWith(state: TransferState.queued(total: job.state.total)),
        );
      }
    }
  }

  TransferJob? _job(TransferId id) => _journal.job(id);

  /// An upload's lane, for its scheduler events; null for a download.
  String? _laneOf(TransferId id) => _journal.record(id)?.upload?.lane.name;

  List<TransferJob> _jobsPaused(PauseReason reason) => [
    for (final job in _journal.jobs)
      if (job.state case TransferState$Paused(reason: final r) when r == reason)
        job,
  ];

  List<TransferJob> _select(TransferFilter filter) =>
      _journal.jobs.where(filter.matches).toList(growable: false);

  void _put(TransferJob job) {
    _journal.writeState(job);
    _changed();
    _toOwner(job);
  }

  /// Tells the publish job that owns upload [job] that it moved.
  void _toOwner(TransferJob job) {
    final owner = _journal.record(job.id)?.upload?.owner;
    if (owner != null) _publish?.uploadChanged(job, owner);
  }

  void _changed() {
    if (_disposed) return;
    _tracked?.refresh();
    for (final watch in [..._watchers]) {
      final next = _select(watch.filter);
      if (_sameJobs(next, watch.last)) continue;
      watch.last = next;
      watch.controller.add(next);
    }
    _syncEnvelope();
    _syncUnloadWarning();
    _syncSystemActive();
    _schedulePrune();
  }

  /// Keeps [systemActive] true while a `system` job is queued or running.
  void _syncSystemActive() {
    _systemActive.value = _journal.jobs.any(
      (job) =>
          job.durability == TransferDurability.system && job.state.isActive,
    );
  }

  /// Arms the page's warning while any job is queued or running.
  void _syncUnloadWarning() {
    final warning = _unloadWarning;
    if (warning == null) return;
    if (_journal.jobs.any((job) => job.state.isActive)) {
      warning.arm();
    } else {
      warning.disarm();
    }
  }

  /// Keeps the envelope over the `system` jobs that are queued or running:
  /// started when one of them meets the start rule ([_startsEnvelope]),
  /// updated as they move (a job the rule would not start joins one
  /// started), stopped when none is left.
  void _syncEnvelope() {
    final envelope = _envelope;
    final config = _envelopeConfig;
    if (envelope == null || config == null || _envelopeHeld || _disposed) {
      return;
    }
    final inside = _envelopeJobs();
    final session = _session;
    if (session == null) {
      final trigger = inside.where(_startsEnvelope).firstOrNull;
      if (trigger == null) return;
      _startEnvelope(envelope, config, trigger, inside);
      return;
    }
    if (inside.isEmpty) {
      _session = null;
      envelope.stop();
      MpxDiagnostics.current.emit(
        MpxEventLevel.info,
        EnvelopeOp.withdrawn,
        fields: () => {'why': 'drained'},
      );
      return;
    }
    final progress = session.fold(_progressOf(inside));
    if (progress == session.progress) return;
    session.progress = progress;
    envelope.update(progress);
    _writeEnvelopeHandle(session);
  }

  void _startEnvelope(
    TransferEnvelope envelope,
    TransferEnvelopeConfig config,
    TransferJob trigger,
    List<TransferJob> inside,
  ) {
    final progress = _progressOf(inside);
    final session = _session = _EnvelopeSession(progress);
    final rule = _startRule;
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      EnvelopeOp.startRequested,
      jobId: trigger.id,
      fields: () => {'jobs': inside.length, 'rule': rule.name},
    );
    unawaited(_awaitStart(envelope.start(progress, config), session));
  }

  /// Takes the answer of the start of [session]. The envelope may have
  /// been stopped or ended meanwhile; a refusal still counts.
  Future<void> _awaitStart(
    Future<TransferEnvelopeStart> starting,
    _EnvelopeSession session,
  ) async {
    TransferEnvelopeStart answer;
    try {
      answer = await starting;
    } on Object catch (_, stackTrace) {
      // The error stays out: a platform error may name app state.
      answer = const TransferEnvelopeStart.refused('error');
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        EnvelopeOp.refused,
        fields: () => {'code': 'error'},
        stackTrace: stackTrace,
      );
    }
    if (_disposed) return;
    final current = identical(_session, session);
    switch (answer) {
      case TransferEnvelopeStart$Started(:final handle, :final kind):
        _envelopesStarted++;
        MpxDiagnostics.current.emit(
          MpxEventLevel.info,
          EnvelopeOp.started,
          fields: () => {
            'handle': handle,
            'kind': ?kind?.name,
            'adopted': false,
          },
        );
        if (!current) return;
        session
          ..handle = handle
          ..kind = kind;
        _writeEnvelopeHandle(session);
      case TransferEnvelopeStart$Refused(:final code):
        if (code != 'error') {
          MpxDiagnostics.current.emit(
            MpxEventLevel.warning,
            EnvelopeOp.refused,
            fields: () => {'code': code},
          );
        }
        MpxDiagnostics.current.emit(
          MpxEventLevel.warning,
          EnvelopeOp.degraded,
          jobId: session.progress.jobs.firstOrNull,
          fields: () => {
            'from': TransferDurability.system.name,
            'to': TransferDurability.inProcess.name,
            'why': 'refused',
          },
        );
        if (!current) return;
        _declined.addAll(session.progress.jobs);
        _session = null;
    }
  }

  /// Journals the handle of [session], once started, with each job inside.
  void _writeEnvelopeHandle(_EnvelopeSession session) {
    final handle = session.handle;
    if (handle == null) return;
    for (final id in session.progress.jobs) {
      _journal.writeEnvelopeHandle(id, handle);
    }
  }

  /// The `system` jobs queued or running: what an envelope holds.
  List<TransferJob> _envelopeJobs() => [
    for (final job in _journal.jobs)
      if (job.durability == TransferDurability.system && job.state.isActive)
        job,
  ];

  TransferEnvelopeProgress _progressOf(List<TransferJob> inside) {
    final totals = inside.map((job) => job.state.total);
    return TransferEnvelopeProgress(
      jobs: {for (final job in inside) job.id},
      done: inside.fold(0, (sum, job) => sum + job.state.done),
      total: totals.contains(null)
          ? null
          : totals.nonNulls.fold<int>(0, (sum, total) => sum + total),
    );
  }

  /// The host's start rule, else the platform's.
  TransferEnvelopeStartRule get _startRule =>
      _envelopeConfig?.startRule ??
      _envelope?.startRule ??
      TransferEnvelopeStartRule.never;

  /// Whether `system` job [job] starts an envelope by itself.
  bool _startsEnvelope(TransferJob job) {
    if (_declined.contains(job.id)) return false;
    return switch (_startRule) {
      TransferEnvelopeStartRule.always => true,
      TransferEnvelopeStartRule.never => false,
      TransferEnvelopeStartRule.long => _isLong(job),
    };
  }

  /// Whether [job] is long: an upload in the big lane (a video, or a file
  /// over the lane split), or more bytes than the config's
  /// `longJobBytes`, summed over every upload of the publish job it
  /// belongs to.
  bool _isLong(TransferJob job) {
    final limit =
        _envelopeConfig?.longJobBytes ??
        TransferEnvelopeConfig.defaultLongJobBytes;
    final upload = _journal.record(job.id)?.upload;
    if (upload?.lane == UploadLane.big) return true;
    final owner = upload?.owner?.job;
    if (owner == null) return (job.state.total ?? 0) > limit;
    var sum = 0;
    for (final other in _journal.jobs) {
      if (_journal.record(other.id)?.upload?.owner?.job != owner) continue;
      sum += other.state.total ?? 0;
    }
    return sum > limit;
  }

  /// Reports why queued [job] runs without an envelope, when it does: once
  /// per run for an unconfigured envelope, else at each queueing.
  void _reportNoEnvelope(TransferJob job) {
    if (_session?.progress.jobs.contains(job.id) ?? false) return;
    if (job.durability == TransferDurability.system &&
        _envelope != null &&
        _envelopeConfig == null) {
      if (_reportedUnconfigured) return;
      _reportedUnconfigured = true;
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        EnvelopeOp.degraded,
        jobId: job.id,
        fields: () => {
          'from': TransferDurability.system.name,
          'to': TransferDurability.inProcess.name,
          'why': 'unconfigured',
        },
      );
      return;
    }
    // Refused in this run: reported with the refusal.
    if (_declined.contains(job.id)) return;
    final why = switch (job.durability) {
      TransferDurability.inProcess => 'inProcess',
      TransferDurability.system when _envelope == null => 'platform',
      TransferDurability.system => switch (_startRule) {
        TransferEnvelopeStartRule.never => 'never',
        _ => 'short',
      },
    };
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      EnvelopeOp.notStarted,
      jobId: job.id,
      fields: () => {'why': why},
    );
  }

  /// Arms one timer for the completed job whose retention ends first.
  void _schedulePrune() {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    DateTime? first;
    for (final job in _journal.jobs) {
      if (job.state is! TransferState$Completed) continue;
      final expiry = job.updatedAt.add(retention);
      if (first == null || expiry.isBefore(first)) first = expiry;
    }
    if (first == null) return;
    final wait = first.difference(_now());
    _pruneTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
      _pruneTimer = null;
      if (_prune()) _changed();
    });
  }

  /// Forgets the completed jobs past [retention]; answers whether any were.
  bool _prune() {
    final pruned = _journal.prune(retention);
    pruned.forEach(_deleteSources);
    return pruned.isNotEmpty;
  }

  // --- Upload sources on the web -----------------------------------------------

  /// Copies the [sources] of new upload [id] so the job survives a reload,
  /// when they fit [sourceCopyLimit] together. The job runs from the page's
  /// sources meanwhile, so nothing waits for the copy.
  void _copySources(TransferId id, List<SourceBytes> sources) {
    final copies = _sourceCopies;
    if (copies == null || sources.isEmpty) return;
    final bytes = sources.fold(0, (sum, source) => sum + source.size);
    if (bytes > sourceCopyLimit) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.warning,
        JournalOp.sourceOverLimit,
        jobId: id,
        fields: () => {'bytes': bytes, 'limit': sourceCopyLimit},
      );
      return;
    }
    final began = _now();
    final copy = () async {
      try {
        // A retry's new source replaces the copy of the one before; the
        // old copy goes first, so a reload in between finds none.
        if (copies.holds(id)) await copies.delete(id);
        if (!await copies.copy(id, sources)) return;
      } on Object catch (error, stackTrace) {
        _emitSourceFailure(copies, error, stackTrace, id);
        return;
      }
      // Cancelled, or ended by the engine, while it copied.
      if (_disposed || _job(id) == null) {
        _deleteSources(id);
        return;
      }
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        JournalOp.sourceCopied,
        jobId: id,
        fields: () => {
          'bytes': bytes,
          'ms': _now().difference(began).inMilliseconds,
        },
      );
    }();
    _$copies.add(copy);
    unawaited(copy.whenComplete(() => _$copies.remove(copy)));
  }

  /// At a start, fails every upload job whose sources were not kept, and
  /// deletes the copies no job needs any more.
  void _loseSources() {
    final copies = _sourceCopies;
    if (copies == null) return;
    for (final job in [..._journal.jobs]) {
      if (job.direction != TransferDirection.upload || copies.holds(job.id)) {
        continue;
      }
      switch (job.state) {
        case TransferState$Completed() ||
            TransferState$Failed(kind: TransferFailureKind.sourceLost):
          continue;
        default:
          break;
      }
      _put(
        job.copyWith(
          state: TransferState.failed(
            kind: TransferFailureKind.sourceLost,
            retryable: false,
            done: job.state.done,
            total: job.state.total,
          ),
          updatedAt: _now(),
        ),
      );
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        JournalOp.sourceLost,
        jobId: job.id,
      );
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        TransportOp.resumeDecision,
        jobId: job.id,
        fields: () => {'outcome': ResumeOutcome.sourceLost.name, 'offset': 0},
      );
    }
    for (final id in [...copies.held]) {
      if (_job(id)?.state case null || TransferState$Completed()) {
        _deleteSources(id);
      }
    }
  }

  void _deleteSources(TransferId id) {
    // A file a retry wrote for the job, on the VM.
    if (_uploads case final uploads?) {
      unawaited(
        uploads.releaseSources(id.value).catchError((
          Object _,
          StackTrace stackTrace,
        ) {
          MpxDiagnostics.current.emit(
            MpxEventLevel.warning,
            JournalOp.writeFailed,
            jobId: id,
            fields: () => {'code': 'source_delete'},
            stackTrace: stackTrace,
          );
        }),
      );
    }
    final copies = _sourceCopies;
    if (copies == null || !copies.holds(id)) return;
    unawaited(
      copies.delete(id).catchError((Object error, StackTrace stackTrace) {
        _emitSourceFailure(copies, error, stackTrace, id);
      }),
    );
  }

  static void _emitSourceFailure(
    UploadSourceCopies copies,
    Object error,
    StackTrace stackTrace,
    TransferId id,
  ) => MpxDiagnostics.current.emit(
    MpxEventLevel.error,
    JournalOp.writeFailed,
    jobId: id,
    fields: () => {'code': copies.errorCode(error)},
    stackTrace: stackTrace,
  );
}

bool _sameJobs(List<TransferJob> a, List<TransferJob> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The OS envelope the engine started: its jobs and progress, and once the
/// start answered, its handle and what holds the process.
final class _EnvelopeSession {
  _EnvelopeSession(this.progress, {this.handle}) {
    if (progress.total case final total? when total > 0) {
      _shown.fold(progress.done / total);
    }
  }

  TransferEnvelopeProgress progress;

  /// The fraction the system's indicator shows: a job that completes leaves
  /// the envelope with its bytes, and a part tried again drops its own, so
  /// the sum is folded to never go back.
  final ProgressFold _shown = ProgressFold();

  /// [raw], the jobs inside summed now, with its bytes done folded.
  TransferEnvelopeProgress fold(TransferEnvelopeProgress raw) {
    final total = raw.total;
    if (total == null || total <= 0) return raw;
    final done = (_shown.fold(raw.done / total) * total).floor();
    return TransferEnvelopeProgress(
      jobs: raw.jobs,
      done: done.clamp(0, total),
      total: total,
    );
  }

  /// Null while the start has not answered.
  String? handle;
  TransferEnvelopeKind? kind;
  DateTime? submitDueAt;
}

/// One `watch` listener: its filter and the list it saw last.
final class _Watch {
  _Watch(this.filter, this.controller, this.last);

  final TransferFilter filter;
  final MultiStreamController<List<TransferJob>> controller;
  List<TransferJob> last;
}

/// The sink of one run of a job; ignores reports once the run ended, so a
/// runner that reports after a pause or a cancel changes nothing.
final class _Run implements TransferRunSink {
  _Run(this._engine, this.id, this.runner);

  final Transfers _engine;
  final TransferId id;

  /// What moves this run's bytes.
  final TransferRunner runner;
  bool ended = false;

  @override
  void progress(int done, {int? total, bool estimated = false}) {
    if (ended) return;
    _engine._onProgress(this, done, total: total, estimated: estimated);
  }

  @override
  void complete(TransferResult result) {
    if (ended) return;
    _engine._onComplete(this, result);
  }

  @override
  void fail(TransferFailureKind kind, {required bool retryable}) {
    if (ended) return;
    _engine._onFail(this, kind, retryable: retryable);
  }
}

/// The facade as its publish jobs see it.
/// The facade as its publish jobs see it: the journal their uploads are
/// kept in, the bytes cache they alias in, and the facade's verbs on the
/// uploads.
final class _PublishHost implements PublishUploadHost {
  _PublishHost(
    this._engine, {
    required TransferJournal journal,
    required IBytesStore? cache,
    required String Function(MediaKey key) cacheKeyOf,
  }) : _journal = journal,
       _cache = cache,
       _cacheKeyOf = cacheKeyOf;

  final Transfers _engine;
  final TransferJournal _journal;
  final IBytesStore? _cache;
  final String Function(MediaKey key) _cacheKeyOf;

  @override
  JournalRecord? recordOf(TransferId id) => _journal.record(id);

  @override
  Iterable<String> get sourceOwners => [
    for (final record in _journal.records)
      if (record.upload != null && record.job.state is! TransferState$Completed)
        record.job.id.value,
  ];

  @override
  void enqueueUpload(
    TransferId id,
    JournalUpload upload, {
    required TransferDurability durability,
    String? tag,
    MediaKey? key,
    SourceBytes? pageSource,
  }) => _engine.enqueue(
    direction: TransferDirection.upload,
    durability: durability,
    key: key,
    tag: tag,
    total: upload.source.size,
    upload: upload,
    id: id,
    sources: [?pageSource],
  );

  @override
  bool retryUpload(TransferId id, {SourceBytes? source}) =>
      _engine.retry(id, source: source);

  @override
  void cancelUpload(TransferId id) =>
      _engine._cancel(id, by: CancelledBy.owner);

  @override
  void publishChanged() => _engine._publishChanged();

  @override
  Future<bool>? alias(MediaKey local, MediaKey server) => _cache?.alias(
    BytesCacheKey(_cacheKeyOf(local)),
    BytesCacheKey(_cacheKeyOf(server)),
  );
}
