import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/save/media_saver.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_op.dart';
import 'package:mpx_library/src/save/save_request.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// Runs a `MediaSaver.save` batch over a [SaveWriter]: the rules every
/// platform shares, in one place.
///
/// - One batch is one job with one id, one progress and a result per item.
/// - A cancel before the work begins cancels every item; between items it
///   cancels the rest; inside an item it is the writer's to honour. A block
///   writer's batch is cancelled only before its block begins; the block's
///   end, or its cancel before it began, is reported (`changeBlock`).
/// - A failed admission (denied access, no adapter) fails every item.
/// - A `file` item sent to the gallery goes as a photo or a video by its MIME
///   type, or fails `unsupportedFormat` unwritten.
/// - A leased file is never moved.
/// - Every lease is released once its item ends, before the results
///   complete.
/// - Every step reports its `save` event through `MpxDiagnostics.current`.
///
/// A `MediaSaver.saveContent` batch ([runContent]) first makes each content
/// local through `TrackedTransfers`, then saves the leased files under the
/// same rules.
abstract final class SaveJobRunner {
  static int _lastJob = 0;

  /// Starts saving [items] to [destination] through [writer] and returns the
  /// job at once; the work begins on a later microtask, so a cancel right
  /// after this call lands before anything is written.
  static SaveJob run(
    List<SaveItem> items,
    SaveDestination destination,
    SaveWriter writer,
  ) {
    final job = _Job('save-${++_lastJob}', [
      for (final item in items) _Slot.item(item),
    ]);
    unawaited(job._run(destination, writer));
    return job;
  }

  /// Starts saving the contents [requests] name to [destination] through
  /// [writer], downloading through [transfers] those not local, and returns
  /// the job at once, as [run] does. Without [transfers] every item fails
  /// `SaveFailure.unavailable`.
  static SaveJob runContent(
    List<SaveRequest> requests,
    SaveDestination destination,
    SaveWriter writer,
    TrackedTransfers? transfers,
  ) {
    final job = _Job('save-${++_lastJob}', [
      for (final request in requests) _Slot.request(request),
    ]);
    unawaited(job._runContent(destination, writer, transfers));
    return job;
  }
}

/// One item of a job: what it is, the item to write once known, and how far
/// it is.
final class _Slot {
  _Slot.item(SaveItem this.item)
    : request = null,
      kind = item.kind,
      mimeType = item.mimeType;

  _Slot.request(SaveRequest this.request)
    : kind = request.kind,
      mimeType = request.mimeType;

  /// The share of an item's progress its download takes when it has one.
  static const double _downloadShare = 0.9;

  /// The `saveContent` request; null for a `save` item.
  final SaveRequest? request;

  /// What the caller filed it as.
  final SaveItemKind kind;

  /// Its MIME type, as the caller gave it.
  final String mimeType;

  /// The item to write: given for `save`, the leased file once a
  /// `saveContent` item is local.
  SaveItem? item;

  /// Whether the item's share of the progress is its copy alone: a `save`
  /// item, or a content already local. Otherwise its download takes
  /// [_downloadShare] of it and its copy the rest.
  bool copyOnly = true;

  /// How far its download is, 0 to 1.
  double downloaded = 0;

  /// How far its copy is, 0 to 1.
  double copied = 0;

  /// How much of the item's share is done, 0 to 1.
  double get done => copyOnly
      ? copied
      : _downloadShare * downloaded + (1 - _downloadShare) * copied;

  /// The content's key, for the item's events; null for a `save` item.
  MediaKey? get mediaKey => request?.key;
}

/// How a `saveContent` item's download ended for its job.
enum _Arrival {
  /// The content is whole and local.
  complete,

  /// The download failed.
  failed,

  /// The download stopped without the job's cancel (paused elsewhere).
  stopped,

  /// The job was cancelled.
  cancelled,
}

final class _Job implements SaveJob {
  _Job(this.id, this._slots) : _results = List.filled(_slots.length, null);

  @override
  final String id;

  final List<_Slot> _slots;
  final List<SaveResult?> _results;
  final ValueNotifier<double> _progress = ValueNotifier(0);
  final Completer<List<SaveResult>> _done = Completer();
  final CancellationToken _cancellation = CancellationToken();
  final List<Future<void>> _releases = [];
  final Stopwatch _clock = Stopwatch();
  late final List<int?> _bytes = List.filled(_slots.length, null);

  @override
  ValueListenable<double> get progress => _progress;

  @override
  Future<List<SaveResult>> get results => _done.future;

  @override
  void cancel() {
    if (_done.isCompleted || _cancellation.isCancelled) return;
    _cancellation.cancel();
    _stopDownloads();
  }

  Future<void> _run(SaveDestination destination, SaveWriter writer) async {
    if (await _begin(destination, writer)) await _save(destination, writer);
    return _finish();
  }

  /// Reports the start and lets a cancel made right after the call land
  /// before anything starts; false when one did, every item then
  /// cancelled.
  Future<bool> _begin(SaveDestination destination, SaveWriter writer) async {
    _clock.start();
    _emit(
      MpxEventLevel.info,
      SaveOp.jobStarted,
      () => {
        'items': _slots.length,
        'destination': destination.name,
        'named': destination.isNamed,
        'platform': MpxEvent.clip(writer.platform),
        'photos': _count(SaveItemKind.photo),
        'videos': _count(SaveItemKind.video),
        'animations': _count(SaveItemKind.animation),
        'files': _count(SaveItemKind.file),
      },
    );
    await Future<void>.value();
    if (!_cancellation.isCancelled) return true;
    _endRemaining(const SaveResult.cancelled());
    return false;
  }

  /// Admits and writes every item.
  Future<void> _save(SaveDestination destination, SaveWriter writer) async {
    if (await _admitted(destination, writer, [
      for (final slot in _slots) slot.item!,
    ])) {
      await _write(destination, writer);
    }
  }

  /// Admits the batch through [writer] with [items]; false when it was
  /// refused, every item then ended with the refusal.
  Future<bool> _admitted(
    SaveDestination destination,
    SaveWriter writer,
    List<SaveItem> items,
  ) async {
    final refused = await _admit(writer, destination, items);
    if (refused == null) return true;
    _endRemaining(refused);
    return false;
  }

  /// Writes every item not ended yet.
  Future<void> _write(SaveDestination destination, SaveWriter writer) async {
    final writes = <SaveWrite>[];
    for (var i = 0; i < _slots.length; i++) {
      if (_results[i] != null) continue;
      if (_writeOf(i, destination) case final write?) writes.add(write);
    }
    switch (writer) {
      case SaveWriter$PerItem():
        await _writeEach(writer, writes);
      case SaveWriter$Block():
        await _writeBlock(writer, writes);
    }
  }

  Future<SaveResult$Failed?> _admit(
    SaveWriter writer,
    SaveDestination destination,
    List<SaveItem> items,
  ) async {
    try {
      return await writer.admit(id, destination, items);
    } on Object catch (error, stackTrace) {
      _error = (error, stackTrace);
      return const SaveResult$Failed(SaveFailure.unavailable, code: 'admit');
    }
  }

  /// The write of item [index] after the shared rules, or null when they
  /// end it here: a `file` sent to the gallery that is neither an image nor
  /// a video fails `unsupportedFormat`.
  SaveWrite? _writeOf(int index, SaveDestination destination) {
    final item = _slots[index].item!;
    var kind = item.kind;
    if (kind == SaveItemKind.file && destination is SaveDestination$Gallery) {
      switch (_topType(item.mimeType)) {
        case 'image':
          kind = SaveItemKind.photo;
        case 'video':
          kind = SaveItemKind.video;
        default:
          _routed(index, 'unsupportedFormat');
          _end(index, const SaveResult.failed(SaveFailure.unsupportedFormat));
          return null;
      }
      _routed(index, 'gallery');
    }
    // A leased file belongs to its keeper: moving it would take it from
    // under the cache, so it is always copied.
    final move = item.move && !item.isLeased;
    if (item.move && !move) {
      _emit(MpxEventLevel.warning, SaveOp.moveRefused, () => {'index': index});
    }
    return SaveWrite(
      jobId: id,
      index: index,
      item: item,
      kind: kind,
      move: move,
      destination: destination,
    );
  }

  Future<void> _writeEach(
    SaveWriter$PerItem writer,
    List<SaveWrite> writes,
  ) async {
    for (final write in writes) {
      if (_cancellation.isCancelled) break;
      SaveResult result;
      try {
        result = await writer.write(
          write,
          onProgress: (written, total) {
            _bytes[write.index] = written;
            _copy(
              write.index,
              total == null || total <= 0 ? 0 : written / total,
            );
          },
          cancellation: _cancellation,
        );
      } on Object catch (error, stackTrace) {
        _error = (error, stackTrace);
        result = const SaveResult.failed(
          SaveFailure.unavailable,
          code: 'throw',
        );
      }
      _end(write.index, result);
    }
    _endRemaining(const SaveResult.cancelled());
  }

  Future<void> _writeBlock(
    SaveWriter$Block writer,
    List<SaveWrite> writes,
  ) async {
    if (writes.isEmpty) return;
    // A block cannot be stopped once begun: a cancel counts only before it.
    if (_cancellation.isCancelled) {
      _blockEnded(writes.length, 'cancelled', cancel: 'before');
      return _endRemaining(const SaveResult.cancelled());
    }
    List<SaveResult> results;
    try {
      results = await writer.writeBlock(
        writes,
        onProgress: (fraction) {
          for (final write in writes) {
            _slots[write.index].copied = fraction.clamp(0, 1);
          }
          _report('copy');
        },
      );
      if (results.length != writes.length) {
        throw StateError('${results.length} results for ${writes.length}');
      }
    } on Object catch (error, stackTrace) {
      _error = (error, stackTrace);
      results = List.filled(
        writes.length,
        const SaveResult.failed(SaveFailure.unavailable, code: 'throw'),
      );
    }
    // The block is atomic: one failure is every item's.
    final failure = results.whereType<SaveResult$Failed>().firstOrNull;
    _blockEnded(
      writes.length,
      failure != null
          ? 'failed'
          : results.every((r) => r is SaveResult$Cancelled)
          ? 'cancelled'
          : 'saved',
      // The cancel came while the block ran, which it could not stop.
      cancel: _cancellation.isCancelled ? 'during' : null,
    );
    for (var i = 0; i < writes.length; i++) {
      _end(writes[i].index, failure ?? results[i]);
    }
  }

  /// Ends item [index] with [result], reports it, and gives back its lease.
  /// A cancelled item's [stage] says whether it was still downloading.
  void _end(int index, SaveResult result, {String stage = 'copy'}) {
    if (_results[index] != null) return;
    _results[index] = result;
    final error = _takeError();
    final slot = _slots[index];
    final item = slot.item;
    switch (result) {
      case SaveResult$Saved(:final renamed):
        _emit(
          MpxEventLevel.debug,
          SaveOp.itemSaved,
          mediaKey: slot.mediaKey,
          () => {
            'index': index,
            'kind': slot.kind.name,
            'mime': _topType(slot.mimeType),
            'bytes': ?(_bytes[index] ?? item?.bytes?.length),
            'ms': _clock.elapsedMilliseconds,
            'renamed': renamed,
          },
        );
      case SaveResult$Cancelled():
        _emit(
          MpxEventLevel.debug,
          SaveOp.itemCancelled,
          mediaKey: slot.mediaKey,
          () => {'index': index, 'stage': stage},
        );
      case SaveResult$Failed(:final reason, :final code):
        _emit(
          MpxEventLevel.warning,
          SaveOp.itemFailed,
          mediaKey: slot.mediaKey,
          () => {
            'index': index,
            'reason': reason.name,
            if (code != null) 'code': MpxEvent.clip(code),
          },
          error: error,
        );
    }
    if (item?.lease case final lease?) {
      _releases.add(_release(index, lease, result));
    }
    // An ended item's share is done, however it ended.
    slot
      ..downloaded = 1
      ..copied = 1;
    _report('copy');
  }

  Future<void> _release(
    int index,
    ContentFileLease lease,
    SaveResult after,
  ) async {
    try {
      await lease.release();
      _emit(
        MpxEventLevel.trace,
        SaveOp.leaseReleased,
        mediaKey: _slots[index].mediaKey,
        () => {
          'index': index,
          'after': switch (after) {
            SaveResult$Saved() => 'saved',
            SaveResult$Cancelled() => 'cancelled',
            SaveResult$Failed() => 'failed',
          },
        },
      );
    } on Object catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'mpx_library',
          context: ErrorDescription('while releasing a saved item\'s lease'),
        ),
      );
    }
  }

  Future<void> _finish() async {
    await Future.wait(_releases);
    // An empty batch has no item to move it: it is done all the same.
    if (_progress.value < 1) _setProgress(1, 'copy');
    final results = [for (final result in _results) result!];
    _emit(
      MpxEventLevel.info,
      SaveOp.jobFinished,
      () => {
        'saved': results.whereType<SaveResult$Saved>().length,
        'cancelled': results.whereType<SaveResult$Cancelled>().length,
        'failed': results.whereType<SaveResult$Failed>().length,
        'ms': _clock.elapsedMilliseconds,
      },
    );
    _done.complete(results);
  }

  // --- saveContent: making each content local ---

  /// The transfers a `saveContent` job downloads through.
  TrackedTransfers? _transfers;

  /// The items whose download is under way for this job, each with whether
  /// this job started it (true) or joined another caller's (false).
  final Map<int, bool> _downloading = {};

  Future<void> _runContent(
    SaveDestination destination,
    SaveWriter writer,
    TrackedTransfers? transfers,
  ) async {
    if (!await _begin(destination, writer)) return _finish();
    if (transfers == null) {
      // A host that wires no transfer engine: no content can be reached,
      // not even one already local, since only the engine lends its file.
      _emit(
        MpxEventLevel.warning,
        SaveOp.trackedTransfersMissing,
        () => {'items': _slots.length},
      );
      _endRemaining(
        const SaveResult.failed(
          SaveFailure.unavailable,
          code: 'noTrackedTransfers',
        ),
      );
      return _finish();
    }
    // Admitted once, before any download: a refused access, or a platform
    // without an adapter, downloads nothing. No item is local yet, so the
    // writer is given none.
    if (!await _admitted(destination, writer, const [])) return _finish();
    _transfers = transfers;
    // Every download runs at once; the engine queues them as it sees fit.
    await Future.wait([
      for (var i = 0; i < _slots.length; i++) _arrive(i, transfers),
    ]);
    // Written once every item is local, so the batch stays one operation:
    // one change block.
    if (!_cancellation.isCancelled) await _write(destination, writer);
    _endRemaining(const SaveResult.cancelled());
    return _finish();
  }

  /// Makes item [index]'s content local and leases its file, or ends the
  /// item: download, await, lease; a missing lease downloads once more,
  /// then fails the item `unavailable`.
  Future<void> _arrive(int index, TrackedTransfers transfers) async {
    final slot = _slots[index];
    final request = slot.request!;
    if (await _lease(index, transfers) case final lease?) {
      slot.item = request.leased(lease);
      _emit(
        MpxEventLevel.debug,
        SaveOp.downloadShared,
        mediaKey: request.key,
        () => {'index': index, 'why': 'local'},
      );
      return;
    }
    slot.copyOnly = false;
    for (var attempt = 1; ; attempt++) {
      if (_cancellation.isCancelled) {
        return _end(index, const SaveResult.cancelled(), stage: 'download');
      }
      final watched = transfers.watch(request.key);
      // Another caller's download under way is joined and never cancelled.
      final own = !watched.value.isActive;
      _downloading[index] = own;
      _emit(
        MpxEventLevel.debug,
        own ? SaveOp.downloadStarted : SaveOp.downloadShared,
        mediaKey: request.key,
        () => own
            ? {'index': index, 'origin': TransferOrigin.user.name}
            : {'index': index, 'why': 'other'},
      );
      // Joining calls it too: a download an auto origin started becomes the
      // user's, so it resumes after a restart.
      transfers.download(request.key);
      final arrival = await _await(index, watched);
      _downloading.remove(index);
      switch (arrival) {
        case _Arrival.cancelled || _Arrival.stopped:
          return _end(index, const SaveResult.cancelled(), stage: 'download');
        case _Arrival.failed:
          return _end(
            index,
            const SaveResult.failed(SaveFailure.unavailable, code: 'download'),
          );
        case _Arrival.complete:
          slot.downloaded = 1;
          _report('download');
      }
      if (await _lease(index, transfers) case final lease?) {
        slot.item = request.leased(lease);
        return;
      }
      _emit(
        MpxEventLevel.warning,
        SaveOp.leaseMissing,
        mediaKey: request.key,
        () => {'index': index, 'attempt': attempt},
        error: _takeError(),
      );
      if (attempt == 2) {
        return _end(
          index,
          const SaveResult.failed(SaveFailure.unavailable, code: 'noLease'),
        );
      }
    }
  }

  /// The lease of item [index]'s file, or null when its content is not
  /// local; a throw counts as null, its error kept for the event it causes.
  Future<ContentFileLease?> _lease(
    int index,
    TrackedTransfers transfers,
  ) async {
    try {
      return await transfers.leaseFile(_slots[index].request!.key);
    } on Object catch (error, stackTrace) {
      _error = (error, stackTrace);
      return null;
    }
  }

  /// Follows [watched] until item [index]'s download ends or the job is
  /// cancelled, reporting how far it is.
  Future<_Arrival> _await(int index, ValueListenable<AssetTransfer> watched) {
    final arrived = Completer<_Arrival>();
    void check() {
      if (arrived.isCompleted) return;
      if (_cancellation.isCancelled) {
        return arrived.complete(_Arrival.cancelled);
      }
      switch (watched.value) {
        case AssetTransfer$Waiting():
          break;
        case AssetTransfer$Receiving(:final fraction):
          _slots[index].downloaded = fraction ?? 0;
          _report('download');
        case AssetTransfer$AwaitingUser():
          arrived.complete(_Arrival.stopped);
        case AssetTransfer$Failed():
          arrived.complete(_Arrival.failed);
        // No job has the key any more: the download completed. An upload
        // of it is no download to wait on; the lease tells whether the
        // content is local.
        case AssetTransfer$None() ||
            AssetTransfer$Sending() ||
            AssetTransfer$Sent():
          arrived.complete(_Arrival.complete);
      }
    }

    watched.addListener(check);
    _cancellation.onCancel(check);
    check();
    return arrived.future.whenComplete(() => watched.removeListener(check));
  }

  /// On cancel: stops the downloads this job started, leaves the others'.
  void _stopDownloads() {
    final transfers = _transfers;
    if (transfers == null || _downloading.isEmpty) return;
    final own = [
      for (final MapEntry(key: index, value: started) in _downloading.entries)
        if (started) _slots[index].request!.key,
    ];
    final shared = _downloading.length - own.length;
    own.forEach(transfers.cancel);
    _emit(
      MpxEventLevel.debug,
      SaveOp.downloadsCancelled,
      () => {'own': own.length, 'shared': shared},
    );
  }

  // --- Diagnostics ---

  /// The error a writer or the transfers threw, carried into the event it
  /// causes.
  (Object, StackTrace)? _error;

  (Object, StackTrace)? _takeError() {
    final error = _error;
    _error = null;
    return error;
  }

  int _count(SaveItemKind kind) => _slots.where((s) => s.kind == kind).length;

  void _routed(int index, String outcome) => _emit(
    MpxEventLevel.debug,
    SaveOp.routedByMime,
    () => {
      'index': index,
      'mime': _topType(_slots[index].mimeType),
      'outcome': outcome,
    },
  );

  void _blockEnded(int items, String result, {String? cancel}) => _emit(
    MpxEventLevel.debug,
    SaveOp.changeBlock,
    () => {'items': items, 'result': result, 'cancel': ?cancel},
  );

  void _emit(
    MpxEventLevel level,
    SaveOp op,
    Map<String, Object> Function() fields, {
    MediaKey? mediaKey,
    (Object, StackTrace)? error,
  }) => MpxDiagnostics.current.emit(
    level,
    op,
    jobId: id,
    mediaKey: mediaKey,
    fields: fields,
    error: error?.$1,
    stackTrace: error?.$2,
  );

  /// The top-level MIME type: `image`, `video`, or `other`.
  static String _topType(String mimeType) {
    final slash = mimeType.indexOf('/');
    final top = (slash < 0 ? mimeType : mimeType.substring(0, slash))
        .trim()
        .toLowerCase();
    return top == 'image' || top == 'video' ? top : 'other';
  }

  /// Ends every item without a result with [result].
  void _endRemaining(SaveResult result) {
    for (var i = 0; i < _results.length; i++) {
      _end(i, result);
    }
  }

  /// Item [index]'s copy is [fraction] done.
  void _copy(int index, double fraction) {
    _slots[index].copied = fraction.clamp(0, 1);
    _report('copy');
  }

  /// Reports the batch's progress, each item an even share. [stage] names
  /// what moved it.
  void _report(String stage) {
    var done = 0.0;
    for (final slot in _slots) {
      done += slot.done;
    }
    if (_slots.isNotEmpty) _setProgress(done / _slots.length, stage);
  }

  /// Moves the progress to [fraction]; it never goes back.
  void _setProgress(double fraction, String stage) {
    final next = fraction.clamp(0.0, 1.0);
    if (next <= _progress.value) return;
    _progress.value = next;
    _emit(
      MpxEventLevel.trace,
      SaveOp.progress,
      () => {'fraction': next, 'stage': stage},
    );
  }
}
