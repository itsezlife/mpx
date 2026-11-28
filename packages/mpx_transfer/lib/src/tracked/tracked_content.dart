import 'package:flutter/foundation.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show BytesCacheKey;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/download/transfer_downloads.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/journal/journal_record.dart';
import 'package:mpx_transfer/src/journal/transfer_journal.dart';
import 'package:mpx_transfer/src/publish/publish_jobs.dart';
import 'package:mpx_transfer/src/publish/publish_request.dart';
import 'package:mpx_transfer/src/transfers.dart';

/// The engine's jobs seen by content key, as the core's [TrackedTransfers]:
/// what a binding with a status control and a saver read and ask, in both
/// directions.
///
/// - **Download.** The key's download job, by its derived id.
/// - **Upload.** The uploads of a publish job item whose local key is the
///   key, found through each upload's owner (job and item) and its key. An
///   item's uploads (its file, and its thumbnail for a transport that takes
///   it apart) read as one value. Once they all completed it is sent until
///   its job published and aliased its server keys, then none, the local
///   picture kept. An item no longer in its job (removed, its job cancelled
///   or dropped after its retention) reads none.
///
/// While the key has an upload that does not read none, the upload is the
/// value; a download of the same key shows otherwise.
///
/// Internal: hosts reach it as `Transfers.tracked`.
final class TrackedContent implements TrackedTransfers {
  /// The view of [engine]'s jobs kept in [journal], downloads fetching
  /// through [downloads] and uploads made by [publish]; either may be
  /// absent.
  TrackedContent({
    required Transfers engine,
    required TransferJournal journal,
    TransferDownloads? downloads,
    PublishJobs? publish,
  }) : _engine = engine,
       _journal = journal,
       _downloads = downloads,
       _publish = publish;

  final Transfers _engine;
  final TransferJournal _journal;
  final TransferDownloads? _downloads;
  final PublishJobs? _publish;
  final Map<MediaKey, _KeyWatch> _watches = {};

  TransferJob? _downloadOf(MediaKey key) {
    final job = _engine.jobOf(TransferId.forDownload(_engine.cacheKeyOf(key)));
    return job?.direction == TransferDirection.download ? job : null;
  }

  /// The publish job items whose local key is [key] and that are still in
  /// their jobs, the newest first.
  List<_ItemUploads> _itemsOf(MediaKey key) {
    final publish = _publish;
    if (publish == null) return const [];
    final items = <(String, String), List<JournalRecord>>{};
    for (final record in _journal.records) {
      final owner = record.upload?.owner;
      if (owner == null || record.job.key != key) continue;
      items.putIfAbsent((owner.job, owner.itemId), () => []).add(record);
    }
    // Records are in the order their jobs were made: the newest item last.
    return [
      for (final MapEntry(key: (job, itemId), value: uploads)
          in items.entries.toList().reversed)
        if (publish.itemAliased(PublishJobId.parse(job), itemId)
            case final aliased?)
          _ItemUploads(
            PublishJobId.parse(job),
            itemId,
            uploads,
            aliased: aliased,
          ),
    ];
  }

  /// The upload of [key]'s content that a surface shows: the newest item
  /// with the key whose uploads do not read none; null when there is none.
  _ItemUploads? _uploadOf(MediaKey key) => _itemsOf(
    key,
  ).where((item) => item.value is! AssetTransfer$None).firstOrNull;

  /// What [key]'s surfaces show now, and the job it comes from: an upload
  /// under way, else the download, else a published item's upload (none).
  _Seen _see(MediaKey key) {
    final items = _itemsOf(key);
    final upload = items
        .where((item) => item.value is! AssetTransfer$None)
        .firstOrNull;
    final job = _downloadOf(key);
    if (upload ?? (job == null ? items.firstOrNull : null) case final item?) {
      final lead = item.lead.job;
      return (
        value: item.value,
        jobId: lead.id,
        itemId: item.itemId,
        state: _stateName(lead.state),
      );
    }
    return (
      value: valueOf(job),
      jobId: job?.id,
      itemId: null,
      state: job == null ? 'none' : _stateName(job.state),
    );
  }

  /// Starts or joins [key]'s download. For a key whose upload the user
  /// paused it resumes the upload, and for one whose upload failed it
  /// retries the item in its job (the status control's download is the
  /// retry); while the key's upload goes on it does nothing, the content
  /// being local. Without downloads on the facade nothing else happens.
  @override
  void download(MediaKey key, {TransferOrigin origin = TransferOrigin.user}) {
    if (_uploadOf(key) case final upload?) {
      switch (upload.value) {
        case AssetTransfer$AwaitingUser():
          for (final record in upload.uploads) {
            if (record.job.state is TransferState$Paused) {
              _engine.resume(record.job.id);
            }
          }
        case AssetTransfer$Failed():
          _publish?.retryItem(upload.job, upload.itemId);
        case _:
          break;
      }
      return;
    }
    if (_downloads == null) return;
    _engine.download(key, origin: origin);
  }

  @override
  ValueListenable<AssetTransfer> watch(MediaKey key) =>
      _watches.putIfAbsent(key, () => _KeyWatch(this, key));

  /// A download's cancel is the user's pause: the job keeps its bytes and
  /// `download` resumes it. An upload's cancel removes its item from its
  /// publish job, as a cell's (`itemRemoved`, by: cell): the rest of the
  /// job goes on, and a job left with no items waits for its owner.
  @override
  void cancel(MediaKey key) {
    if (_uploadOf(key) case final upload?) {
      _publish?.removeItem(upload.job, upload.itemId, by: 'cell');
      return;
    }
    final job = _downloadOf(key);
    if (job == null) return;
    switch (job.state) {
      case TransferState$Queued() ||
          TransferState$Running() ||
          TransferState$Paused(reason: PauseReason.systemInterrupted) ||
          TransferState$Paused(reason: PauseReason.awaitingNetwork):
        _engine.pause(job.id);
      case TransferState$Paused() ||
          TransferState$Failed() ||
          TransferState$Completed():
        break;
    }
  }

  @override
  Future<ContentFileLease?> leaseFile(MediaKey key) async {
    final store = _downloads?.store;
    if (store == null) return null;
    final cacheKey = BytesCacheKey(_engine.cacheKeyOf(key));
    // A ranged resource still arriving has a file too; only a whole one is
    // lent.
    if (!store.contains(cacheKey)) return null;
    final lease = await store.leaseFile(cacheKey);
    if (lease == null) return null;
    return ContentFileLease(path: lease.path, onRelease: lease.release);
  }

  /// The engine's jobs or publish jobs changed: every watched key whose
  /// value moved tells its listeners, and a watched download waiting to
  /// resume resumes.
  void refresh() {
    final resume = <TransferId>[];
    for (final watch in [..._watches.values]) {
      if (!watch.listened) continue;
      final job = _downloadOf(watch.key);
      if (_awaitsResume(job)) resume.add(job!.id);
      watch.update();
    }
    resume.forEach(_engine.resume);
  }

  void _watched(_KeyWatch watch) {
    final job = _downloadOf(watch.key);
    if (_awaitsResume(job)) _engine.resume(job!.id);
  }

  void _unwatched(_KeyWatch watch) {
    if (identical(_watches[watch.key], watch)) _watches.remove(watch.key);
  }

  static bool _awaitsResume(TransferJob? job) =>
      job != null &&
      job.state is TransferState$Paused &&
      (job.state as TransferState$Paused).reason == PauseReason.awaitingResume;

  /// The value a surface shows for download [job] (null when the key has
  /// none).
  static AssetTransfer valueOf(TransferJob? job) {
    if (job == null || job.direction != TransferDirection.download) {
      return AssetTransfer.none;
    }
    return switch (job.state) {
      TransferState$Queued(:final total) => AssetTransfer.waiting(total),
      TransferState$Running(:final done, :final total) =>
        AssetTransfer.receiving(done, total),
      TransferState$Paused(
        reason: PauseReason.user || PauseReason.awaitingResume,
        :final done,
        :final total,
      ) =>
        AssetTransfer.awaitingUser(total, done),
      // Frozen: the ring holds where it was and cancel still works.
      TransferState$Paused(:final done, :final total) =>
        AssetTransfer.receiving(done, total),
      TransferState$Failed(:final retryable, :final done, :final total) =>
        AssetTransfer.failed(
          retryable ? AssetFailureKind.transient : AssetFailureKind.permanent,
          done,
          total,
        ),
      TransferState$Completed() => AssetTransfer.none,
    };
  }

  /// The state as a binding's `mapped` event names it: a pause with its
  /// reason, as `paused.user`.
  static String _stateName(TransferState state) => switch (state) {
    TransferState$Paused(:final reason) => '${state.name}.${reason.name}',
    _ => state.name,
  };

  static String _transferName(AssetTransfer transfer) => switch (transfer) {
    AssetTransfer$None() => 'none',
    AssetTransfer$Waiting() => 'waiting',
    AssetTransfer$Receiving() => 'receiving',
    AssetTransfer$AwaitingUser() => 'awaitingUser',
    AssetTransfer$Failed() => 'failed',
    AssetTransfer$Sending() => 'sending',
    AssetTransfer$Sent() => 'sent',
  };
}

/// What a key's surfaces show, with the job (and item) it comes from.
typedef _Seen = ({
  AssetTransfer value,
  TransferId? jobId,
  String? itemId,
  String state,
});

/// The uploads of one publish job item, read as the one value its cells
/// show.
final class _ItemUploads {
  _ItemUploads(this.job, this.itemId, this.uploads, {required this.aliased});

  final PublishJobId job;
  final String itemId;

  /// The item's uploads: its file, and its thumbnail when sent apart.
  final List<JournalRecord> uploads;

  /// Whether the item's job published and aliased its server keys.
  final bool aliased;

  /// The file's upload, which names the item in diagnostics.
  JournalRecord get lead => uploads.firstWhere(
    (record) => record.upload?.owner?.role == UploadRole.file,
    orElse: () => uploads.first,
  );

  /// The uploads together:
  ///
  /// | Uploads | Value |
  /// | --- | --- |
  /// | any failed | failed, transient while every failure may be retried |
  /// | any paused by the user, or waiting to resume | awaitingUser |
  /// | all completed | sent, or none once aliased |
  /// | all queued | waiting |
  /// | otherwise (running, paused by the system or for the network) | sending, its bytes held while paused |
  late final AssetTransfer value = _value();

  AssetTransfer _value() {
    var done = 0;
    int? total = 0;
    var failed = false;
    var retryable = true;
    var userPaused = false;
    var completed = true;
    var queued = true;
    for (final record in uploads) {
      final state = record.job.state;
      final size = record.upload?.source.size;
      if (state is! TransferState$Completed) completed = false;
      if (state is! TransferState$Queued) queued = false;
      switch (state) {
        case TransferState$Completed():
          done += size ?? 0;
        case TransferState$Failed(retryable: final again):
          failed = true;
          retryable = retryable && again;
          done += state.done;
        case TransferState$Paused(
          reason: PauseReason.user || PauseReason.awaitingResume,
        ):
          userPaused = true;
          done += state.done;
        case TransferState$Queued():
          break;
        case TransferState$Running() || TransferState$Paused():
          done += state.done;
      }
      final known = state is TransferState$Completed
          ? size
          : state.total ?? size;
      total = total == null || known == null ? null : total + known;
    }
    if (failed) {
      return AssetTransfer.failed(
        retryable ? AssetFailureKind.transient : AssetFailureKind.permanent,
        done,
        total,
      );
    }
    if (userPaused) return AssetTransfer.awaitingUser(total, done);
    if (completed) return aliased ? AssetTransfer.none : AssetTransfer.sent;
    if (queued) return AssetTransfer.waiting(total);
    return AssetTransfer.sending(done, total);
  }
}

/// One key's value. Read live from the engine, so a listenable kept without
/// a listener still reads right; told of changes while it has listeners.
final class _KeyWatch extends ChangeNotifier
    implements ValueListenable<AssetTransfer> {
  _KeyWatch(this._view, this.key);

  final TrackedContent _view;
  final MediaKey key;
  AssetTransfer _last = AssetTransfer.none;

  /// Whether anyone listens now.
  bool get listened => hasListeners;

  @override
  AssetTransfer get value => _view._see(key).value;

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (!first) return;
    _view._watches[key] = this;
    _last = value;
    _view._watched(this);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _view._unwatched(this);
  }

  void update() {
    final seen = _view._see(key);
    final next = seen.value;
    if (next == _last) return;
    _last = next;
    MpxDiagnostics.current.emit(
      MpxEventLevel.trace,
      BindingOp.mapped,
      jobId: seen.jobId,
      itemId: seen.itemId,
      mediaKey: key,
      fields: () => {
        'state': seen.state,
        'transfer': TrackedContent._transferName(next),
      },
    );
    notifyListeners();
  }
}
