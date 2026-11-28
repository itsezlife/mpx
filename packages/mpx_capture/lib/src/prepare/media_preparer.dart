import 'dart:async';
import 'dart:collection';

import 'package:mpx_capture/src/diagnostics/preparation_op.dart';
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
  void Function(double fraction)? _onProgress;
  void Function(PreparedMedia? media, CaptureException? error)? _onSettled;

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
    _onProgress?.call(_latest);
  }

  void _complete(PreparedMedia media) {
    if (isDone) return;
    _report(1);
    _result.complete(media);
    _onSettled?.call(media, null);
    unawaited(_progress.close());
  }

  void _fail(CaptureException error, [StackTrace? stackTrace]) {
    if (isDone) return;
    _result.completeError(error, stackTrace);
    _onSettled?.call(null, error);
    unawaited(_progress.close());
  }
}

/// Prepares picked items for upload with one call each, by a
/// [PreparationPolicy]: stills scaled and encoded, videos compressed or
/// passed through, thumbnails and facts read.
///
/// Items run [PreparationPolicy.concurrency] at a time (two for every
/// built-in policy) and videos [PreparationPolicy.videoConcurrency] at a
/// time (one), a video holding a slot of each; later ones queue in call
/// order, a video waiting for its slot letting the items behind it by. The work runs off the
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
  int _runningVideos = 0;
  int _count = 0;
  int _written = 0;

  /// Starts preparing [input] as [intent] says, by [policy].
  ///
  /// With [thumbnailFile] a thumbnail the preparer made is also written as
  /// a file in [outputDirectory] and named by `PreparedMedia.thumbnailPath`
  /// (the host deletes it with the output; cancel and failure delete it).
  PreparationJob prepare(
    PreparationInput input,
    PreparationIntent intent,
    PreparationPolicy policy, {
    bool thumbnailFile = false,
  }) {
    final job = PreparationJob._();
    final pending = _Pending(
      input,
      intent,
      policy,
      job,
      number: _count++,
      thumbnailFile: thumbnailFile,
    );
    job._onCancel = () async => _queue.remove(pending);
    job._onProgress = (fraction) => _emit(
      MpxEventLevel.trace,
      PreparationOp.progress,
      pending,
      {'fraction': fraction},
    );
    job._onSettled = (media, error) => _settled(pending, media, error);
    _emit(MpxEventLevel.debug, PreparationOp.queued, pending, {
      if (pending.isVideo)
        'waitingForVideoSlot': _runningVideos >= policy.videoConcurrency,
    });
    _queue.add(pending);
    _pump();
    return job;
  }

  void _pump() {
    for (final next in _queue.toList()) {
      if (_running >= next.policy.concurrency) continue;
      if (next.isVideo && _runningVideos >= next.policy.videoConcurrency) {
        continue;
      }
      _queue.remove(next);
      _running++;
      if (next.isVideo) _runningVideos++;
      unawaited(
        _run(next).whenComplete(() {
          _running--;
          if (next.isVideo) _runningVideos--;
          _pump();
        }),
      );
    }
  }

  void _emit(
    MpxEventLevel level,
    PreparationOp op,
    _Pending item, [
    Map<String, Object> fields = const {},
    Object? error,
    StackTrace? stackTrace,
  ]) => MpxDiagnostics.current.emit(
    level,
    op,
    fields: () => {'n': item.number, 'kind': item.kind, ...fields},
    error: error,
    stackTrace: stackTrace,
  );

  void _settled(_Pending item, PreparedMedia? media, CaptureException? error) {
    final ms = item.age.inMilliseconds;
    switch ((media, error)) {
      case (final media?, _):
        _emit(MpxEventLevel.info, PreparationOp.finished, item, {
          'bytes': media.byteSize,
          'ms': ms,
          'original': media.isOriginal,
        });
      case (_, CaptureCancelled()):
        _emit(MpxEventLevel.info, PreparationOp.cancelled, item, {'ms': ms});
      default:
        // The error itself stays out: its message may name the input's
        // path. The code says what went wrong; the host gets the error.
        _emit(MpxEventLevel.error, PreparationOp.failed, item, {
          'code': error?.failureCode ?? 'failed',
          'ms': ms,
        });
    }
  }

  Future<void> _run(_Pending item) async {
    final job = item.job;
    if (job.isDone) return;
    final written = <String>[];
    _emit(MpxEventLevel.debug, PreparationOp.started, item, {
      'waitedMs': item.age.inMilliseconds,
    });
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
      job._complete(_withThumbnailFile(item, media, written));
    } on CaptureException catch (error, stackTrace) {
      _delete(written);
      job._fail(error, stackTrace);
    } on Object catch (error, stackTrace) {
      _delete(written);
      // By its type only: the text of an error from elsewhere (a file
      // system error) names the path it failed on.
      job._fail(CaptureFailed('${error.runtimeType}'), stackTrace);
    }
  }

  // The thumbnail as a file beside the outputs, when the item asked for it.
  PreparedMedia _withThumbnailFile(
    _Pending item,
    PreparedMedia media,
    List<String> written,
  ) {
    final bytes = media.thumbnail;
    if (!item.thumbnailFile || bytes == null) return media;
    final path = _nextOutput('jpg');
    if (!files.$write(path, bytes)) return media;
    written.add(path);
    return PreparedMedia(
      kind: media.kind,
      path: media.path,
      isOriginal: media.isOriginal,
      byteSize: media.byteSize,
      mimeType: media.mimeType,
      dimensions: media.dimensions,
      duration: media.duration,
      thumbnailPath: path,
      thumbnail: bytes,
      thumbnailDimensions: media.thumbnailDimensions,
      hasAudio: media.hasAudio,
      animated: media.animated,
      bytes: media.bytes,
    );
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
        byteSize: item.input.byteSize ?? await files.$lengthOf(path),
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
    final byteSize = item.input.byteSize ?? await files.$lengthOf(path);
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
    paths.forEach(files.$delete);
  }
}

final class _Pending {
  _Pending(
    this.input,
    this.intent,
    this.policy,
    this.job, {
    required this.number,
    required this.thumbnailFile,
  });

  final int number;
  final bool thumbnailFile;
  final Stopwatch _age = Stopwatch()..start();

  Duration get age => _age.elapsed;
  bool get isVideo => intent is PreparationIntent$Video;
  String get kind => switch (intent) {
    PreparationIntent$Photo() => 'photo',
    PreparationIntent$Video() => 'video',
    PreparationIntent$File() => 'file',
  };

  final PreparationInput input;
  final PreparationIntent intent;
  final PreparationPolicy policy;
  final PreparationJob job;
}
