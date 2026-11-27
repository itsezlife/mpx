import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:http_bytes_cache/http_bytes_cache.dart' show RequestPriority;
import 'package:meta/meta.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/envelope_op.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/diagnostics/scheduler_op.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/engine/transfer_runner.dart';
import 'package:mpx_transfer/src/envelope/transfer_envelope.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/platform_journal_store.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/journal/unload_warning.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';

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
  /// package's own runners and test support build on.
  @internal
  Transfers.engine({
    required String Function(MediaKey key) cacheKeyOf,
    required PlaybackLifecycleSource lifecycle,
    required TransferRunner runner,
    required TransferJournal journal,
    TransferEnvelope? envelope,
    UploadSourceCopies? sourceCopies,
    UnloadWarning? unloadWarning,
    this.retention = defaultRetention,
    this.sourceCopyLimit = defaultSourceCopyLimit,
    bool online = true,
    DateTime Function() now = DateTime.now,
  }) : _cacheKeyOf = cacheKeyOf,
       _lifecycle = lifecycle,
       _runner = runner,
       _journal = journal,
       _envelope = envelope,
       _sourceCopies = sourceCopies,
       _unloadWarning = unloadWarning,
       _online = online,
       _now = now,
       _lastLifecycle = lifecycle.state {
    _lifecycle.addListener(_onLifecycle);
    _envelopeEvents = envelope?.events.listen(_onEnvelopeEvent);
    _restore();
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
  /// OS envelope; without one, `system` jobs run in process. [online] is
  /// the connectivity at start; [now] reads the time.
  ///
  /// A journal that cannot be read is reported (`journal` `writeFailed`)
  /// and the engine runs in memory for this run, with no jobs.
  static Future<Transfers> open({
    required String Function(MediaKey key) cacheKeyOf,
    required PlaybackLifecycleSource lifecycle,
    String? directory,
    TransferEnvelope? envelope,
    Duration retention = defaultRetention,
    Duration progressInterval = defaultProgressInterval,
    int sourceCopyLimit = defaultSourceCopyLimit,
    bool online = true,
    DateTime Function() now = DateTime.now,
  }) async {
    final platform = await openJournalPlatform(directory);
    final journal = await TransferJournal.open(
      platform.store,
      retention: retention,
      progressInterval: progressInterval,
      now: now,
    );
    return Transfers.engine(
      cacheKeyOf: cacheKeyOf,
      lifecycle: lifecycle,
      runner: const _NoRunner(),
      journal: journal,
      envelope: envelope,
      sourceCopies: platform.sourceCopies,
      unloadWarning: platform.unloadWarning,
      retention: retention,
      sourceCopyLimit: sourceCopyLimit,
      online: online,
      now: now,
    );
  }

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
  final TransferJournal _journal;
  final TransferEnvelope? _envelope;
  final UploadSourceCopies? _sourceCopies;
  final UnloadWarning? _unloadWarning;
  final DateTime Function() _now;

  /// The source copies under way; see [debugSourcesCopied].
  final Set<Future<void>> _$copies = {};

  bool _online;
  AppLifecycleState? _lastLifecycle;
  bool _disposed = false;

  final Map<TransferId, _Run> _runs = {};
  final Map<TransferId, DateTime> _queuedAt = {};
  final List<_Watch> _watchers = [];
  StreamSubscription<TransferEnvelopeEvent>? _envelopeEvents;
  TransferEnvelopeProgress? _envelopeProgress;
  Timer? _pruneTimer;

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

  /// The engine's state now, for a debug panel.
  TransfersDebugSnapshot debugSnapshot() => TransfersDebugSnapshot(
    jobs: [
      for (final job in _journal.jobs)
        if (job.state is! TransferState$Completed) job,
    ],
    online: _online,
    journal: _journal.debugSnapshot(),
  );

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
  /// Answers whether the job changed: false for an unknown id or a job that
  /// has not failed.
  bool retry(TransferId id) {
    final job = _job(id);
    if (job == null || job.state is! TransferState$Failed) return false;
    _queue(job.copyWith(state: TransferState.queued(total: job.state.total)));
    return true;
  }

  /// Cancels job [id]: its transfer stops and the job is removed. There is
  /// no cancelled state; watchers see the job leave.
  ///
  /// Applies in every state, a completed job included (it leaves the query
  /// before its retention ends). Answers false for an unknown id.
  bool cancel(TransferId id) {
    final job = _job(id);
    if (job == null) return false;
    _stopRun(id);
    _queuedAt.remove(id);
    _journal.remove(id);
    _deleteSources(id);
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      SchedulerOp.cancelled,
      jobId: id,
      mediaKey: job.key,
      tag: job.tag,
      fields: () => {'by': 'user'},
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
    _runner.reprioritize(id, priority);
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      SchedulerOp.priorityChanged,
      jobId: id,
      mediaKey: job.key,
      fields: () => {'from': job.priority.name, 'to': priority.name},
    );
    return true;
  }

  // --- Entry for the package's own paths -------------------------------------

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
  }) {
    assert(
      direction == TransferDirection.upload || key != null,
      'A download needs the key of the content it fetches.',
    );
    assert(
      direction == TransferDirection.upload || sources.isEmpty,
      'Only an upload has sources.',
    );
    final id = switch (direction) {
      TransferDirection.download => TransferId.forDownload(_cacheKeyOf(key!)),
      TransferDirection.upload => TransferId.issue(),
    };
    if (_job(id) != null) return id;
    final now = _now();
    _queue(
      TransferJob(
        id: id,
        direction: direction,
        durability: durability,
        state: TransferState.queued(total: total),
        createdAt: now,
        updatedAt: now,
        tag: tag,
        key: key,
        priority: priority,
        resumeOnStart: resumeOnStart,
      ),
    );
    if (direction == TransferDirection.upload) _copySources(id, sources);
    return id;
  }

  /// Completes once every source copy begun so far has ended.
  @internal
  Future<void> get debugSourcesCopied async {
    while (_$copies.isNotEmpty) {
      await Future.wait([..._$copies]);
    }
  }

  /// Stops listening to the lifecycle and the envelope, ends every query
  /// and stops every run; completes once the journal has written what it
  /// still held and closed. The jobs stay in the journal.
  Future<void> dispose() {
    _shutDown();
    return _journal.close();
  }

  /// Stops as a killed process would: everything [dispose] stops, but the
  /// journal writes nothing more, losing the progress it still batched.
  @internal
  void debugKill() {
    _shutDown();
    _journal.abandon();
  }

  void _shutDown() {
    if (_disposed) return;
    _disposed = true;
    _unloadWarning?.disarm();
    _lifecycle.removeListener(_onLifecycle);
    unawaited(_envelopeEvents?.cancel());
    _pruneTimer?.cancel();
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
        'durability': queued.durability.name,
        'priority': queued.priority.name,
      },
    );
    _startRun(queued);
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
      fields: () => {'reason': reason.name},
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
      fields: () => {'reason': left.name},
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
        fields: () => {'waitedMs': _now().difference(queuedAt).inMilliseconds},
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
    switch (event) {
      case TransferEnvelopeEvent$SystemEnded():
        final inside = _envelopeProgress?.jobs ?? const {};
        // The system already ended it: nothing to stop, and a job resumed
        // later starts a new one.
        _envelopeProgress = null;
        final interrupted = inside
            .map(_job)
            .nonNulls
            .where((job) => job.state.isActive)
            .toList();
        MpxDiagnostics.current.emit(
          MpxEventLevel.warning,
          EnvelopeOp.systemEnded,
          jobId: interrupted.firstOrNull?.id,
          fields: () => {'jobs': interrupted.length},
        );
        for (final job in interrupted) {
          _stopRun(job.id);
          _pause(job, PauseReason.systemInterrupted);
        }
      // A user's cancel of the whole envelope and a notification tap reach
      // owners once the envelope's native parts land; until then nothing
      // can send them.
      case TransferEnvelopeEvent$UserCancelledAll() ||
          TransferEnvelopeEvent$NotificationTap():
        break;
    }
  }

  // --- Runs ------------------------------------------------------------------

  void _startRun(TransferJob job) {
    _stopRun(job.id);
    final run = _Run(this, job.id);
    _runs[job.id] = run;
    _runner.start(job, run);
  }

  void _stopRun(TransferId id) {
    final run = _runs.remove(id);
    if (run == null) return;
    run.ended = true;
    _runner.stop(id);
  }

  void _endRun(_Run run) {
    run.ended = true;
    if (identical(_runs[run.id], run)) _runs.remove(run.id);
  }

  // --- Store, watchers, envelope, retention -----------------------------------

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
  }

  void _changed() {
    if (_disposed) return;
    for (final watch in [..._watchers]) {
      final next = _select(watch.filter);
      if (_sameJobs(next, watch.last)) continue;
      watch.last = next;
      watch.controller.add(next);
    }
    _syncEnvelope();
    _syncUnloadWarning();
    _schedulePrune();
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
  /// started with the first, updated as they move, stopped when none is
  /// left.
  void _syncEnvelope() {
    final envelope = _envelope;
    if (envelope == null) return;
    final inside = [
      for (final job in _journal.jobs)
        if (job.durability == TransferDurability.system && job.state.isActive)
          job,
    ];
    final started = _envelopeProgress;
    if (inside.isEmpty) {
      if (started == null) return;
      _envelopeProgress = null;
      envelope.stop();
      MpxDiagnostics.current.emit(
        MpxEventLevel.info,
        EnvelopeOp.withdrawn,
        fields: () => {'why': 'drained'},
      );
      return;
    }
    final totals = inside.map((job) => job.state.total);
    final progress = TransferEnvelopeProgress(
      jobs: {for (final job in inside) job.id},
      done: inside.fold(0, (sum, job) => sum + job.state.done),
      total: totals.contains(null)
          ? null
          : totals.nonNulls.fold<int>(0, (sum, total) => sum + total),
    );
    if (progress == started) return;
    _envelopeProgress = progress;
    if (started == null) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        EnvelopeOp.startRequested,
        jobId: inside.first.id,
        fields: () => {'jobs': inside.length},
      );
      envelope.start(progress);
    } else {
      envelope.update(progress);
    }
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
    if (copies == null) return;
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
    }
    for (final id in [...copies.held]) {
      if (_job(id)?.state case null || TransferState$Completed()) {
        _deleteSources(id);
      }
    }
  }

  void _deleteSources(TransferId id) {
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
  _Run(this._engine, this.id);

  final Transfers _engine;
  final TransferId id;
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

/// The runner of a facade made by [Transfers.open], before the package's
/// own entry points (downloads, uploads) bring theirs. Nothing can queue a
/// job on such a facade yet, so its journal holds none to resume and the
/// runner is never started.
final class _NoRunner implements TransferRunner {
  const _NoRunner();

  @override
  void start(TransferJob job, TransferRunSink sink) =>
      throw StateError('No transfer runner is wired for ${job.direction}.');

  @override
  void stop(TransferId id) {}

  @override
  void reprioritize(TransferId id, RequestPriority priority) {}
}
