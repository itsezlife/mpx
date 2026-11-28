import 'dart:async';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/save/media_saver.dart';
import 'package:mpx_library/src/save/save_access.dart';
import 'package:mpx_library/src/save/save_admission.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_job_runner.dart';
import 'package:mpx_library/src/save/save_request.dart';
import 'package:mpx_library/src/save/save_result.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// One batch a [FakeMediaSaver] was given.
final class FakeSaveBatch {
  /// The batch of job [jobId].
  const FakeSaveBatch({
    required this.jobId,
    required this.items,
    required this.destination,
  });

  /// The job's id.
  final String jobId;

  /// The items, as given.
  final List<SaveItem> items;

  /// Where they went.
  final SaveDestination destination;
}

/// One `saveContent` batch a [FakeMediaSaver] was given.
final class FakeContentBatch {
  /// The batch of job [jobId].
  const FakeContentBatch({
    required this.jobId,
    required this.requests,
    required this.destination,
  });

  /// The job's id.
  final String jobId;

  /// The requests, as given.
  final List<SaveRequest> requests;

  /// Where they went.
  final SaveDestination destination;
}

/// One item a [FakeMediaSaver] wrote, after the shared rules: [kind] is
/// the kind it was filed as (a `file` sent to the gallery routed by its MIME
/// type), [move] whether the item was moved rather than copied.
final class FakeSaveWrite {
  /// The write of [item], the [index]th of job [jobId].
  const FakeSaveWrite({
    required this.jobId,
    required this.index,
    required this.item,
    required this.kind,
    required this.move,
    required this.destination,
  });

  /// The job's id.
  final String jobId;

  /// The item's place in its batch.
  final int index;

  /// The item as given.
  final SaveItem item;

  /// What it was filed as.
  final SaveItemKind kind;

  /// Whether it was moved.
  final bool move;

  /// Where it went.
  final SaveDestination destination;
}

/// A [MediaSaver] that writes nothing, for tests and for hosts without a
/// device: it records batches, ends each item with a scripted result,
/// reports progress in steps and honours cancel. It runs on the same shared
/// rules as the platform adapters (routing by MIME type, no move of a
/// leased file, lease release, diagnostics), so it meets
/// `MediaSaverContract`.
final class FakeMediaSaver implements MediaSaver {
  /// Creates a saver that ends each item with [resultFor] (by default
  /// saved, with a `fake-<n>` ref).
  ///
  /// Each item reports [progressSteps] even steps of [stepBytes] bytes, each
  /// after [stepDelay], and checks for a cancel before every step: a cancel
  /// that lands inside an item ends it cancelled.
  ///
  /// With [changeBlock] the batch is written as one atomic block, as Photos
  /// does on Apple: [progressSteps] steps for the whole block, a cancel
  /// before it cancels every item, a cancel during it has no effect, and
  /// [blockFailure] fails every item.
  ///
  /// [transfers] is what `saveContent` downloads and leases through (a
  /// `FakeTrackedTransfers` in tests); without it every `saveContent` item
  /// fails `SaveFailure.unavailable`.
  FakeMediaSaver({
    SaveResult Function(FakeSaveWrite write)? resultFor,
    this.transfers,
    this.changeBlock = false,
    this.progressSteps = 4,
    this.stepBytes = 1024,
    this.stepDelay = Duration.zero,
  }) : assert(progressSteps > 0, 'an item reports at least one step'),
       resultFor = resultFor ?? _saved;

  static int _lastRef = 0;

  static SaveResult _saved(FakeSaveWrite write) =>
      SaveResult.saved('fake-${++_lastRef}');

  /// The tracked transfers `saveContent` makes content local through.
  final TrackedTransfers? transfers;

  /// How each item ends once written.
  SaveResult Function(FakeSaveWrite write) resultFor;

  /// Whether a batch is written as one change block.
  final bool changeBlock;

  /// The failure of the next blocks, under [changeBlock]; null writes them.
  SaveFailure? blockFailure;

  /// How many progress steps an item (a block, under [changeBlock])
  /// reports.
  final int progressSteps;

  /// How many bytes each step reports written.
  final int stepBytes;

  /// How long each step takes.
  final Duration stepDelay;

  /// The access saving has, the same for every destination. A batch asks
  /// for it while [SaveAccess.notDetermined] (the user answers
  /// [grantOnRequest]); [SaveAccess.denied] or [SaveAccess.restricted] fail
  /// every item `SaveFailure.accessDenied`, [SaveAccess.unavailable] (a
  /// build without the save code) `SaveFailure.unavailable`.
  SaveAccess saveAccess = SaveAccess.granted;

  /// What the user answers the system prompt.
  SaveAccess grantOnRequest = SaveAccess.granted;

  /// How many times the system prompt was shown.
  int accessRequests = 0;

  /// Every batch given to [save], oldest first.
  final List<FakeSaveBatch> batches = [];

  /// Every item written, oldest first; an item failed or cancelled before
  /// its write is not here.
  final List<FakeSaveWrite> writes = [];

  /// Every `saveContent` batch, oldest first, as given; its items, once
  /// local, are in [writes].
  final List<FakeContentBatch> contentBatches = [];

  SaveWriter get _writer =>
      changeBlock ? _FakeBlockWriter(this) : _FakeItemWriter(this);

  @override
  SaveJob save(List<SaveItem> items, SaveDestination destination) {
    final job = SaveJobRunner.run(
      items,
      destination,
      _writer,
      access: _admitAccess,
    );
    batches.add(
      FakeSaveBatch(
        jobId: job.id,
        items: List.unmodifiable(items),
        destination: destination,
      ),
    );
    return job;
  }

  @override
  Future<SaveAccess> access(SaveDestination destination) async => saveAccess;

  @override
  Future<SaveAccess> requestAccess(SaveDestination destination) async {
    if (saveAccess != SaveAccess.notDetermined) return saveAccess;
    return (await SaveAdmission.ask(_prompt)).access;
  }

  // The fake stands for Apple's gallery: add-only access, and the save
  // define as the build define it lacks.
  Future<SaveAccessAnswer> _answer() async => SaveAccessAnswer(
    saveAccess,
    scope: SaveAccessScope.addOnly,
    missing: saveAccess == SaveAccess.unavailable ? 'MPX_LIBRARY_SAVE' : null,
  );

  Future<SaveResult$Failed?> _admitAccess(
    String jobId,
    SaveDestination destination,
  ) => SaveAdmission.admit(
    jobId: jobId,
    destination: destination,
    read: _answer,
    request: _prompt,
  );

  Future<SaveAccessAnswer> _prompt() async {
    accessRequests++;
    saveAccess = grantOnRequest;
    return _answer();
  }

  @override
  SaveJob saveContent(List<SaveRequest> requests, SaveDestination destination) {
    final job = SaveJobRunner.runContent(
      requests,
      destination,
      _writer,
      transfers,
      access: _admitAccess,
    );
    contentBatches.add(
      FakeContentBatch(
        jobId: job.id,
        requests: List.unmodifiable(requests),
        destination: destination,
      ),
    );
    return job;
  }
}

// Shared by both writer shapes, which the sealed `SaveWriter` keeps apart.
FakeSaveWrite _record(FakeMediaSaver saver, SaveWrite write) {
  final written = FakeSaveWrite(
    jobId: write.jobId,
    index: write.index,
    item: write.item,
    kind: write.kind,
    move: write.move,
    destination: write.destination,
  );
  saver.writes.add(written);
  return written;
}

final class _FakeItemWriter extends SaveWriter$PerItem {
  _FakeItemWriter(this._saver);

  final FakeMediaSaver _saver;

  @override
  String get platform => 'fake';

  @override
  Future<SaveResult> write(
    SaveWrite write, {
    required FetchProgress onProgress,
    required CancellationToken cancellation,
  }) async {
    final written = _record(_saver, write);
    final steps = _saver.progressSteps;
    for (var step = 1; step <= steps; step++) {
      if (cancellation.isCancelled) return const SaveResult.cancelled();
      await Future<void>.delayed(_saver.stepDelay);
      onProgress(step * _saver.stepBytes, steps * _saver.stepBytes);
    }
    return _saver.resultFor(written);
  }
}

final class _FakeBlockWriter extends SaveWriter$Block {
  _FakeBlockWriter(this._saver);

  final FakeMediaSaver _saver;

  @override
  String get platform => 'fake';

  @override
  Future<List<SaveResult>> writeBlock(
    List<SaveWrite> writes, {
    required void Function(double fraction) onProgress,
  }) async {
    final written = [for (final write in writes) _record(_saver, write)];
    final steps = _saver.progressSteps;
    for (var step = 1; step <= steps; step++) {
      await Future<void>.delayed(_saver.stepDelay);
      onProgress(step / steps);
    }
    if (_saver.blockFailure case final failure?) {
      return [for (final _ in writes) SaveResult.failed(failure)];
    }
    return [for (final write in written) _saver.resultFor(write)];
  }
}
