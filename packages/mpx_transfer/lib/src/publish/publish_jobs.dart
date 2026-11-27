import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/diagnostics/publish_op.dart';
import 'package:mpx_transfer/src/diagnostics/transfers_debug_snapshot.dart';
import 'package:mpx_transfer/src/diagnostics/transport_op.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
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
/// uploads are, and a way to queue one.
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
  });
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
///   with no publisher (an upload on its own) completes there.
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
      watch(id)
          .map(
            (job) =>
                job.item(itemId) ??
                (throw ArgumentError.value(
                  itemId,
                  'itemId',
                  'is not in the job',
                )),
          )
          .distinct();

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
    for (final record in [..._journal.records]) {
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
  /// leave. Answers null
  /// for an unknown job.
  List<TransferId>? cancel(PublishJobId id) {
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
    for (final watch in [..._jobsWatches]) {
      if (!watch.last.any((job) => job.id == id)) continue;
      watch.last = [
        for (final job in watch.last)
          if (job.id != id) job,
      ];
      watch.sink.add(watch.last);
    }
    return [
      for (final item in record.items)
        if (item.progress case ItemProgress$Uploading(
          :final file,
          :final thumbnail,
        )) ...[
          file,
          ?thumbnail,
        ],
    ];
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
    final ids = <String>{};
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
    final carrier = transport ?? _uploads.transportIds.firstOrNull;
    if (uploads && (carrier == null || _uploads.transport(carrier) == null)) {
      throw ArgumentError.value(
        transport,
        'transport',
        'is not one of the facade transports',
      );
    }
    final now = _now();
    final record = PublishRecord(
      id: id,
      tag: tag,
      publisher: publisher,
      transport: uploads ? carrier : null,
      payload: payload,
      durability: durability,
      failurePolicy: failurePolicy,
      orderingGroup: orderingGroup,
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

  static String _newKey() => [
    for (var i = 0; i < 16; i++)
      _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();

  // --- Items -----------------------------------------------------------------

  /// Moves item [itemId] on from where its record says it is.
  Future<void> _runItem(
    PublishJobId id,
    String itemId, {
    bool restored = false,
  }) async {
    final item = _itemRecord(id, itemId);
    if (item == null) return;
    switch (item.progress) {
      case ItemProgress$Waiting():
        await _lookUpAndPrepare(id, item.item);
      case ItemProgress$Prepared(:final media, :final reuseKey):
        await _upload(id, item.item, media, reuseKey);
      case ItemProgress$Uploading():
        if (restored) _queueMissingUploads(id, item);
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
    TransferId? thumbnailId;
    final JournalUpload file;
    JournalUpload? thumbnail;
    try {
      file = _describeFile(id, item, media);
      if (transport.capabilities.thumbnail == UploadThumbnail.separate &&
          media.thumbnailPath != null) {
        final stat = await _uploads.stat(media.thumbnailPath!);
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
        thumbnail = _describeThumbnail(id, item, media, stat.size);
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
              media,
              file: fileId,
              thumbnail: thumbnailId,
              reuseKey: reuseKey,
            ),
            _now(),
          ),
    );
    if (!_running(id)) return;
    _enqueue(record, item, fileId, file);
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
    JournalUpload upload,
  ) {
    _$enqueuing = true;
    try {
      _host.enqueueUpload(
        id,
        upload,
        durability: record.durability,
        tag: record.tag,
        key: item.key,
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
      ItemProgress$Uploaded(file: fileRef, thumbnail: thumbnailRef),
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
    ItemProgress$Failed(stage: stage, reason: reason, retryable: retryable),
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
    if (!record.items.every((item) => item.progress is ItemProgress$Uploaded)) {
      _changed(id);
      return;
    }
    final name = record.publisher;
    if (name == null) {
      _end(record, const PublishJobState.completed(null));
      return;
    }
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
    if (live.attempting) return;
    unawaited(_attempt(record, publisher));
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
    switch (outcome) {
      case PublishOutcome$Published(:final result, :final serverKeys):
        MpxDiagnostics.current.emit(
          MpxEventLevel.info,
          PublishOp.outcome,
          jobId: id,
          tag: record.tag,
          fields: () => {
            'outcome': outcome.name,
            'retryable': false,
            'serverKeys': serverKeys.length,
          },
        );
        _end(_journal.record(id)!, PublishJobState.completed(result));
    }
  }

  void _end(PublishRecord record, PublishJobState end) {
    unawaited(_put(record.copyWith(end: end, updatedAt: _now())));
    _changed(record.id);
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
            : (1 - _weights.publish) * itemsFraction(measures),
      ),
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
    if (progress.any((p) => p is ItemProgress$Failed)) {
      // Per-item policy: publish waits for the host.
      return const PublishJobState.uploading();
    }
    final publisher = record.publisher;
    if (publisher == null) return const PublishJobState.uploading();
    return _publishers.containsKey(publisher)
        ? const PublishJobState.publishing()
        : const PublishJobState.awaitingPublisher();
  }

  // --- Plumbing --------------------------------------------------------------

  bool _running(PublishJobId id) =>
      !_disposed && _journal.record(id)?.end == null;

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
}

/// One `watch` listener and the snapshot it saw last.
final class _JobWatch {
  _JobWatch(this.sink, this.last);

  final MultiStreamController<PublishJobSnapshot> sink;
  PublishJobSnapshot last;
}
