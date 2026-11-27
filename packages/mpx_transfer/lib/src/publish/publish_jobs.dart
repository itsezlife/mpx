import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/journal_op.dart';
import 'package:mpx_transfer/src/diagnostics/publish_op.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/diagnostics/transport_op.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/upload_source_copies.dart';
import 'package:mpx_transfer/src/publish/publish_job.dart';
import 'package:mpx_transfer/src/publish/publish_journal.dart';
import 'package:mpx_transfer/src/publish/publish_progress.dart';
import 'package:mpx_transfer/src/publish/publish_record.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/publish/publish_state.dart';
import 'package:mpx_transfer/src/publish/publisher.dart';
import 'package:mpx_transfer/src/reuse/reuse_table.dart';
import 'package:mpx_transfer/src/upload/remote_ref.dart';
import 'package:mpx_transfer/src/upload/upload_engine.dart';
import 'package:mpx_transfer/src/upload/upload_lane.dart';
import 'package:mpx_transfer/src/upload/upload_source.dart';
import 'package:mpx_transfer/src/upload/upload_transport.dart';

/// What the publish jobs need of the facade: the transfer jobs their
/// uploads are, the verbs on them, and the bytes cache the server keys are
/// aliased in.
///
/// Internal to the package.
abstract interface class PublishUploadHost {
  /// Upload [id]'s journal record, or null when there is no such job.
  JournalRecord? recordOf(TransferId id);

  /// Queues upload [id] of [upload].
  void enqueueUpload(
    TransferId id,
    JournalUpload upload, {
    required TransferDurability durability,
    String? tag,
    MediaKey? key,
    SourceBytes? pageSource,
  });

  /// Queues failed upload [id] again, keeping what it sent, or from zero
  /// over a new [source] file or [pageSource]; answers whether it changed.
  bool retryUpload(
    TransferId id, {
    UploadSource$Finished? source,
    SourceBytes? pageSource,
  });

  /// Cancels upload [id] for the job that owns it.
  void cancelUpload(TransferId id);

  /// A job changed, was cancelled or lost an item: what the facade's view
  /// by content key reads may have moved.
  void publishChanged();

  /// Makes [server] resolve to the bytes [local] holds in the bytes cache;
  /// completes with whether [local] held any. Null when the facade has no
  /// bytes cache.
  Future<bool>? alias(MediaKey local, MediaKey server);
}

/// The publish jobs of one facade: each one's items looked up in the reuse
/// table, prepared, uploaded as transfer jobs of their own, and then its
/// publisher called once with the job's idempotency key.
///
/// - **Per item.** A remote item is uploaded at once; a reuse hit too.
///   Otherwise the item prepares through [preparation] (an item that needs
///   one on a facade without it is refused), its prepared file is
///   journaled, and the file uploads, with its thumbnail as an upload of
///   its own when the transport takes thumbnails separately. The item is
///   uploaded once every one of its uploads completed, and its references
///   go into the reuse table.
/// - **Publish.** Once every item is uploaded, the job's publisher is
///   called; a job whose publisher is not registered waits for it. A job
///   with no publisher (an upload on its own) completes there. A
///   `published` answer completes the job and then aliases its server keys
///   in the bytes cache; `reuploadItems` sends those items again (once per
///   job); `rejected` fails the job at the publish stage.
/// - **Failure and retry.** With the whole-job policy a failed item fails
///   the job; with the per-item policy the item fails and publish waits
///   until it is retried or removed. A retry takes each failed item back to
///   where it failed (a finished preparation and every journaled upload
///   kept) and, for a job failed at the publish stage, publishes again.
/// - **Order, hold, removal.** Jobs of one ordering group publish in the
///   order of their places in its line, which a job takes when it joins
///   (made, committed, retried after failing); a held job publishes once
///   committed; an item removed leaves the record, and a job left with
///   none waits for its owner.
/// - **Journal.** Every step is kept in [journal]. An item's upload ids
///   are written before its uploads are queued, so a restart finds every
///   upload its item names, or queues it again under the same id. A
///   preparation under way at a kill starts over; a finished one is not
///   redone. A publish attempt under way at a kill is made again with the
///   same key.
///
/// Internal to the package: hosts reach publish jobs through the facade.
final class PublishJobs {
  /// The publish jobs over [journal], uploading through [uploads].
  PublishJobs({
    required PublishJournal journal,
    required UploadEngine uploads,
    required PublishUploadHost host,
    ReuseTable? reuse,
    MediaPreparation? preparation,
    PublishProgressWeights progressWeights = PublishProgressWeights.standard,
    DateTime Function() now = DateTime.now,
  }) : _journal = journal,
       _uploads = uploads,
       _host = host,
       _reuse = reuse,
       _preparation = preparation,
       _weights = progressWeights,
       _now = now;

  final PublishJournal _journal;
  final UploadEngine _uploads;
  final PublishUploadHost _host;
  final ReuseTable? _reuse;
  final MediaPreparation? _preparation;
  final PublishProgressWeights _weights;
  final DateTime Function() _now;

  final Map<String, Publisher> _publishers = {};
  final Map<PublishJobId, _Live> _live = {};

  /// Each job's progress shown so far; kept apart from [_live], which
  /// holds only the jobs running in this run, as a query reads any job.
  final Map<PublishJobId, _Progress> _progress = {};
  final List<_JobsWatch> _jobsWatches = [];
  bool _disposed = false;

  /// While set, an upload's change is the engine's own queueing of it,
  /// not news: the item's other upload may not be queued yet.
  bool _$enqueuing = false;

  static final Random _random = Random.secure();

  /// The journal's records, for the facade's shutdown.
  PublishJournal get journal => _journal;

  // --- Entry points ----------------------------------------------------------

  /// Makes a job for [request]; see `Transfers.publish`.
  PublishJob publish(PublishRequest request) => _create(
    items: request.items,
    payload: request.payload,
    publisher: request.publisher,
    tag: request.tag,
    transport: request.transport,
    durability: request.durability,
    failurePolicy: request.failurePolicy,
    orderingGroup: request.orderingGroup,
    hold: request.hold,
    idempotencyKey: request.idempotencyKey,
  );

  /// Makes a one-item job with no publisher; see `Transfers.upload`.
  PublishJob upload(
    PublishItem item, {
    String? transport,
    String? tag,
    TransferDurability durability = TransferDurability.system,
  }) => _create(
    items: [item],
    payload: Uint8List(0),
    tag: tag,
    transport: transport,
    durability: durability,
    failurePolicy: PublishFailurePolicy.wholeJob,
  );

  /// Registers [publisher] under [id], replacing any before, and lets every
  /// job waiting for it publish.
  void registerPublisher(String id, Publisher publisher) {
    final waiting = [
      for (final record in _journal.records)
        if (record.publisher == id &&
            _stateOf(record) is PublishJobState$AwaitingPublisher)
          record.id,
    ];
    _publishers[id] = publisher;
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      PublishOp.publisherRegistered,
      fields: () => {'publisher': id, 'jobsWaiting': waiting.length},
    );
    waiting.forEach(_advance);
  }

  /// A handle on job [id], or null when there is no such job.
  PublishJob? job(PublishJobId id) =>
      _journal.record(id) == null ? null : PublishJob(this, id);

  /// Job [id] now, or null.
  PublishJobSnapshot? snapshotOf(PublishJobId id) {
    final record = _journal.record(id);
    return record == null ? null : _snapshot(record);
  }

  /// Whether item [itemId] of job [id] is published, its server keys
  /// aliased in the bytes cache: what turns its cells' sent into none. Null
  /// when the job or the item is gone (removed, the job cancelled or
  /// dropped after its retention).
  bool? itemAliased(PublishJobId id, String itemId) {
    final record = _journal.record(id);
    if (record == null || _itemRecord(id, itemId) == null) return null;
    return record.end is PublishJobState$Completed && record.aliases.isEmpty;
  }

  /// See [PublishJob.watch].
  Stream<PublishJobSnapshot> watch(PublishJobId id) => Stream.multi((sink) {
    final record = _journal.record(id);
    if (record == null) {
      sink.addError(StateError('The publish job is no longer known.'));
      unawaited(sink.close());
      return;
    }
    final last = _snapshot(record);
    sink.add(last);
    if (_disposed) {
      unawaited(sink.close());
      return;
    }
    final watch = _JobWatch(sink, last);
    final live = _liveOf(id);
    live.watches.add(watch);
    sink.onCancel = () => live.watches.remove(watch);
  });

  /// Snapshots of every job [filter] passes, oldest first: the current
  /// list on listen, then the list again whenever one of them changes. See
  /// `Transfers.watchJobs`.
  Stream<List<PublishJobSnapshot>> watchJobs(PublishJobFilter filter) =>
      Stream.multi((sink) {
        final watch = _JobsWatch(filter, sink, [
          for (final record in _journal.records)
            if (_snapshot(record) case final job when filter.matches(job)) job,
        ]);
        sink.add(watch.last);
        if (_disposed) {
          unawaited(sink.close());
          return;
        }
        _jobsWatches.add(watch);
        sink.onCancel = () => _jobsWatches.remove(watch);
      });

  /// See [PublishJob.watchItem].
  Stream<PublishItemSnapshot> watchItem(PublishJobId id, String itemId) =>
      Stream.multi((sink) {
        PublishItemSnapshot? last;
        late final StreamSubscription<PublishJobSnapshot> jobs;
        jobs = watch(id).listen(
          (job) {
            final item = job.item(itemId);
            if (item == null) {
              final seen = last;
              if (seen == null) {
                sink.addError(
                  ArgumentError.value(itemId, 'itemId', 'is not in the job'),
                );
              } else {
                sink.add(
                  PublishItemSnapshot(
                    itemId: itemId,
                    key: seen.key,
                    state: const PublishItemState.removed(),
                    progress: seen.progress,
                  ),
                );
              }
              unawaited(jobs.cancel());
              unawaited(sink.close());
              return;
            }
            if (item == last) return;
            sink.add(last = item);
          },
          onError: sink.addError,
          onDone: () => unawaited(sink.close()),
        );
        sink.onCancel = jobs.cancel;
      });

  /// The publish section of a debug snapshot.
  PublishDebugSnapshot debugSnapshot() => PublishDebugSnapshot(
    jobs: [
      for (final record in _journal.records)
        if (record.end is! PublishJobState$Completed)
          PublishJobDebugSnapshot(
            id: record.id,
            tag: record.tag,
            publisher: record.publisher,
            state: _stateOf(record),
            attempts: record.attempts,
            items: [
              for (final item in record.items)
                PublishItemDebugSnapshot(
                  item: _itemSnapshot(record, item),
                  reuseHit: switch (item.progress) {
                    ItemProgress$Uploaded(:final reused) => reused,
                    _ => false,
                  },
                ),
            ],
          ),
    ],
    publishers: _publishers.keys,
  );

  /// Picks up every job the journal holds, after the facade queued the
  /// uploads it read back.
  void restore() {
    // Files written for jobs a kill ended, or that ended since, go; a
    // failed job may still be retried.
    unawaited(
      _reportingRelease(
        _uploads.sweepSources({
          for (final record in _journal.records)
            if (record.end is! PublishJobState$Completed) record.id,
        }),
      ),
    );
    for (final record in [..._journal.records]) {
      if (record.end is PublishJobState$Completed &&
          record.aliases.isNotEmpty) {
        // Published before a kill, its aliases not all applied.
        unawaited(_applyAliases(record.id));
      }
      if (record.end != null) continue;
      _liveOf(record.id);
      for (final item in record.items) {
        unawaited(_runItem(record.id, item.item.itemId, restored: true));
      }
      _advance(record.id);
    }
  }

  /// Upload [job], which [owner]'s item sends, changed.
  void uploadChanged(TransferJob job, JournalUploadOwner owner) {
    if (_disposed || _$enqueuing) return;
    final id = PublishJobId.parse(owner.job);
    if (!_live.containsKey(id)) return;
    _checkUploads(id, owner.itemId);
  }

  /// Removes job [id] and answers the uploads it made, for the facade to
  /// cancel: its preparations stop, its record is forgotten, its watchers
  /// end and `watchJobs` lists it no more, as an owner sees a cancelled job
  /// leave; the jobs behind it in its ordering group go on. [by] is
  /// `owner` or `envelope`, for its event. Answers null for an unknown job.
  List<TransferId>? cancel(PublishJobId id, {required String by}) {
    final record = _journal.record(id);
    if (record == null) return null;
    final live = _live.remove(id);
    if (live != null) {
      for (final handle in live.preparations.values) {
        unawaited(handle.cancel());
      }
      for (final watch in live.watches) {
        unawaited(watch.sink.close());
      }
    }
    unawaited(_journal.remove(id));
    _releaseSources(id);
    _progress.remove(id);
    _host.publishChanged();
    for (final watch in [..._jobsWatches]) {
      if (!watch.last.any((job) => job.id == id)) continue;
      watch.last = [
        for (final job in watch.last)
          if (job.id != id) job,
      ];
      watch.sink.add(watch.last);
    }
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      PublishOp.cancelled,
      jobId: id,
      tag: record.tag,
      fields: () => {'by': by, 'items': record.items.length},
    );
    if (!_disposed) _releaseGroup(record);
    return [for (final item in record.items) ..._uploadsOf(item)];
  }

  /// See [PublishJob.cancel]: the job is removed and its uploads cancelled,
  /// whatever its state.
  bool cancelByOwner(PublishJobId id) {
    if (_disposed) return false;
    final uploads = cancel(id, by: 'owner');
    if (uploads == null) return false;
    for (final upload in uploads) {
      if (_host.recordOf(upload) != null) _host.cancelUpload(upload);
    }
    return true;
  }

  /// Stops every job: preparations are cancelled (a later start makes them
  /// again) and watchers end. The records stay.
  void shutDown() {
    if (_disposed) return;
    _disposed = true;
    for (final live in _live.values) {
      for (final handle in live.preparations.values) {
        unawaited(handle.cancel());
      }
      live.preparations.clear();
      for (final watch in [...live.watches]) {
        unawaited(watch.sink.close());
      }
      live.watches.clear();
    }
    for (final watch in [..._jobsWatches]) {
      unawaited(watch.sink.close());
    }
    _jobsWatches.clear();
  }

  // --- Creation --------------------------------------------------------------

  PublishJob _create({
    required List<PublishItem> items,
    required Uint8List payload,
    required String? tag,
    required String? transport,
    required TransferDurability durability,
    required PublishFailurePolicy failurePolicy,
    String? publisher,
    String? orderingGroup,
    bool hold = false,
    String? idempotencyKey,
  }) {
    if (_disposed) throw StateError('The facade was disposed.');
    final id = PublishJobId.issue();
    final carrier = transport ?? _uploads.transportIds.firstOrNull;
    _checkItems(id, items, const [], carrier, transport);
    final uploads = items.any((item) => item.source is! PublishSource$Remote);
    final now = _now();
    final record = PublishRecord(
      id: id,
      tag: tag,
      publisher: publisher,
      // A held job may take items to upload later.
      transport: uploads || hold ? carrier : null,
      payload: payload,
      durability: durability,
      failurePolicy: failurePolicy,
      orderingGroup: orderingGroup,
      // A held job joins its group's line when it is committed.
      groupOrder: orderingGroup == null || hold ? null : _nextGroupOrder(),
      hold: hold,
      idempotencyKey: idempotencyKey ?? _newKey(),
      keyFromRequest: idempotencyKey != null,
      createdAt: now,
      updatedAt: now,
      items: [
        for (final item in items)
          PublishItemRecord(item, const ItemProgress$Waiting()),
      ],
    );
    unawaited(_journal.put(record));
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      PublishOp.jobCreated,
      jobId: id,
      tag: tag,
      fields: () => {
        'items': items.length,
        'publisher': ?publisher,
        'durability': durability.name,
        'failurePolicy': failurePolicy.name,
        'hold': hold,
        'group': orderingGroup != null,
        'idempotency': idempotencyKey != null ? 'request' : 'engine',
      },
    );
    _liveOf(id);
    for (final item in items) {
      unawaited(_runItem(id, item.itemId));
    }
    _advance(id);
    return PublishJob(this, id);
  }

  /// Refuses [items] for job [id], which already has [existing]: an item id
  /// given twice, an item that needs preparation on a facade without it,
  /// or an item to upload with no transport ([carrier], from [transport]).
  void _checkItems(
    PublishJobId id,
    List<PublishItem> items,
    List<PublishItemRecord> existing,
    String? carrier,
    String? transport,
  ) {
    final ids = {for (final item in existing) item.item.itemId};
    for (final item in items) {
      if (!ids.add(item.itemId)) {
        throw ArgumentError.value(item.itemId, 'items', 'repeats an item id');
      }
    }
    if (_preparation == null) {
      for (final item in items) {
        if (item.source is! PublishSource$Prepare) continue;
        MpxDiagnostics.current.emit(
          MpxEventLevel.error,
          PublishPreparationOp.refusedNoSeam,
          jobId: id,
          itemId: item.itemId,
        );
        throw PreparationUnavailable(item.itemId);
      }
    }
    final uploads = items.any((item) => item.source is! PublishSource$Remote);
    if (uploads && (carrier == null || _uploads.transport(carrier) == null)) {
      throw ArgumentError.value(
        transport,
        'transport',
        'is not one of the facade transports',
      );
    }
  }

  /// The place at the end of every ordering group's line. One counter for
  /// all groups, read from the records, so it survives a restart and only
  /// the order within a group means anything.
  int _nextGroupOrder() {
    var last = 0;
    for (final record in _journal.records) {
      if (record.groupOrder case final order? when order > last) last = order;
    }
    return last + 1;
  }

  static String _newKey() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  // --- Items -----------------------------------------------------------------

  /// Moves item [itemId] on from where its record says it is.
  ///
  /// [restored] after a restart, [reopened] after a retry: an uploading
  /// item then queues again the uploads the journal lost, and after a
  /// retry its failed uploads too.
  Future<void> _runItem(
    PublishJobId id,
    String itemId, {
    bool restored = false,
    bool reopened = false,
  }) async {
    final item = _itemRecord(id, itemId);
    if (item == null) return;
    switch (item.progress) {
      case ItemProgress$Waiting():
        await _lookUpAndPrepare(id, item.item);
      case ItemProgress$Prepared(:final media, :final reuseKey):
        await _upload(id, item.item, media, reuseKey);
      case ItemProgress$Uploading():
        if (reopened) {
          await _retryFailedUploads(id, item);
          if (!_running(id)) return;
        }
        if (restored || reopened) _queueMissingUploads(id, item);
        _checkUploads(id, itemId);
      case ItemProgress$Uploaded() || ItemProgress$Failed():
        break;
    }
  }

  Future<void> _lookUpAndPrepare(PublishJobId id, PublishItem item) async {
    if (item.source is PublishSource$Remote) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        PublishOp.remoteItem,
        jobId: id,
        itemId: item.itemId,
        mediaKey: item.key,
      );
      _setItem(id, item, const ItemProgress$Uploaded());
      return;
    }
    if (item.source case PublishSource$Prepare(
      :final input,
    ) when input.byteSize == null) {
      // The source's size weighs the item until its preparation ends.
      final stat = await _uploads.stat(input.path);
      if (!_running(id)) return;
      if (stat != null) _progressOf(id).sources[item.itemId] = stat.size;
    }
    final record = _journal.record(id)!;
    final transport = _uploads.transport(record.transport!);
    final reuseKey = await _reuseKeyOf(item);
    if (!_running(id)) return;
    final reuse = _reuse;
    if (reuseKey != null && reuse != null && transport != null) {
      final hit = await reuse.lookup(
        reuseKey,
        transport,
        jobId: id,
        itemId: item.itemId,
        mediaKey: item.key,
      );
      if (!_running(id)) return;
      if (hit != null) {
        _setItem(
          id,
          item,
          ItemProgress$Uploaded(
            file: hit.file,
            thumbnail: hit.thumbnail,
            reused: true,
            reuseKey: reuseKey,
          ),
        );
        return;
      }
    }
    switch (item.source) {
      case PublishSource$Prepared(:final media):
        await _upload(id, item, media, reuseKey);
      case PublishSource$Prepare(:final input, :final intent):
        final media = await _prepare(id, item, input, intent);
        if (media == null || !_running(id)) return;
        _setItem(id, item, ItemProgress$Prepared(media, reuseKey: reuseKey));
        await _upload(id, item, media, reuseKey);
      case PublishSource$Remote():
        break;
    }
  }

  /// The reuse table's key for [item]: the host's fingerprint, else the
  /// file's path, size and time; null where the file cannot be read (the
  /// web has no file times), so the item is not looked up.
  Future<ReuseKey?> _reuseKeyOf(PublishItem item) async {
    final (path, intent) = switch (item.source) {
      PublishSource$Prepare(:final input, :final intent) => (
        input.path,
        intent,
      ),
      PublishSource$Prepared(:final media) => (media.path, null),
      PublishSource$Remote() => (null, null),
    };
    if (path == null) return null;
    if (item.fingerprint case final fingerprint?) {
      return ReuseKey.host(fingerprint, preparation: intent);
    }
    final stat = await _uploads.stat(path);
    if (stat == null) return null;
    return ReuseKey.file(
      path: path,
      size: stat.size,
      modified: stat.modified,
      preparation: intent,
    );
  }

  /// Prepares [input]; answers the prepared media, or null once the item
  /// failed (or the engine stopped).
  Future<PreparedMedia?> _prepare(
    PublishJobId id,
    PublishItem item,
    PreparationInput input,
    PreparationIntent intent,
  ) async {
    final preparation = _preparation;
    if (preparation == null) {
      // A job read back on a facade opened without preparation.
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        PublishPreparationOp.refusedNoSeam,
        jobId: id,
        itemId: item.itemId,
      );
      _failItem(id, item, PublishStage.prepare, 'noPreparation', false);
      return null;
    }
    final live = _liveOf(id);
    final handle = preparation.prepare(input, intent);
    live.preparations[item.itemId] = handle;
    void onProgress() => _changed(id);
    handle.progress.addListener(onProgress);
    _emitStage(
      id,
      item,
      const PublishItemState.waiting(),
      _itemStateOf(id, item),
    );
    try {
      return await handle.result;
    } on PreparationException catch (error, stackTrace) {
      if (!_running(id)) return null;
      final (reason, retryable) = switch (error) {
        PreparationCancelled() => ('cancelled', true),
        PreparationFailed(:final code) => (code, true),
      };
      _failItem(
        id,
        item,
        PublishStage.prepare,
        reason,
        retryable,
        stackTrace: stackTrace,
      );
      return null;
    } on Object catch (_, stackTrace) {
      if (!_running(id)) return null;
      _failItem(
        id,
        item,
        PublishStage.prepare,
        'unexpected',
        false,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      handle.progress.removeListener(onProgress);
      if (identical(live.preparations[item.itemId], handle)) {
        live.preparations.remove(item.itemId);
      }
    }
  }

  /// Makes [media]'s uploads: the file, and the thumbnail when the
  /// transport takes it separately. Their ids are journaled before they
  /// are queued.
  Future<void> _upload(
    PublishJobId id,
    PublishItem item,
    PreparedMedia media,
    ReuseKey? reuseKey,
  ) async {
    final record = _journal.record(id)!;
    final transport = _uploads.transport(record.transport!);
    if (transport == null) {
      _failItem(id, item, PublishStage.upload, 'unknownTransport', false);
      return;
    }
    final fileId = TransferId.issue();
    final PreparedMedia sent;
    final SourceBytes? pageSource;
    try {
      (sent, pageSource) = await _fileSourceOf(id, fileId, item, media);
    } on Object catch (_, stackTrace) {
      if (!_running(id)) return;
      _failItem(
        id,
        item,
        PublishStage.upload,
        'sourceUnwritable',
        true,
        stackTrace: stackTrace,
      );
      return;
    }
    if (!_running(id)) return;
    TransferId? thumbnailId;
    final JournalUpload file;
    JournalUpload? thumbnail;
    try {
      file = _describeFile(id, item, sent);
      if (transport.capabilities.thumbnail == UploadThumbnail.separate &&
          sent.thumbnailPath != null) {
        final stat = await _uploads.stat(sent.thumbnailPath!);
        if (!_running(id)) return;
        if (stat == null) {
          _failItem(
            id,
            item,
            PublishStage.upload,
            'thumbnailUnreadable',
            false,
          );
          return;
        }
        thumbnailId = TransferId.issue();
        thumbnail = _describeThumbnail(id, item, sent, stat.size);
      }
    } on Object catch (_, stackTrace) {
      _failItem(
        id,
        item,
        PublishStage.upload,
        'transport',
        false,
        stackTrace: stackTrace,
      );
      return;
    }
    final before = _itemStateOf(id, item);
    // The ids are kept before the uploads exist: a restart then finds each
    // upload its item names, or queues it again under the same id.
    await _put(
      _journal
          .record(id)!
          .withItem(
            item.itemId,
            ItemProgress$Uploading(
              sent,
              file: fileId,
              thumbnail: thumbnailId,
              reuseKey: reuseKey,
            ),
            _now(),
          ),
    );
    if (!_running(id)) return;
    _enqueue(record, item, fileId, file, pageSource: pageSource);
    if (thumbnail != null) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.debug,
        TransportOp.thumbnailUpload,
        jobId: thumbnailId,
        itemId: item.itemId,
        fields: () => {'bytes': thumbnail!.source.size},
      );
      _enqueue(record, item, thumbnailId!, thumbnail);
    }
    _emitStage(id, item, before, _itemStateOf(id, item));
    _checkUploads(id, item.itemId);
  }

  /// What upload [fileId] of [media]'s file reads, and the media as it is
  /// journaled.
  ///
  /// The bytes the page holds come first: the prepared bytes, else the
  /// item's page source where the upload sends the item's own file (the
  /// host's prepared media, or an original the preparation kept). Where
  /// uploads read page sources (the web) the upload takes them as they
  /// are. Elsewhere (the VM) a file at the media's path wins, and without
  /// one the bytes are written to a file of the engine's own for job [id],
  /// which the media then names. Without such bytes the upload reads the
  /// media's path.
  Future<(PreparedMedia, SourceBytes?)> _fileSourceOf(
    PublishJobId id,
    TransferId fileId,
    PublishItem item,
    PreparedMedia media,
  ) async {
    final page = switch (media.bytes) {
      final bytes? => SourceBytes.memory(bytes),
      null when media.isOriginal || item.source is PublishSource$Prepared =>
        item.pageSource,
      null => null,
    };
    if (page == null) return (media, null);
    if (_uploads.readsPageSources) {
      return (_mediaAt(media, media.path, page.size, bytes: media.bytes), page);
    }
    if (await _uploads.stat(media.path) != null) return (media, null);
    final began = _now();
    final path = await _uploads.writeSource(id, page);
    MpxDiagnostics.current.emit(
      MpxEventLevel.debug,
      JournalOp.sourceCopied,
      jobId: fileId,
      fields: () => {
        'bytes': page.size,
        'ms': _now().difference(began).inMilliseconds,
      },
    );
    return (_mediaAt(media, path, page.size), null);
  }

  /// [media] as the file at [path], [size] bytes long, holding [bytes] in
  /// memory.
  static PreparedMedia _mediaAt(
    PreparedMedia media,
    String path,
    int size, {
    Uint8List? bytes,
  }) => PreparedMedia(
    kind: media.kind,
    path: path,
    isOriginal: media.isOriginal,
    byteSize: size,
    mimeType: media.mimeType,
    dimensions: media.dimensions,
    duration: media.duration,
    thumbnailPath: media.thumbnailPath,
    thumbnail: media.thumbnail,
    thumbnailDimensions: media.thumbnailDimensions,
    hasAudio: media.hasAudio,
    animated: media.animated,
    bytes: bytes,
  );

  /// The upload of [media]'s file: a video waits in the big lane, any
  /// other file by its size.
  JournalUpload _describeFile(
    PublishJobId id,
    PublishItem item,
    PreparedMedia media,
  ) => _uploads.describe(
    UploadSource.finished(media.path, size: media.byteSize),
    transport: _journal.record(id)!.transport!,
    lane: media.kind == PreparedKind.video ? UploadLane.big : null,
    fileName: item.fileName,
    contentType: media.mimeType,
    fingerprint: item.fingerprint,
    owner: JournalUploadOwner(
      job: id,
      itemId: item.itemId,
      role: UploadRole.file,
    ),
  );

  /// The upload of [media]'s thumbnail, [size] bytes: always small.
  JournalUpload _describeThumbnail(
    PublishJobId id,
    PublishItem item,
    PreparedMedia media,
    int size,
  ) => _uploads.describe(
    UploadSource.finished(media.thumbnailPath!, size: size),
    transport: _journal.record(id)!.transport!,
    lane: UploadLane.small,
    owner: JournalUploadOwner(
      job: id,
      itemId: item.itemId,
      role: UploadRole.thumbnail,
    ),
  );

  void _enqueue(
    PublishRecord record,
    PublishItem item,
    TransferId id,
    JournalUpload upload, {
    SourceBytes? pageSource,
  }) {
    _$enqueuing = true;
    try {
      _host.enqueueUpload(
        id,
        upload,
        durability: record.durability,
        tag: record.tag,
        key: item.key,
        pageSource: pageSource,
      );
    } finally {
      _$enqueuing = false;
    }
  }

  /// After a restart, queues again every upload [item] names that the
  /// transfer journal does not hold: its record was written, its upload's
  /// was not.
  void _queueMissingUploads(PublishJobId id, PublishItemRecord item) {
    final progress = item.progress as ItemProgress$Uploading;
    final record = _journal.record(id)!;
    final media = progress.media;
    try {
      if (_host.recordOf(progress.file) == null) {
        _enqueue(
          record,
          item.item,
          progress.file,
          _describeFile(id, item.item, media),
        );
      }
    } on Object catch (_, stackTrace) {
      _failItem(
        id,
        item.item,
        PublishStage.upload,
        'transport',
        false,
        stackTrace: stackTrace,
      );
      return;
    }
    final thumbnail = progress.thumbnail;
    if (thumbnail == null ||
        _host.recordOf(thumbnail) != null ||
        media.thumbnailPath == null) {
      return;
    }
    final live = _liveOf(id)..requeuing.add(item.item.itemId);
    // The thumbnail's size is read again: the file is what uploads now.
    unawaited(
      _uploads.stat(media.thumbnailPath!).then((stat) {
        live.requeuing.remove(item.item.itemId);
        if (!_running(id)) return;
        if (stat == null) {
          _failItem(
            id,
            item.item,
            PublishStage.upload,
            'thumbnailUnreadable',
            false,
          );
          return;
        }
        try {
          _enqueue(
            record,
            item.item,
            thumbnail,
            _describeThumbnail(id, item.item, media, stat.size),
          );
        } on Object catch (_, stackTrace) {
          _failItem(
            id,
            item.item,
            PublishStage.upload,
            'transport',
            false,
            stackTrace: stackTrace,
          );
          return;
        }
        _checkUploads(id, item.item.itemId);
      }),
    );
  }

  /// Queues again each failed upload of uploading [item], keeping its
  /// journaled parts; the file's from zero over the new source a retry of
  /// the item gave ([retryItem]), written to a file first on the VM.
  Future<void> _retryFailedUploads(
    PublishJobId id,
    PublishItemRecord item,
  ) async {
    final progress = item.progress as ItemProgress$Uploading;
    final given = _liveOf(id).newSources.remove(item.item.itemId);
    UploadSource$Finished? file;
    SourceBytes? pageSource;
    if (given != null && !_uploads.readsPageSources) {
      try {
        file = UploadSource$Finished(
          await _uploads.writeSource(id, given),
          size: given.size,
        );
      } on Object catch (_, stackTrace) {
        if (!_running(id)) return;
        _failItem(
          id,
          item.item,
          PublishStage.upload,
          'sourceUnwritable',
          true,
          stackTrace: stackTrace,
        );
        return;
      }
      if (!_running(id)) return;
    } else {
      pageSource = given;
    }
    // Each retry is news the item would read with its other upload still
    // failed, failing it again.
    _$enqueuing = true;
    try {
      for (final upload in [progress.file, ?progress.thumbnail]) {
        if (_host.recordOf(upload)?.job.state is TransferState$Failed) {
          final isFile = upload == progress.file;
          _host.retryUpload(
            upload,
            source: isFile ? file : null,
            pageSource: isFile ? pageSource : null,
          );
        }
      }
    } finally {
      _$enqueuing = false;
    }
  }

  /// Reads item [itemId]'s uploads: all completed makes it uploaded, one
  /// failed or gone fails it, else its progress moved.
  void _checkUploads(PublishJobId id, String itemId) {
    final item = _itemRecord(id, itemId);
    if (item == null || !_running(id)) return;
    final progress = item.progress;
    if (progress is! ItemProgress$Uploading) return;
    final file = _host.recordOf(progress.file)?.job;
    final thumbnailId = progress.thumbnail;
    final thumbnail = thumbnailId == null
        ? null
        : _host.recordOf(thumbnailId)?.job;
    final jobs = [file, if (thumbnailId != null) thumbnail];
    // Queued again after a restart, but not yet: nothing to read.
    if (_liveOf(id).requeuing.contains(itemId)) {
      _changed(id);
      return;
    }
    if (jobs.contains(null)) {
      _failItem(id, item.item, PublishStage.upload, 'cancelled', true);
      return;
    }
    for (final job in jobs.nonNulls) {
      if (job.state case TransferState$Failed(:final kind, :final retryable)) {
        _failItem(id, item.item, PublishStage.upload, kind.name, retryable);
        return;
      }
    }
    final refs = [
      for (final job in jobs.nonNulls)
        if (job.state case TransferState$Completed(result: final RemoteRef ref))
          ref,
    ];
    if (refs.length < jobs.length) {
      _changed(id);
      return;
    }
    final fileRef = refs.first;
    final thumbnailRef = thumbnailId == null ? null : refs[1];
    if (progress.reuseKey case final key?) {
      final transport = _uploads.transport(_journal.record(id)!.transport!);
      if (transport != null) {
        _reuse?.store(
          key,
          transport,
          file: fileRef,
          thumbnail: thumbnailRef,
          jobId: id,
          itemId: itemId,
          mediaKey: item.item.key,
        );
      }
    }
    _setItem(
      id,
      item.item,
      ItemProgress$Uploaded(
        file: fileRef,
        thumbnail: thumbnailRef,
        media: progress.media,
        reuseKey: progress.reuseKey,
        uploads: [progress.file, ?thumbnailId],
      ),
    );
  }

  void _failItem(
    PublishJobId id,
    PublishItem item,
    PublishStage stage,
    String reason,
    bool retryable, {
    StackTrace? stackTrace,
  }) => _setItem(
    id,
    item,
    ItemProgress$Failed(
      stage: stage,
      reason: reason,
      retryable: retryable,
      // Where a retry resumes: a finished preparation and the journaled
      // uploads are kept rather than made again.
      before: switch (_itemRecord(id, item.itemId)?.progress) {
        final ItemProgress$Prepared prepared => prepared,
        final ItemProgress$Uploading uploading => uploading,
        _ => null,
      },
    ),
    stackTrace: stackTrace,
  );

  /// Writes item [item]'s new [progress], reports the stage it moved to and
  /// moves the job on.
  void _setItem(
    PublishJobId id,
    PublishItem item,
    ItemProgress progress, {
    StackTrace? stackTrace,
  }) {
    final record = _journal.record(id);
    if (record == null || !_running(id)) return;
    final before = _itemStateOf(id, item);
    unawaited(_put(record.withItem(item.itemId, progress, _now())));
    _emitStage(id, item, before, _itemStateOf(id, item), stackTrace);
    _advance(id);
  }

  void _emitStage(
    PublishJobId id,
    PublishItem item,
    PublishItemState from,
    PublishItemState to, [
    StackTrace? stackTrace,
  ]) {
    if (from.name == to.name) return;
    final failed = to is PublishItemState$Failed ? to : null;
    MpxDiagnostics.current.emit(
      failed == null ? MpxEventLevel.debug : MpxEventLevel.error,
      PublishOp.itemStage,
      jobId: id,
      itemId: item.itemId,
      mediaKey: item.key,
      fields: () => {
        'from': from.name,
        'to': to.name,
        if (failed != null) ...{
          'stage': failed.stage.name,
          'reason': MpxEvent.clip(failed.reason),
        },
      },
      stackTrace: stackTrace,
    );
  }

  // --- The job ---------------------------------------------------------------

  /// Moves job [id] on: it fails with a failed item (whole-job policy),
  /// completes with no publisher, or publishes once every item is
  /// uploaded.
  void _advance(PublishJobId id) {
    final record = _journal.record(id);
    if (record == null || record.end != null || !_running(id)) return;
    final live = _liveOf(id);
    if (record.failurePolicy == PublishFailurePolicy.wholeJob) {
      for (final item in record.items) {
        if (item.progress case ItemProgress$Failed(
          :final stage,
          :final reason,
          :final retryable,
        )) {
          _end(
            record,
            PublishJobState.failed(
              stage: stage,
              reason: reason,
              retryable: retryable,
            ),
          );
          return;
        }
      }
    }
    if (record.awaitingOwner ||
        !record.items.every((item) => item.progress is ItemProgress$Uploaded) ||
        (record.hold && !record.committed)) {
      _changed(id);
      return;
    }
    final name = record.publisher;
    if (name == null) {
      _end(record, const PublishJobState.completed(null));
      return;
    }
    if (live.attempting) return;
    final ahead = _aheadInGroup(record);
    if (ahead > 0) {
      if (!live.reportedGroupWait) {
        live.reportedGroupWait = true;
        MpxDiagnostics.current.emit(
          MpxEventLevel.debug,
          PublishOp.groupWait,
          jobId: id,
          tag: record.tag,
          fields: () => {'ahead': ahead},
        );
      }
      _changed(id);
      return;
    }
    live.reportedGroupWait = false;
    final publisher = _publishers[name];
    if (publisher == null) {
      if (!live.reportedAwaiting) {
        live.reportedAwaiting = true;
        MpxDiagnostics.current.emit(
          MpxEventLevel.warning,
          PublishOp.awaitingPublisher,
          jobId: id,
          tag: record.tag,
          fields: () => {'publisher': name},
        );
      }
      _changed(id);
      return;
    }
    unawaited(_attempt(record, publisher));
  }

  /// How many jobs of [record]'s ordering group are ahead of it in the
  /// line and still on their way to publish. A job that failed, completed,
  /// waits for its owner or was cancelled holds no one; a held job joins
  /// the line only when committed.
  int _aheadInGroup(PublishRecord record) {
    final group = record.orderingGroup;
    final place = record.groupOrder;
    if (group == null || place == null) return 0;
    var ahead = 0;
    for (final other in _journal.records) {
      if (other.orderingGroup != group ||
          other.end != null ||
          other.awaitingOwner) {
        continue;
      }
      if (other.groupOrder case final order? when order < place) ahead++;
    }
    return ahead;
  }

  /// Lets the jobs behind [record] in its ordering group go on, once it no
  /// longer holds them.
  void _releaseGroup(PublishRecord record) {
    final group = record.orderingGroup;
    if (group == null || record.groupOrder == null) return;
    for (final other in [..._journal.records]) {
      if (other.id == record.id ||
          other.orderingGroup != group ||
          other.end != null) {
        continue;
      }
      _advance(other.id);
    }
  }

  Future<void> _attempt(PublishRecord before, Publisher publisher) async {
    final id = before.id;
    final live = _liveOf(id);
    live.attempting = true;
    final record = before.copyWith(
      attempts: before.attempts + 1,
      updatedAt: _now(),
    );
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      PublishOp.attempt,
      jobId: id,
      tag: record.tag,
      fields: () => {'attempt': record.attempts, 'stage': 'publish'},
    );
    _changed(id);
    await _put(record);
    if (!_running(id)) return;
    final items = <String, PublishItemRefs>{
      for (final item in record.items)
        if (item.progress case ItemProgress$Uploaded(
          :final file,
          :final thumbnail,
        ))
          item.item.itemId: PublishItemRefs(
            key: item.item.key,
            file: file,
            thumbnail: thumbnail,
          ),
    };
    final PublishOutcome outcome;
    try {
      outcome = await publisher.publish(
        record.payload,
        items,
        record.idempotencyKey,
      );
    } on Object catch (_, stackTrace) {
      // The publisher's error may carry the payload: only that it threw.
      if (!_running(id)) return;
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        PublishOp.outcome,
        jobId: id,
        tag: record.tag,
        fields: () => {'outcome': 'error', 'retryable': true, 'serverKeys': 0},
        stackTrace: stackTrace,
      );
      live.attempting = false;
      _end(
        _journal.record(id)!,
        const PublishJobState.failed(
          stage: PublishStage.publish,
          reason: 'publisherError',
          retryable: true,
        ),
      );
      return;
    }
    // A kill or a shutdown during the call: the next start calls again
    // with the same key, and the remote end applies it once.
    if (!_running(id)) return;
    live.attempting = false;
    void emitOutcome(
      MpxEventLevel level, {
      bool retryable = false,
      int serverKeys = 0,
      int? items,
    }) => MpxDiagnostics.current.emit(
      level,
      PublishOp.outcome,
      jobId: id,
      tag: record.tag,
      fields: () => {
        'outcome': outcome.name,
        'retryable': retryable,
        'serverKeys': serverKeys,
        'items': ?items,
      },
    );
    final current = _journal.record(id)!;
    switch (outcome) {
      case PublishOutcome$Published(:final result, :final serverKeys):
        emitOutcome(MpxEventLevel.info, serverKeys: serverKeys.length);
        // The completion and its server keys are written before any alias
        // applies: a kill in between applies the aliases at the next start
        // and never publishes again.
        final done = current.copyWith(
          end: PublishJobState.completed(result),
          aliases: serverKeys,
          updatedAt: _now(),
        );
        final written = _put(done);
        _changed(id);
        _releaseGroup(done);
        _releaseSources(id);
        await written;
        await _applyAliases(id);
      case PublishOutcome$Rejected(:final reason, :final retryable):
        emitOutcome(MpxEventLevel.warning, retryable: retryable);
        _end(
          current,
          PublishJobState.failed(
            stage: PublishStage.publish,
            reason: reason,
            retryable: retryable,
          ),
        );
      case PublishOutcome$ReuploadItems(:final itemIds):
        await _reupload(current, itemIds, emitOutcome);
    }
  }

  /// Sends items [itemIds] of [record] again after a `reuploadItems`
  /// answer, or fails the job when it already honoured one.
  Future<void> _reupload(
    PublishRecord record,
    Set<String> itemIds,
    void Function(MpxEventLevel level, {int? items}) emitOutcome,
  ) async {
    final id = record.id;
    if (record.reuploads > 0) {
      emitOutcome(MpxEventLevel.error, items: 0);
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        PublishOp.reuploadRefused,
        jobId: id,
        tag: record.tag,
      );
      _end(
        record,
        const PublishJobState.failed(
          stage: PublishStage.publish,
          reason: 'reuploadRefused',
          retryable: false,
        ),
      );
      return;
    }
    final transport = switch (record.transport) {
      final carrier? => _uploads.transport(carrier),
      null => null,
    };
    final again = <PublishItem>[];
    final items = <PublishItemRecord>[];
    for (final item in record.items) {
      final progress = item.progress;
      if (progress is! ItemProgress$Uploaded ||
          progress.file == null ||
          !itemIds.contains(item.item.itemId)) {
        items.add(item);
        continue;
      }
      again.add(item.item);
      if ((progress.reuseKey, transport) case (final key?, final carrier?)) {
        _reuse?.invalidate(
          key,
          carrier,
          jobId: id,
          itemId: item.item.itemId,
          mediaKey: item.item.key,
        );
      }
      // The file that was sent goes again; a reuse hit sent none and starts
      // over, and with its entry gone the table does not answer it again.
      items.add(
        PublishItemRecord(item.item, switch (progress.media) {
          final media? => ItemProgress$Prepared(
            media,
            reuseKey: progress.reuseKey,
          ),
          null => const ItemProgress$Waiting(),
        }),
      );
    }
    emitOutcome(MpxEventLevel.info, items: again.length);
    // The count is kept before anything is sent again, so a kill never
    // lets a second answer be honoured.
    await _put(
      record.copyWith(
        items: items,
        reuploads: record.reuploads + 1,
        updatedAt: _now(),
      ),
    );
    if (!_running(id)) return;
    for (final item in again) {
      _emitStage(
        id,
        item,
        const PublishItemState.uploaded(),
        _itemStateOf(id, item),
      );
    }
    _changed(id);
    if (again.isEmpty) {
      _advance(id);
      return;
    }
    for (final item in again) {
      unawaited(_runItem(id, item.itemId));
    }
  }

  /// Aliases each server key job [id] kept to its item's local key, then
  /// drops the keys from the record. Each alias is reported; one that fails
  /// is a warning and the others still apply.
  Future<void> _applyAliases(PublishJobId id) async {
    final record = _journal.record(id);
    if (record == null || record.aliases.isEmpty || _disposed) return;
    final keys = {
      for (final item in record.items) item.item.itemId: item.item.key,
    };
    for (final MapEntry(key: itemId, value: server) in record.aliases.entries) {
      final local = keys[itemId];
      var level = MpxEventLevel.debug;
      String result;
      StackTrace? trace;
      if (local == null) {
        result = 'unknownItem';
      } else {
        try {
          result = switch (_host.alias(local, server)) {
            null => 'noCache',
            final aliasing => await aliasing ? 'aliased' : 'nothingHeld',
          };
        } on Object catch (_, stackTrace) {
          level = MpxEventLevel.warning;
          result = 'failed';
          trace = stackTrace;
        }
      }
      // A kill during the alias: the next start applies them all again,
      // and aliasing twice changes nothing.
      if (_disposed) return;
      MpxDiagnostics.current.emit(
        level,
        PublishOp.aliasApplied,
        jobId: id,
        itemId: itemId,
        mediaKey: local,
        fields: () => {'result': result},
        stackTrace: trace,
      );
    }
    final now = _journal.record(id);
    if (now == null) return;
    final written = _put(now.copyWith(aliases: const {}, updatedAt: _now()));
    _changed(id);
    await written;
  }

  // --- Host verbs ------------------------------------------------------------

  /// See [PublishJob.retry].
  bool retry(PublishJobId id) {
    final record = _journal.record(id);
    if (_disposed || record == null) return false;
    final PublishJobState$Failed? failed;
    switch (record.end) {
      case null:
        failed = null;
      case final PublishJobState$Failed end:
        failed = end;
      case _:
        return false;
    }
    final reset = [
      for (final item in record.items)
        if (item.progress is ItemProgress$Failed) item.item.itemId,
    ];
    if (failed == null && reset.isEmpty) return false;
    _reopen(record, reset, stage: failed?.stage ?? _failedStage(record));
    return true;
  }

  /// See [PublishJob.retryItem].
  bool retryItem(PublishJobId id, String itemId, {SourceBytes? source}) {
    final record = _journal.record(id);
    if (_disposed || record == null) return false;
    if (record.end case final end? when end is! PublishJobState$Failed) {
      return false;
    }
    final item = _itemRecord(id, itemId);
    if (item?.progress case ItemProgress$Failed(:final stage)) {
      if (source != null) _liveOf(id).newSources[itemId] = source;
      _reopen(
        record,
        [itemId],
        stage: stage,
        itemId: itemId,
        pageSource: source,
      );
      return true;
    }
    return false;
  }

  /// See [PublishJob.removeItem]; [by] is `host` for the host's verb and
  /// `cell` for a cancel of one of the item's uploads.
  bool removeItem(PublishJobId id, String itemId, {String by = 'host'}) {
    final record = _journal.record(id);
    if (_disposed || record == null || record.end != null) return false;
    final item = _itemRecord(id, itemId);
    if (item == null) return false;
    final live = _liveOf(id);
    if (live.preparations.remove(itemId) case final handle?) {
      unawaited(handle.cancel());
    }
    final left = [
      for (final other in record.items)
        if (other.item.itemId != itemId) other,
    ];
    // The item leaves the record first, so its cancelled uploads are not
    // read as its failure.
    final removed = record.copyWith(
      items: left,
      awaitingOwner: left.isEmpty ? true : null,
      updatedAt: _now(),
    );
    unawaited(_put(removed));
    for (final upload in _uploadsOf(item)) {
      if (_host.recordOf(upload) != null) _host.cancelUpload(upload);
    }
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      PublishOp.itemRemoved,
      jobId: id,
      itemId: itemId,
      mediaKey: item.item.key,
      tag: record.tag,
      fields: () => {'by': by},
    );
    if (left.isEmpty) {
      // The engine never cancels an empty job: whether nothing is left to
      // send is the owner's call.
      MpxDiagnostics.current.emit(
        MpxEventLevel.info,
        PublishOp.awaitingOwner,
        jobId: id,
        tag: record.tag,
      );
      _changed(id);
      _releaseGroup(removed);
      return true;
    }
    _advance(id);
    return true;
  }

  /// One of item [owner]'s uploads was cancelled on its own (a cell's
  /// cancel by the item's key): the item leaves its job, and the rest
  /// publish.
  void uploadCancelled(JournalUploadOwner owner) {
    if (_disposed) return;
    final id = PublishJobId.parse(owner.job);
    if (removeItem(id, owner.itemId, by: 'cell')) return;
    // An ended job keeps its item; one still running reads the loss.
    if (_live.containsKey(id)) _checkUploads(id, owner.itemId);
  }

  /// See [PublishJob.addItem].
  bool addItem(PublishJobId id, PublishItem item) {
    final record = _journal.record(id);
    if (_disposed || record == null || !_beforeCommit(record)) return false;
    _checkItems(id, [item], record.items, record.transport, record.transport);
    unawaited(
      _put(
        record.copyWith(
          items: [
            ...record.items,
            PublishItemRecord(item, const ItemProgress$Waiting()),
          ],
          awaitingOwner: false,
          updatedAt: _now(),
        ),
      ),
    );
    unawaited(_runItem(id, item.itemId));
    _advance(id);
    return true;
  }

  /// See [PublishJob.reorder].
  bool reorder(PublishJobId id, List<String> itemIds) {
    final record = _journal.record(id);
    if (_disposed || record == null || !_beforeCommit(record)) return false;
    final byId = {for (final item in record.items) item.item.itemId: item};
    if (itemIds.length != byId.length ||
        !itemIds.every(byId.containsKey) ||
        itemIds.toSet().length != itemIds.length) {
      throw ArgumentError.value(
        itemIds,
        'itemIds',
        "is not an order of the job's items",
      );
    }
    unawaited(
      _put(
        record.copyWith(
          items: [for (final itemId in itemIds) byId[itemId]!],
          updatedAt: _now(),
        ),
      ),
    );
    _changed(id);
    return true;
  }

  /// See [PublishJob.setPayload].
  bool setPayload(PublishJobId id, Uint8List payload) {
    final record = _journal.record(id);
    if (_disposed || record == null || !_beforeCommit(record)) return false;
    unawaited(
      _put(
        record.copyWith(
          payload: Uint8List.fromList(payload),
          updatedAt: _now(),
        ),
      ),
    );
    return true;
  }

  /// See [PublishJob.commit].
  bool commit(PublishJobId id, Uint8List? payload) {
    final record = _journal.record(id);
    if (_disposed || record == null || record.end != null) return false;
    if (!_beforeCommit(record) && !record.awaitingOwner) return false;
    final committed = record.copyWith(
      payload: payload == null ? null : Uint8List.fromList(payload),
      committed: record.hold ? true : null,
      awaitingOwner: false,
      // The owner's decision is a new send: it joins the end of the line.
      groupOrder: record.orderingGroup == null ? null : _nextGroupOrder(),
      updatedAt: _now(),
    );
    unawaited(_put(committed));
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      PublishOp.committed,
      jobId: id,
      tag: record.tag,
      fields: () => {'items': committed.items.length},
    );
    _advance(id);
    return true;
  }

  /// Whether [record] is a held job not yet committed, which takes every
  /// change of its items and payload.
  static bool _beforeCommit(PublishRecord record) =>
      record.end == null && record.hold && !record.committed;

  /// Upload ids [item] holds: its file and thumbnail while it uploads,
  /// when it failed uploading, or once they completed.
  static List<TransferId> _uploadsOf(PublishItemRecord item) =>
      switch (item.progress) {
        ItemProgress$Uploading(:final file, :final thumbnail) ||
        ItemProgress$Failed(
          before: ItemProgress$Uploading(:final file, :final thumbnail),
        ) => [file, ?thumbnail],
        ItemProgress$Uploaded(:final uploads) => uploads,
        _ => const <TransferId>[],
      };

  /// The stage of the first failed item of [record].
  static PublishStage _failedStage(PublishRecord record) {
    for (final item in record.items) {
      if (item.progress case ItemProgress$Failed(:final stage)) return stage;
    }
    return PublishStage.publish;
  }

  /// Takes items [reset] of [record] back to where they failed, reopens the
  /// job when it ended, and moves every unfinished item on.
  void _reopen(
    PublishRecord record,
    List<String> reset, {
    required PublishStage stage,
    String? itemId,
    SourceBytes? pageSource,
  }) {
    final id = record.id;
    final reopened = record.copyWith(
      items: [
        for (final item in record.items)
          switch (item.progress) {
            ItemProgress$Failed(:final before)
                when reset.contains(item.item.itemId) =>
              PublishItemRecord(
                // A new source replaces the item's page source too, for
                // an upload it has not made yet.
                pageSource == null
                    ? item.item
                    : item.item.withPageSource(pageSource),
                before ?? const ItemProgress$Waiting(),
              ),
            _ => item,
          },
      ],
      // A failed job no longer held its group: retried, it joins the end
      // of the line.
      groupOrder:
          record.end is PublishJobState$Failed && record.groupOrder != null
          ? _nextGroupOrder()
          : null,
      clearEnd: true,
      updatedAt: _now(),
    );
    unawaited(_put(reopened));
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      PublishOp.retry,
      jobId: id,
      itemId: itemId,
      tag: record.tag,
      fields: () => {'stage': stage.name, 'items': reset.length},
    );
    final live = _liveOf(id)
      ..reportedAwaiting = false
      ..reportedGroupWait = false;
    for (final (index, item) in reopened.items.indexed) {
      if (!reset.contains(item.item.itemId)) continue;
      _emitStage(
        id,
        item.item,
        _itemState(id, record.items[index]),
        _itemState(id, item),
      );
    }
    for (final item in reopened.items) {
      final itemId = item.item.itemId;
      // A preparation still under way from before the failure goes on.
      if (live.preparations.containsKey(itemId)) continue;
      // An ended job read none of its items' news: every unfinished item
      // is read again.
      if (record.end == null && !reset.contains(itemId)) continue;
      unawaited(_runItem(id, itemId, reopened: true));
    }
    _advance(id);
  }

  void _end(PublishRecord record, PublishJobState end) {
    unawaited(_put(record.copyWith(end: end, updatedAt: _now())));
    // A failed job may be retried; a completed one sends nothing again.
    if (end is PublishJobState$Completed) _releaseSources(record.id);
    _changed(record.id);
    _releaseGroup(record);
  }

  /// Deletes the files written for job [id]'s sources.
  void _releaseSources(PublishJobId id) =>
      unawaited(_reportingRelease(_uploads.releaseSources(id), id: id));

  /// Waits for [release] and reports its failure: a file left behind.
  static Future<void> _reportingRelease(
    Future<void> release, {
    PublishJobId? id,
  }) async {
    try {
      await release;
    } on Object catch (_, stackTrace) {
      MpxDiagnostics.current.emit(
        MpxEventLevel.error,
        JournalOp.writeFailed,
        jobId: id,
        // The error stays out: a file system error names a path.
        fields: () => {'code': 'source_delete'},
        stackTrace: stackTrace,
      );
    }
  }

  // --- State -----------------------------------------------------------------

  PublishJobSnapshot _snapshot(PublishRecord record) {
    final measures = [for (final item in record.items) _measure(record, item)];
    final state = _stateOf(record);
    return PublishJobSnapshot(
      id: record.id,
      state: state,
      items: [
        for (final (i, item) in record.items.indexed)
          _itemSnapshot(record, item, measures[i].fraction),
      ],
      tag: record.tag,
      publisher: record.publisher,
      createdAt: record.createdAt,
      progress: _progressOf(record.id).job.fold(
        state is PublishJobState$Completed
            ? 1
            : (1 - _weights.publish) * measures.fraction,
      ),
      aliasesApplied:
          record.end is PublishJobState$Completed && record.aliases.isEmpty,
      held: record.hold && !record.committed,
    );
  }

  PublishItemSnapshot _itemSnapshot(
    PublishRecord record,
    PublishItemRecord item, [
    double? progress,
  ]) => PublishItemSnapshot(
    itemId: item.item.itemId,
    key: item.item.key,
    state: _itemState(record.id, item),
    progress: progress ?? _measure(record, item).fraction,
  );

  // --- Progress --------------------------------------------------------------

  _Progress _progressOf(PublishJobId id) => _progress.putIfAbsent(
    id,
    () => _Progress(_journal.record(id)?.progress ?? 0),
  );

  /// Item [item] of [record] as the job's progress counts it: its bytes and
  /// its share done, folded so the share never goes back.
  ItemMeasure _measure(PublishRecord record, PublishItemRecord item) {
    final itemId = item.item.itemId;
    final progress = _progressOf(record.id);
    final fold = progress.items.putIfAbsent(itemId, ProgressFold.new);
    final source = item.item.source;
    if (source is PublishSource$Remote) return (weight: 0, fraction: 1);
    final share = switch (source) {
      PublishSource$Prepare(:final intent) => _weights.preparationOf(intent),
      _ => 0.0,
    };
    final sourceSize = switch (source) {
      PublishSource$Prepare(:final input) =>
        input.byteSize ?? progress.sources[itemId],
      PublishSource$Prepared(:final media) => media.byteSize,
      PublishSource$Remote() => 0,
    };
    final (int? weight, double? done) = switch (item.progress) {
      ItemProgress$Waiting() => (
        sourceSize,
        switch (_live[record.id]?.preparations[itemId]) {
          final handle? => share * handle.progress.value,
          null => 0.0,
        },
      ),
      ItemProgress$Prepared(:final media) => (media.byteSize, share),
      ItemProgress$Uploading(:final media, :final file, :final thumbnail) =>
        switch (_uploading([file, ?thumbnail])) {
          final PublishItemState$Uploading uploading => (
            uploading.total ?? media.byteSize,
            share +
                (1 - share) *
                    _share(uploading.sent, uploading.total ?? media.byteSize),
          ),
          _ => (media.byteSize, share),
        },
      ItemProgress$Uploaded() => (progress.weights[itemId] ?? sourceSize, 1.0),
      // A failed item holds the share it reached.
      ItemProgress$Failed() => (progress.weights[itemId] ?? sourceSize, null),
    };
    if (weight != null) progress.weights[itemId] = weight;
    return (
      weight: weight,
      fraction: done == null ? fold.value : fold.fold(done),
    );
  }

  static double _share(int sent, int total) =>
      total <= 0 ? 0 : (sent / total).clamp(0.0, 1.0);

  PublishItemState _itemStateOf(PublishJobId id, PublishItem item) {
    final record = _itemRecord(id, item.itemId);
    return record == null
        ? const PublishItemState.removed()
        : _itemState(id, record);
  }

  PublishItemState _itemState(PublishJobId id, PublishItemRecord item) =>
      switch (item.progress) {
        ItemProgress$Waiting() =>
          switch (_live[id]?.preparations[item.item.itemId]) {
            final handle? => PublishItemState.preparing(handle.progress.value),
            null => const PublishItemState.waiting(),
          },
        ItemProgress$Prepared(:final media) => PublishItemState.uploading(
          sent: 0,
          total: media.byteSize,
        ),
        ItemProgress$Uploading(:final file, :final thumbnail) => _uploading([
          file,
          ?thumbnail,
        ]),
        ItemProgress$Uploaded(:final file, :final thumbnail) =>
          PublishItemState.uploaded(file: file, thumbnail: thumbnail),
        ItemProgress$Failed(:final stage, :final reason, :final retryable) =>
          PublishItemState.failed(
            stage: stage,
            reason: reason,
            retryable: retryable,
          ),
      };

  /// The uploads [ids] together: the bytes sent of the bytes to send.
  PublishItemState _uploading(List<TransferId> ids) {
    var sent = 0;
    int? total = 0;
    var estimated = false;
    for (final id in ids) {
      final record = _host.recordOf(id);
      final size = record?.upload?.source.size;
      final state = record?.job.state;
      switch (state) {
        case TransferState$Completed():
          sent += size ?? 0;
        case final TransferState moving?:
          sent += moving.done;
          if (moving case TransferState$Running(estimated: true)) {
            estimated = true;
          }
        case null:
          break;
      }
      final known = state?.total ?? size;
      total = total == null || known == null ? null : total + known;
    }
    return PublishItemState.uploading(
      sent: sent,
      total: total,
      estimated: estimated,
    );
  }

  PublishJobState _stateOf(PublishRecord record) {
    if (record.end case final end?) return end;
    final live = _live[record.id];
    if (live?.attempting ?? false) return const PublishJobState.publishing();
    if (record.awaitingOwner) return const PublishJobState.awaitingOwner();
    final progress = [for (final item in record.items) item.progress];
    if (progress.any((p) => p is ItemProgress$Waiting)) {
      return const PublishJobState.preparing();
    }
    for (final p in progress) {
      if (p is! ItemProgress$Uploading) continue;
      for (final id in [p.file, ?p.thumbnail]) {
        if (_host.recordOf(id)?.job.state case TransferState$Paused(
          :final reason,
        )) {
          return PublishJobState.paused(reason);
        }
      }
    }
    if (progress.any(
      (p) => p is ItemProgress$Prepared || p is ItemProgress$Uploading,
    )) {
      return const PublishJobState.uploading();
    }
    if (progress.any((p) => p is ItemProgress$Failed) ||
        (record.hold && !record.committed)) {
      // Per-item policy: publish waits for the host; a held job, for its
      // commit.
      return const PublishJobState.uploading();
    }
    final publisher = record.publisher;
    if (publisher == null) return const PublishJobState.uploading();
    return _publishers.containsKey(publisher)
        ? const PublishJobState.publishing()
        : const PublishJobState.awaitingPublisher();
  }

  // --- Plumbing --------------------------------------------------------------

  /// Whether job [id] still goes on: not ended, and not cancelled (a
  /// cancelled job has no record).
  bool _running(PublishJobId id) =>
      !_disposed && (_journal.record(id)?.isRunning ?? false);

  _Live _liveOf(PublishJobId id) => _live.putIfAbsent(id, _Live.new);

  PublishItemRecord? _itemRecord(PublishJobId id, String itemId) {
    for (final item
        in _journal.record(id)?.items ?? const <PublishItemRecord>[]) {
      if (item.item.itemId == itemId) return item;
    }
    return null;
  }

  /// Writes [record] with the progress its job shows now, which a restart
  /// starts from.
  Future<void> _put(PublishRecord record) {
    final shown = _progress[record.id]?.job.value ?? 0;
    return _journal.put(
      shown > record.progress ? record.copyWith(progress: shown) : record,
    );
  }

  /// Tells job [id]'s watchers, and the lists that hold it, what changed.
  /// The snapshot is made even with no one watching, so the job's progress
  /// folds in every step it took.
  void _changed(PublishJobId id) {
    if (_disposed) return;
    _host.publishChanged();
    final record = _journal.record(id);
    if (record == null) return;
    final next = _snapshot(record);
    for (final watch in [...?_live[id]?.watches]) {
      if (watch.last == next) continue;
      watch.last = next;
      watch.sink.add(next);
    }
    for (final watch in [..._jobsWatches]) {
      final passes = watch.filter.matches(next);
      final before = {for (final job in watch.last) job.id: job};
      if (!passes && !before.containsKey(id)) continue;
      if (passes && before[id] == next) continue;
      // Only job [id] changed: the others keep the snapshots given last.
      watch.last = [
        for (final other in _journal.records)
          if (other.id == id) ...[if (passes) next] else ?before[other.id],
      ];
      watch.sink.add(watch.last);
    }
  }
}

/// A job's progress shown so far in this run, and what it was weighed by.
final class _Progress {
  _Progress(double floor) : job = ProgressFold(floor);

  /// The job's value, starting from what its record kept.
  final ProgressFold job;

  /// Each item's value, by item id.
  final Map<String, ProgressFold> items = {};

  /// Each item's weight last known, by item id: what an uploaded or failed
  /// item keeps weighing.
  final Map<String, int> weights = {};

  /// The sizes of sources the host gave no size for, read from the file.
  final Map<String, int> sources = {};
}

/// One `watchJobs` listener: its filter and the list it saw last.
final class _JobsWatch {
  _JobsWatch(this.filter, this.sink, this.last);

  final PublishJobFilter filter;
  final MultiStreamController<List<PublishJobSnapshot>> sink;
  List<PublishJobSnapshot> last;
}

/// What a job holds in this run only.
final class _Live {
  /// Preparations under way, by item id.
  final Map<String, PreparationHandle> preparations = {};

  final List<_JobWatch> watches = [];

  /// Items whose thumbnail upload is being queued again after a restart.
  final Set<String> requeuing = {};

  /// Whether the publisher's call is under way.
  bool attempting = false;

  /// Whether `awaitingPublisher` was reported in this run.
  bool reportedAwaiting = false;

  /// The source a retry of an item gave, by item id, until its failed
  /// file upload is queued again over it.
  final Map<String, SourceBytes> newSources = {};

  /// Whether the job's current wait for its ordering group was reported.
  bool reportedGroupWait = false;
}

/// One `watch` listener and the snapshot it saw last.
final class _JobWatch {
  _JobWatch(this.sink, this.last);

  final MultiStreamController<PublishJobSnapshot> sink;
  PublishJobSnapshot last;
}
