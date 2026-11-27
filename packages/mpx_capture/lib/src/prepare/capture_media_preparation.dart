import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/prepare/failure_code.dart';
import 'package:mpx_capture/src/prepare/media_preparer.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';
import 'package:mpx_core/mpx_core.dart';

/// `mpx_core`'s [MediaPreparation] over a [MediaPreparer] and one
/// [PreparationPolicy].
///
/// The limits of the policy hold for every caller of one preparer, a publish
/// job included: items run [PreparationPolicy.concurrency] at a time and
/// videos [PreparationPolicy.videoConcurrency]. A thumbnail the preparer
/// makes is written as a file beside the outputs, so a journal can name it
/// (`PreparedMedia.thumbnailPath`); the web has no files and keeps it in
/// memory. Meets `MediaPreparationContract`.
final class CaptureMediaPreparation implements MediaPreparation {
  /// Prepares through [preparer] by [policy].
  const CaptureMediaPreparation({required this.preparer, required this.policy});

  /// The preparer that does the work.
  final MediaPreparer preparer;

  /// The limits and rules the items are prepared by.
  final PreparationPolicy policy;

  @override
  PreparationHandle prepare(PreparationInput input, PreparationIntent intent) =>
      _CaptureHandle(
        preparer.prepare(input, intent, policy, thumbnailFile: true),
      );
}

final class _CaptureHandle implements PreparationHandle {
  _CaptureHandle(this._job) {
    _job.progress.listen((fraction) => _progress.value = fraction);
    unawaited(
      _job.result.then<void>(
        (media) {
          _progress.value = 1;
          _result.complete(media);
        },
        onError: (Object error, StackTrace stackTrace) =>
            _result.completeError(_translate(error), stackTrace),
      ),
    );
    _result.future.ignore();
  }

  final PreparationJob _job;
  final ValueNotifier<double> _progress = ValueNotifier(0);
  final Completer<PreparedMedia> _result = Completer<PreparedMedia>();

  @override
  ValueListenable<double> get progress => _progress;

  @override
  Future<PreparedMedia> get result => _result.future;

  @override
  Future<void> cancel() => _job.cancel();

  static PreparationException _translate(Object error) => switch (error) {
    CaptureCancelled() => const PreparationCancelled(),
    final CaptureException error => PreparationFailed(
      captureFailureCode(error),
      cause: error,
    ),
    _ => PreparationFailed('failed', cause: error),
  };
}
