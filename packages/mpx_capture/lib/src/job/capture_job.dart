import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// Where a running capture or compression stands.
///
/// Reported while the output file grows and once more at completion. An
/// uploader that starts on the growing file reads [bytesWritten]; at
/// completion [finalSize] is set, and [headerRewritten] says whether bytes
/// already read from the head of the file changed (an MP4 writer patches its
/// box sizes, or moves the index to the front, when it finishes) so the head
/// has to be sent again.
@immutable
final class CaptureProgress {
  /// Creates a progress report.
  const CaptureProgress({
    required this.bytesWritten,
    required this.position,
    required this.fraction,
    this.finalSize,
    this.headerRewritten = false,
  });

  /// Bytes in the output file so far.
  final int bytesWritten;

  /// Media time written so far: the encode position of a compression, the
  /// recorded time of a recording.
  final Duration position;

  /// [position] over the whole: the source's duration for a compression, the
  /// longest allowed recording for a recording. From 0 to 1.
  final double fraction;

  /// The size of the finished file; null until completion.
  final int? finalSize;

  /// Set at completion when the head of the file changed after it was first
  /// written.
  final bool headerRewritten;

  /// Whether this is the completion report.
  bool get isFinal => finalSize != null;

  @override
  bool operator ==(Object other) =>
      other is CaptureProgress &&
      other.bytesWritten == bytesWritten &&
      other.position == position &&
      other.fraction == fraction &&
      other.finalSize == finalSize &&
      other.headerRewritten == headerRewritten;

  @override
  int get hashCode =>
      Object.hash(bytesWritten, position, fraction, finalSize, headerRewritten);

  @override
  String toString() =>
      'CaptureProgress($bytesWritten B, $position, '
      '${(fraction * 100).toStringAsFixed(1)}%'
      '${isFinal ? ', final $finalSize B, header rewritten: '
                '$headerRewritten' : ''})';
}

/// The finished file of a capture or compression.
@immutable
final class CaptureOutput {
  /// Describes a finished output file.
  const CaptureOutput({
    required this.path,
    required this.size,
    required this.duration,
    required this.dimensions,
    required this.headerRewritten,
    this.reencoded = true,
  });

  /// Absolute path of the MP4 file.
  final String path;

  /// Its size in bytes.
  final int size;

  /// Its playing time.
  final Duration duration;

  /// Its frame size as displayed.
  final MediaDimensions dimensions;

  /// Whether the head of the file changed after it was first written (see
  /// [CaptureProgress.headerRewritten]).
  final bool headerRewritten;

  /// False when a compression passed the source through (remuxed it)
  /// instead of encoding it again.
  final bool reencoded;

  @override
  bool operator ==(Object other) =>
      other is CaptureOutput &&
      other.path == path &&
      other.size == size &&
      other.duration == duration &&
      other.dimensions == dimensions &&
      other.headerRewritten == headerRewritten &&
      other.reencoded == reencoded;

  @override
  int get hashCode =>
      Object.hash(path, size, duration, dimensions, headerRewritten, reencoded);

  @override
  String toString() =>
      'CaptureOutput($path, $size B, $duration, $dimensions, '
      'header rewritten: $headerRewritten, reencoded: $reencoded)';
}

/// Why a capture or compression did not produce a file.
sealed class CaptureException implements Exception {
  const CaptureException(this.message);

  /// What happened, for logs.
  final String message;
}

/// The job was cancelled; its output file is gone.
final class CaptureCancelled extends CaptureException {
  /// Creates the cancellation error.
  const CaptureCancelled() : super('cancelled');

  @override
  String toString() => 'CaptureCancelled';
}

/// The camera or the microphone is not allowed.
final class CapturePermissionDenied extends CaptureException {
  /// Creates the error for a denied permission.
  const CapturePermissionDenied(super.message);

  @override
  String toString() => 'CapturePermissionDenied: $message';
}

/// The platform could not read the source, or could not encode or write the
/// output; the output file is gone.
final class CaptureFailed extends CaptureException {
  /// Creates the error with the platform's [message].
  const CaptureFailed(super.message);

  @override
  String toString() => 'CaptureFailed: $message';
}

/// One running compression or recording: its progress, its output and a way
/// to stop it.
///
/// [progress] is a broadcast stream; [latest] holds the last report for a
/// listener that comes late. [output] completes with the finished file, or
/// with a [CaptureException]: [CaptureCancelled] after [cancel], otherwise
/// [CaptureFailed] or [CapturePermissionDenied]. The progress stream closes
/// when [output] settles.
final class CaptureJob {
  /// Creates a job that runs [onCancel] once, on the first [cancel] before it
  /// settles. Platform code and fakes drive it through [report], [complete]
  /// and [fail].
  CaptureJob({required Future<void> Function() onCancel})
    : _onCancel = onCancel {
    // The caller may never listen to [output] (a recording it lets run out);
    // an unhandled failure must not reach the zone.
    _output.future.ignore();
  }

  final Future<void> Function() _onCancel;
  final StreamController<CaptureProgress> _progress =
      StreamController<CaptureProgress>.broadcast(sync: true);
  final Completer<CaptureOutput> _output = Completer<CaptureOutput>();
  CaptureProgress? _latest;
  bool _cancelRequested = false;

  /// Progress reports, in order; closes when [output] settles.
  Stream<CaptureProgress> get progress => _progress.stream;

  /// The last progress report, or null before the first.
  CaptureProgress? get latest => _latest;

  /// The finished file, or a [CaptureException].
  Future<CaptureOutput> get output => _output.future;

  /// Whether [output] has settled.
  bool get isDone => _output.isCompleted;

  /// Stops the job and deletes its output; [output] fails with
  /// [CaptureCancelled]. Idempotent, and a no-op once [output] settled.
  Future<void> cancel() async {
    if (isDone || _cancelRequested) return;
    _cancelRequested = true;
    try {
      await _onCancel();
    } finally {
      fail(const CaptureCancelled());
    }
  }

  // --- Driven by the platform side or a fake ---

  /// Publishes [progress] unless the job settled.
  @internal
  void report(CaptureProgress progress) {
    if (isDone) return;
    _latest = progress;
    _progress.add(progress);
  }

  /// Settles the job with [output], after a final progress report built from
  /// it at [fraction] (a recording stopped early ends below 1). Ignored once
  /// settled.
  @internal
  void complete(CaptureOutput output, {double fraction = 1}) {
    if (isDone) return;
    report(
      CaptureProgress(
        bytesWritten: output.size,
        position: output.duration,
        fraction: fraction,
        finalSize: output.size,
        headerRewritten: output.headerRewritten,
      ),
    );
    _output.complete(output);
    unawaited(_progress.close());
  }

  /// Settles the job with [error]. Ignored once settled.
  @internal
  void fail(CaptureException error, [StackTrace? stackTrace]) {
    if (isDone) return;
    _output.completeError(error, stackTrace);
    unawaited(_progress.close());
  }
}
