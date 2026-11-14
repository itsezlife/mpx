import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/lab/corpus.dart';
import 'package:mpx_example/lab/stress_feed.dart';
import 'package:mpx_video_decoder/mpx_video_decoder.dart';

/// What a run showed: the stress items that reached a picture and the video
/// frames decoded, per corpus kind. The guard next to the hitch numbers: a
/// run that draws less is cheaper, and its hitches mean nothing until its
/// coverage matches the tape's recording.
abstract final class LabCoverage {
  static bool _active = false;
  static final Set<MediaKey> _shown = {};
  static final Map<CorpusKind, int> _frames = {};
  static final Map<String, CorpusKind> _kindOfEntry = {};
  static (AssetCacheScope, StressItems)? _watched;

  /// The stress feed [items] drawn through [scope] is watched from now on.
  static void watch(AssetCacheScope scope, StressItems items) {
    _watched = (scope, items);
    for (var i = 0; i < items.count; i++) {
      _kindOfEntry[items.keyAt(i).encoded] = items.sourceAt(i).kind;
    }
  }

  /// Starts counting, from nothing.
  static void start() {
    _shown.clear();
    _frames.clear();
    if (!_active) {
      _active = true;
      SchedulerBinding.instance.addPostFrameCallback(_check);
    }
  }

  /// Stops counting and returns the `coverage` line.
  static String stop() {
    _check(Duration.zero, again: false);
    _active = false;
    final watched = _watched;
    final byKind = <CorpusKind, (int, int)>{};
    if (watched != null) {
      final items = watched.$2;
      for (var i = 0; i < items.count; i++) {
        final kind = items.sourceAt(i).kind;
        final (shown, all) = byKind[kind] ?? (0, 0);
        byKind[kind] = (
          shown + (_shown.contains(items.keyAt(i)) ? 1 : 0),
          all + 1,
        );
      }
    }
    final shown = byKind.values.fold(0, (sum, v) => sum + v.$1);
    final all = byKind.values.fold(0, (sum, v) => sum + v.$2);
    final frames = _frames.values.fold(0, (sum, v) => sum + v);
    return 'coverage content=$shown/$all '
        '${[for (final MapEntry(:key, :value) in byKind.entries) 'content.${key.name}=${value.$1}/${value.$2}'].join(' ')} '
        'videoFrames=$frames '
        '${[for (final MapEntry(:key, :value) in _frames.entries) 'videoFrames.${key.name}=$value'].join(' ')}';
  }

  static void _check(Duration _, {bool again = true}) {
    if (!_active) return;
    if (_watched case (final scope, final items)?) {
      for (var i = 0; i < items.count; i++) {
        final key = items.keyAt(i);
        if (!_shown.contains(key) && scope.pictureSizeOf(key) != null) {
          _shown.add(key);
        }
      }
    }
    if (again) SchedulerBinding.instance.addPostFrameCallback(_check);
  }

  /// [engine], counting every frame it decodes against the corpus kind of
  /// the clip's file (named by its cache key).
  static VideoTextureEngine count(VideoTextureEngine engine) =>
      _CountingEngine(engine);

  static void _decoded(String? entry) {
    if (!_active || entry == null) return;
    final kind = _kindOfEntry[entry];
    if (kind == null) return;
    _frames.update(kind, (n) => n + 1, ifAbsent: () => 1);
  }
}

final class _CountingEngine implements VideoTextureEngine {
  _CountingEngine(this._inner);

  final VideoTextureEngine _inner;
  final Map<int, String> _entryOf = {};

  @override
  Future<VideoClipOpenResult> open(
    VideoSource source, {
    required int width,
    required int height,
  }) async {
    final result = await _inner.open(source, width: width, height: height);
    if (result case VideoClipOpened(:final clip)) {
      _entryOf[clip.id] = switch (source) {
        VideoFileSource(:final path) => path.split('/').last,
        VideoRangedSource(:final key) => key,
        VideoBytesSource() => '',
      };
    }
    return result;
  }

  @override
  Future<VideoFrameResult> nextFrame(
    VideoClip clip, {
    required Uint8List destination,
  }) async {
    final result = await _inner.nextFrame(clip, destination: destination);
    if (result.status == VideoFrameStatus.frame) {
      LabCoverage._decoded(_entryOf[clip.id]);
    }
    return result;
  }

  @override
  Future<bool> rewind(VideoClip clip) => _inner.rewind(clip);

  @override
  Future<bool> seek(VideoClip clip, Duration position) =>
      _inner.seek(clip, position);

  @override
  Future<List<TextureFrameOutcome>> writeTextures(
    FrameTextureEntryPoints entryPoints,
    FrameTextureFormat format,
    List<VideoTextureJob> jobs,
  ) => _inner.writeTextures(entryPoints, format, jobs);

  @override
  Future<void> close(VideoClip clip) {
    _entryOf.remove(clip.id);
    return _inner.close(clip);
  }

  @override
  Future<void> dispose() => _inner.dispose();
}
