import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/prepare/preparation_codec.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';
import 'package:mpx_capture/src/preset/compression_preset.dart';
import 'package:mpx_capture/src/transcode/transcoder.dart';
import 'package:mpx_core/mpx_core.dart';

/// One item to prepare: a local file and, when known, its MIME type.
@immutable
final class PreparationInput {
  /// Describes the file at [path].
  const PreparationInput(this.path, {this.mimeType});

  /// Absolute path of the file.
  final String path;

  /// Its MIME type, when the host knows it.
  final String? mimeType;

  @override
  String toString() => 'PreparationInput($path)';
}

/// How the host wants an item sent.
@immutable
sealed class PreparationIntent {
  const PreparationIntent();

  /// As a photo: scaled and encoded by the policy, at standard or
  /// [highQuality].
  const factory PreparationIntent.photo({bool highQuality}) =
      PreparationIntent$Photo;

  /// As a video, compressed at [preset]; without one it goes as it is.
  const factory PreparationIntent.video({CompressionPreset? preset}) =
      PreparationIntent$Video;

  /// As a file: the original bytes, with a thumbnail when it is media.
  const factory PreparationIntent.file() = PreparationIntent$File;
}

/// See [PreparationIntent.photo].
final class PreparationIntent$Photo extends PreparationIntent {
  /// Creates the intent.
  const PreparationIntent$Photo({this.highQuality = false});

  /// Whether the policy's high-quality size and quality apply.
  final bool highQuality;
}

/// See [PreparationIntent.video].
final class PreparationIntent$Video extends PreparationIntent {
  /// Creates the intent.
  const PreparationIntent$Video({this.preset});

  /// The compression step, or null to send the video as it is.
  final CompressionPreset? preset;
}

/// See [PreparationIntent.file].
final class PreparationIntent$File extends PreparationIntent {
  /// Creates the intent.
  const PreparationIntent$File();
}

/// What a prepared item is sent as.
enum PreparedKind {
  /// A photo.
  photo,

  /// A video.
  video,

  /// A file.
  file,
}

/// An item ready to upload.
///
/// [path] is a file the preparer wrote into its output directory, or the
/// input itself when [isOriginal] (the host must not delete that one). A
/// host that wants the item to play before upload moves a written file into
/// the bytes store with `CaptureCache`.
@immutable
final class PreparedMedia {
  /// Describes a prepared item.
  const PreparedMedia({
    required this.kind,
    required this.path,
    required this.isOriginal,
    required this.byteSize,
    this.mimeType,
    this.dimensions,
    this.duration,
    this.thumbnail,
    this.thumbnailDimensions,
    this.hasAudio = false,
    this.animated = false,
  });

  /// What it is sent as.
  final PreparedKind kind;

  /// The file to upload.
  final String path;

  /// Whether [path] is the input, unchanged.
  final bool isOriginal;

  /// The size of [path] in bytes.
  final int byteSize;

  /// The MIME type of [path], when known.
  final String? mimeType;

  /// The pixel size as displayed, when it is a picture or a video.
  final MediaDimensions? dimensions;

  /// The playing time of a video.
  final Duration? duration;

  /// A JPEG thumbnail (the poster of a video), when one could be made.
  final Uint8List? thumbnail;

  /// The pixel size of [thumbnail].
  final MediaDimensions? thumbnailDimensions;

  /// Whether a video has a sound track.
  final bool hasAudio;

  /// Whether it moves without sound: an animated still, or a silent video
  /// that loops.
  final bool animated;

  @override
  String toString() =>
      'PreparedMedia(${kind.name}, $path, $byteSize B, '
      '${dimensions ?? '?'}${isOriginal ? ', original' : ''})';
}

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
        byteSize: await File(path).length(),
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
    final file = File(path);
    final byteSize = file.existsSync() ? await file.length() : 0;
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
    for (final path in paths) {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

final class _Pending {
  _Pending(this.input, this.intent, this.policy, this.job);

  final PreparationInput input;
  final PreparationIntent intent;
  final PreparationPolicy policy;
  final PreparationJob job;
}
