import 'package:flutter/foundation.dart';
import 'package:http_bytes_cache/http_bytes_cache.dart' show BytesCacheKey;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_transfer/src/download/transfer_downloads.dart';
import 'package:mpx_transfer/src/job/transfer_id.dart';
import 'package:mpx_transfer/src/job/transfer_job.dart';
import 'package:mpx_transfer/src/job/transfer_state.dart';
import 'package:mpx_transfer/src/transfers.dart';

/// The engine's jobs seen by key, as the core's [TrackedTransfers]: what a
/// binding with a status control and a saver read and ask.
///
/// Internal: hosts reach it as `Transfers.tracked`.
final class TrackedDownloads implements TrackedTransfers {
  /// The view of [_engine]'s download jobs, leasing files from [_downloads].
  TrackedDownloads(this._engine, this._downloads);

  final Transfers _engine;
  final TransferDownloads _downloads;
  final Map<MediaKey, _KeyWatch> _watches = {};

  TransferId _idOf(MediaKey key) =>
      TransferId.forDownload(_engine.cacheKeyOf(key));

  TransferJob? _jobOf(MediaKey key) => _engine.jobOf(_idOf(key));

  @override
  void download(MediaKey key, {TransferOrigin origin = TransferOrigin.user}) =>
      _engine.download(key, origin: origin);

  @override
  ValueListenable<AssetTransfer> watch(MediaKey key) =>
      _watches.putIfAbsent(key, () => _KeyWatch(this, key));

  /// A download's cancel is the user's pause: the job keeps its bytes and
  /// `download` resumes it.
  @override
  void cancel(MediaKey key) {
    final job = _jobOf(key);
    if (job == null || job.direction != TransferDirection.download) return;
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
    final cacheKey = BytesCacheKey(_engine.cacheKeyOf(key));
    // A ranged resource still arriving has a file too; only a whole one is
    // lent.
    if (!_downloads.store.contains(cacheKey)) return null;
    final lease = await _downloads.store.leaseFile(cacheKey);
    if (lease == null) return null;
    return ContentFileLease(path: lease.path, onRelease: lease.release);
  }

  /// The engine's jobs changed: every watched key whose value moved tells
  /// its listeners, and a watched download waiting to resume resumes.
  void refresh() {
    final resume = <TransferId>[];
    for (final watch in [..._watches.values]) {
      if (!watch.listened) continue;
      final job = _jobOf(watch.key);
      if (_awaitsResume(job)) resume.add(job!.id);
      watch.update(job);
    }
    resume.forEach(_engine.resume);
  }

  void _watched(_KeyWatch watch) {
    final job = _jobOf(watch.key);
    if (_awaitsResume(job)) _engine.resume(job!.id);
  }

  void _unwatched(_KeyWatch watch) {
    if (identical(_watches[watch.key], watch)) _watches.remove(watch.key);
  }

  static bool _awaitsResume(TransferJob? job) =>
      job != null &&
      job.direction == TransferDirection.download &&
      job.state is TransferState$Paused &&
      (job.state as TransferState$Paused).reason == PauseReason.awaitingResume;

  /// The value a surface shows for [job] (null when the key has none).
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

  static String _stateName(TransferState state) => switch (state) {
    TransferState$Queued() => 'queued',
    TransferState$Running() => 'running',
    TransferState$Paused(:final reason) => 'paused.${reason.name}',
    TransferState$Failed() => 'failed',
    TransferState$Completed() => 'completed',
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

/// One key's value. Read live from the engine, so a listenable kept without
/// a listener still reads right; told of changes while it has listeners.
final class _KeyWatch extends ChangeNotifier
    implements ValueListenable<AssetTransfer> {
  _KeyWatch(this._view, this.key);

  final TrackedDownloads _view;
  final MediaKey key;
  AssetTransfer _last = AssetTransfer.none;

  /// Whether anyone listens now.
  bool get listened => hasListeners;

  @override
  AssetTransfer get value => TrackedDownloads.valueOf(_view._jobOf(key));

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

  void update(TransferJob? job) {
    final next = TrackedDownloads.valueOf(job);
    if (next == _last) return;
    _last = next;
    MpxDiagnostics.current.emit(
      MpxEventLevel.trace,
      BindingOp.mapped,
      jobId: job?.id,
      mediaKey: key,
      fields: () => {
        'state': job == null ? 'none' : TrackedDownloads._stateName(job.state),
        'transfer': TrackedDownloads._transferName(next),
      },
    );
    notifyListeners();
  }
}
