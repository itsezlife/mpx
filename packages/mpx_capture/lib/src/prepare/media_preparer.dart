import 'dart:async';
import 'dart:collection';

import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/prepare/preparation_codec.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';
import 'package:mpx_capture/src/prepare/prepared_files_io.dart'
    if (dart.library.js_interop) 'package:mpx_capture/src/prepare/prepared_files_web.dart'
    as files;
import 'package:mpx_capture/src/preset/compression_preset.dart';
import 'package:mpx_capture/src/transcode/transcoder.dart';
import 'package:mpx_core/mpx_core.dart';

/// One item being prepared: progress, the result and a way to stop it.
///
/// [progress] is a broadcast stream of fractions from 0 to 1 that closes
/// when [result] settles; [result] fails with a `CaptureException`:
/// `CaptureCancelled` after [cancel], `CaptureFailed` otherwise.
final class PreparationJob {
  PreparationJob._() {
    _result.future.ignore();
  }

  final StreamController<double> _progress = StreamController<double>.broadcast(
    sync: true,
  );
  final Completer<PreparedMedia> _result = Completer<PreparedMedia>();
  double _latest = 0;
  bool _cancelled = false;
  CaptureJob? _compression;
  Future<void> Function()? _onCancel;

  /// Progress, from 0 to 1.
  Stream<double> get progress => _progress.stream;

  /// The last progress reported.
  double get latest => _latest;

  /// The prepared item.
  Future<PreparedMedia> get result => _result.future;

  /// Whether [result] has settled.
  bool get isDone => _result.isCompleted;

  /// Stops the item and deletes what it wrote; [result] fails with
  /// `CaptureCancelled`. Idempotent; a no-op once settled.
  Future<void> cancel() async {
    if (isDone || _cancelled) return;
    _cancelled = true;
    try {
      await _compression?.cancel();
      await _onCancel?.call();
    } finally {
      _fail(const CaptureCancelled());
    }
  }

  void _report(double fraction) {
    if (isDone || fraction <= _latest) return;
    _latest = fraction.clamp(0, 1);
    _progress.add(_latest);
  }

  void _complete(PreparedMedia media) {
    if (isDone) return;
    _report(1);
    _result.complete(media);
    unawaited(_progress.close());
  }

  void _fail(CaptureException error, [StackTrace? stackTrace]) {
    if (isDone) return;
    _result.completeError(error, stackTrace);
    unawaited(_progress.close());
  }
}

/// Prepares picked items for upload with one call each, by a
/// [PreparationPolicy]: stills scaled and encoded, videos compressed or
/// passed through, thumbnails and facts read.
///
/// Items run [PreparationPolicy.concurrency] at a time (two for every
/// built-in policy); later ones queue in call order. The work runs off the
/// UI isolate, in the platform codecs. Written files land in
/// [outputDirectory]; the host deletes them once uploaded.
final class MediaPreparer {
  /// Creates a preparer over [codec] and [transcoder] that writes into
  /// [outputDirectory] (which must exist).
  MediaPreparer({
    required this.codec,
    required this.transcoder,
    required this.outputDirectory,
  });

  /// Reads stills and draws posters.
  final PreparationCodec codec;

  /// Probes and compresses videos.
  final Transcoder transcoder;

  /// Where written files land.
  final String outputDirectory;

  final Queue<_Pending> _queue = Queue();
  int _running = 0;
  int _written = 0;

  /// Starts preparing [input] as [intent] says, by [policy].
  PreparationJob prepare(
    PreparationInput input,
    PreparationIntent intent,
    PreparationPolicy policy,
  ) {
    final job = PreparationJob._();
    final pending = _Pending(input, intent, policy, job);
    job._onCancel = () async => _queue.remove(pending);
    _queue.add(pending);
    _pump();
    return job;
  }

  void _pump() {
    while (_queue.isNotEmpty && _running < _queue.first.policy.concurrency) {
      final next = _queue.removeFirst();
      _running++;
      unawaited(
        _run(next).whenComplete(() {
          _running--;
          _pump();
        }),
      );
    }
  }

  Future<void> _run(_Pending item) async {
    final job = item.job;
    if (job.isDone) return;
    final written = <String>[];
    try {
      final media = switch (item.intent) {
        PreparationIntent$Photo(:final highQuality) => await _photo(
          item,
          highQuality,
          written,
        ),
        PreparationIntent$Video(:final preset) => await _video(
          item,
          preset,
          written,
        ),
        PreparationIntent$File() => await _file(item),
      };
      if (job._cancelled) {
        _delete(written);
        return;
      }
      job._complete(media);
    } on CaptureException catch (error, stackTrace) {
      _delete(written);
      job._fail(error, stackTrace);
    } on Object catch (error, stackTrace) {
      _delete(written);
      job._fail(CaptureFailed('$error'), stackTrace);
    }
  }

  // --- Photo ---

  Future<PreparedMedia> _photo(
    _Pending item,
    bool highQuality,
    List<String> written,
  ) async {
    final path = item.input.path;
    final source = await codec.probeStill(path);
    item.job._report(0.1);
    final thumbnail = await _stillThumbnail(item, path);
    final plan = item.policy.planStill(source, highQuality: highQuality);
    switch (plan) {
      case StillPlan$Keep():
        return PreparedMedia(
          kind: PreparedKind.photo,
          path: path,
          isOriginal: true,
          byteSize: source.byteSize,
          mimeType: source.mimeType ?? item.input.mimeType,
          dimensions: source.dimensions,
          thumbnail: thumbnail?.bytes,
          thumbnailDimensions: thumbnail?.dimensions,
          animated: source.animated,
        );
      case StillPlan$Encode():
        final output = _nextOutput('jpg');
        written.add(output);
        var current = plan;
        var encoded = await _encode(path, current, output);
        for (
          var again = item.policy.retryStill(
            current,
            resultBytes: encoded.byteSize,
          );
          again != null && !item.job._cancelled;
          again = item.policy.retryStill(current, resultBytes: encoded.byteSize)
        ) {
          current = again;
          encoded = await _encode(path, current, output);
        }
        return PreparedMedia(
          kind: PreparedKind.photo,
          path: output,
          isOriginal: false,
          byteSize: encoded.byteSize,
          mimeType: 'image/jpeg',
          dimensions: encoded.dimensions,
          thumbnail: thumbnail?.bytes,
          thumbnailDimensions: thumbnail?.dimensions,
          bytes: encoded.bytes,
        );
    }
  }

  Future<EncodedStill> _encode(
    String path,
    StillPlan$Encode plan,
    String output,
  ) => codec.encodeStill(
    path,
    maxSide: plan.size.width > plan.size.height
        ? plan.size.width
        : plan.size.height,
    quality: plan.quality,
    progressive: plan.progressive,
    outputPath: output,
  );

  // A thumbnail is a nicety: an item whose thumbnail fails still goes.
  Future<EncodedStill?> _stillThumbnail(_Pending item, String path) async {
    final spec = item.policy.thumbnail;
    try {
      return await codec.encodeStill(
        path,
        maxSide: spec.side,
        quality: spec.quality,
      );
    } on CaptureException {
      return null;
    }
  }

  Future<EncodedStill?> _poster(_Pending item, String path) async {
    try {
      return await codec.videoThumbnail(path, item.policy.thumbnail);
    } on CaptureException {
      return null;
    }
  }

  // --- Video ---

  Future<PreparedMedia> _video(
    _Pending item,
    CompressionPreset? preset,
    List<String> written,
  ) async {
    final path = item.input.path;
    final source = await transcoder.probe(path);
    final poster = await _poster(item, path);
    item.job._report(0.05);
    if (preset == null) {
      return PreparedMedia(
        kind: PreparedKind.video,
        path: path,
        isOriginal: true,
        byteSize: item.input.byteSize ?? await files.lengthOf(path),
        mimeType: item.input.mimeType ?? 'video/mp4',
        dimensions: source.dimensions,
        duration: source.duration,
        thumbnail: poster?.bytes,
        thumbnailDimensions: poster?.dimensions,
        hasAudio: source.hasAudio,
        animated: !source.hasAudio,
      );
    }
    final output = _nextOutput('mp4');
    written.add(output);
    final compression = transcoder.compress(
      TranscodeRequest(sourcePath: path, outputPath: output, preset: preset),
    );
    item.job._compression = compression;
    if (item.job._cancelled) await compression.cancel();
    final subscription = compression.progress.listen(
      (progress) => item.job._report(0.05 + progress.fraction * 0.94),
    );
    try {
      final result = await compression.output;
      return PreparedMedia(
        kind: PreparedKind.video,
        path: result.path,
        isOriginal: false,
        byteSize: result.size,
        mimeType: 'video/mp4',
        dimensions: result.dimensions,
        duration: result.duration,
        thumbnail: poster?.bytes,
        thumbnailDimensions: poster?.dimensions,
        hasAudio: source.hasAudio,
        animated: !source.hasAudio,
      );
    } finally {
      await subscription.cancel();
    }
  }

  // --- File ---

  Future<PreparedMedia> _file(_Pending item) async {
    final path = item.input.path;
    final byteSize = item.input.byteSize ?? await files.lengthOf(path);
    StillSource? still;
    try {
      still = await codec.probeStill(path);
    } on CaptureException {
      still = null;
    }
    if (still != null) {
      final thumbnail = await _stillThumbnail(item, path);
      return PreparedMedia(
        kind: PreparedKind.file,
        path: path,
        isOriginal: true,
        byteSize: still.byteSize,
        mimeType: item.input.mimeType ?? still.mimeType,
        dimensions: still.dimensions,
        thumbnail: thumbnail?.bytes,
        thumbnailDimensions: thumbnail?.dimensions,
        animated: still.animated,
      );
    }
    SourceVideo? video;
    try {
      video = await transcoder.probe(path);
    } on CaptureException {
      video = null;
    }
    final poster = video == null ? null : await _poster(item, path);
    return PreparedMedia(
      kind: PreparedKind.file,
      path: path,
      isOriginal: true,
      byteSize: byteSize,
      mimeType: item.input.mimeType,
      dimensions: video?.dimensions,
      duration: video?.duration,
      thumbnail: poster?.bytes,
      thumbnailDimensions: poster?.dimensions,
      hasAudio: video?.hasAudio ?? false,
    );
  }

  // --- Files ---

  String _nextOutput(String extension) =>
      '$outputDirectory/prepared-${DateTime.now().microsecondsSinceEpoch}-'
      '${_written++}.$extension';

  static void _delete(List<String> paths) {
    paths.forEach(files.delete);
  }
}

final class _Pending {
  _Pending(this.input, this.intent, this.policy, this.job);

  final PreparationInput input;
  final PreparationIntent intent;
  final PreparationPolicy policy;
  final PreparationJob job;
}
