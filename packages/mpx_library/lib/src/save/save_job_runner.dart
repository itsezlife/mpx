import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/save/media_saver.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_op.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// Runs a `MediaSaver.save` batch over a [SaveWriter]: the rules every
/// platform shares, in one place.
///
/// - One batch is one job with one id, one progress and a result per item.
/// - A cancel before the work begins cancels every item; between items it
///   cancels the rest; inside an item it is the writer's to honour. A block
///   writer's batch is cancelled only before its block begins.
/// - A failed admission (denied access, no adapter) fails every item.
/// - A `file` item sent to the gallery goes as a photo or a video by its MIME
///   type, or fails `unsupportedFormat` unwritten.
/// - A leased file is never moved.
/// - Every lease is released once its item ends, before the results
///   complete.
/// - Every step reports its `save` event through `MpxDiagnostics.current`.
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
    final job = _Job('save-${++_lastJob}', List.unmodifiable(items));
    unawaited(job._run(destination, writer));
    return job;
  }
}

final class _Job implements SaveJob {
  _Job(this.id, this._items) : _results = List.filled(_items.length, null);

  @override
  final String id;

  final List<SaveItem> _items;
  final List<SaveResult?> _results;
  final ValueNotifier<double> _progress = ValueNotifier(0);
  final Completer<List<SaveResult>> _done = Completer();
  final CancellationToken _cancellation = CancellationToken();
  final List<Future<void>> _releases = [];
  final Stopwatch _clock = Stopwatch();
  late final List<int?> _bytes = List.filled(_items.length, null);

  @override
  ValueListenable<double> get progress => _progress;

  @override
  Future<List<SaveResult>> get results => _done.future;

  @override
  void cancel() {
    if (_done.isCompleted) return;
    _cancellation.cancel();
  }

  Future<void> _run(SaveDestination destination, SaveWriter writer) async {
    _clock.start();
    _emit(
      MpxEventLevel.info,
      SaveOp.jobStarted,
      () => {
        'items': _items.length,
        'destination': destination.name,
        'named': destination.isNamed,
        'platform': MpxEvent.clip(writer.platform),
        'photos': _count(SaveItemKind.photo),
        'videos': _count(SaveItemKind.video),
        'animations': _count(SaveItemKind.animation),
        'files': _count(SaveItemKind.file),
      },
    );
    // Lets a cancel made right after `save` land before anything starts.
    await Future<void>.value();
    if (_cancellation.isCancelled) {
      _endRemaining(const SaveResult.cancelled());
      return _finish();
    }
    final refused = await _admit(writer, destination);
    if (refused != null) {
      _endRemaining(refused);
      return _finish();
    }
    final writes = <SaveWrite>[];
    for (var i = 0; i < _items.length; i++) {
      if (_writeOf(i, destination) case final write?) writes.add(write);
    }
    switch (writer) {
      case SaveWriter$PerItem():
        await _writeEach(writer, writes);
      case SaveWriter$Block():
        await _writeBlock(writer, writes);
    }
    return _finish();
  }

  Future<SaveResult$Failed?> _admit(
    SaveWriter writer,
    SaveDestination destination,
  ) async {
    try {
      return await writer.admit(id, destination, _items);
    } on Object catch (error, stackTrace) {
      _error = (error, stackTrace);
      return const SaveResult$Failed(SaveFailure.unavailable, code: 'admit');
    }
  }

  /// The write of item [index] after the shared rules, or null when they
  /// end it here: a `file` sent to the gallery that is neither an image nor
  /// a video fails `unsupportedFormat`.
  SaveWrite? _writeOf(int index, SaveDestination destination) {
    final item = _items[index];
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
            _advance(
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
      _advance(write.index, 1);
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
      return _endRemaining(const SaveResult.cancelled());
    }
    List<SaveResult> results;
    try {
      results = await writer.writeBlock(writes, onProgress: _advanceBlock);
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
    for (var i = 0; i < writes.length; i++) {
      _end(writes[i].index, failure ?? results[i]);
    }
  }

  /// Ends item [index] with [result], reports it, and gives back its lease.
  void _end(int index, SaveResult result) {
    if (_results[index] != null) return;
    _results[index] = result;
    final error = _error;
    _error = null;
    final item = _items[index];
    switch (result) {
      case SaveResult$Saved(:final renamed):
        _emit(
          MpxEventLevel.debug,
          SaveOp.itemSaved,
          () => {
            'index': index,
            'kind': item.kind.name,
            'mime': _topType(item.mimeType),
            'bytes': ?(_bytes[index] ?? item.bytes?.length),
            'ms': _clock.elapsedMilliseconds,
            'renamed': renamed,
          },
        );
      case SaveResult$Cancelled():
        _emit(
          MpxEventLevel.debug,
          SaveOp.itemCancelled,
          () => {'index': index, 'stage': 'copy'},
        );
      case SaveResult$Failed(:final reason, :final code):
        _emit(
          MpxEventLevel.warning,
          SaveOp.itemFailed,
          () => {
            'index': index,
            'reason': reason.name,
            if (code != null) 'code': MpxEvent.clip(code),
          },
          error: error,
        );
    }
    if (item.lease case final lease?) {
      _releases.add(_release(index, lease, result));
    }
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
    _advanceBlock(1);
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

  // --- Diagnostics ---

  /// The error a writer threw, carried into the failure event it causes.
  (Object, StackTrace)? _error;

  int _count(SaveItemKind kind) => _items.where((i) => i.kind == kind).length;

  void _routed(int index, String outcome) => _emit(
    MpxEventLevel.debug,
    SaveOp.routedByMime,
    () => {
      'index': index,
      'mime': _topType(_items[index].mimeType),
      'outcome': outcome,
    },
  );

  void _emit(
    MpxEventLevel level,
    SaveOp op,
    Map<String, Object> Function() fields, {
    (Object, StackTrace)? error,
  }) => MpxDiagnostics.current.emit(
    level,
    op,
    jobId: id,
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

  /// Item [index] (each item an even share of the batch) is [fraction] done.
  void _advance(int index, double fraction) =>
      _advanceBlock((index + fraction.clamp(0, 1)) / _items.length);

  /// The batch is [fraction] done; progress never goes back.
  void _advanceBlock(double fraction) {
    final next = fraction.clamp(0.0, 1.0);
    if (next <= _progress.value) return;
    _progress.value = next;
    _emit(
      MpxEventLevel.trace,
      SaveOp.progress,
      () => {'fraction': next, 'stage': 'copy'},
    );
  }
}
