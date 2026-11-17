import 'dart:typed_data';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_video_decoder/src/binding/binding.dart';
import 'package:mpx_video_decoder/src/engine/texture_calls.dart';
import 'package:mpx_video_decoder/src/engine/video_decode_core.dart';
import 'package:mpx_video_decoder/src/engine/video_engine.dart';
import 'package:mpx_video_decoder/src/engine/video_texture_engine.dart';

/// A [VideoEngine] that runs a [VideoBinding] on the calling isolate; its
/// futures complete at once.
///
/// For tests (over `FakeVideoBinding`), hosts that want no isolate, and as
/// the proof that the worker isolate adds transport only: both run the same
/// `VideoDecodeCore`.
final class InProcessVideoEngine implements VideoTextureEngine {
  /// Creates an engine over [binding], which it owns and closes.
  InProcessVideoEngine(VideoBinding binding) : _core = VideoDecodeCore(binding);

  final VideoDecodeCore _core;
  bool _disposed = false;

  void _requireOpen() {
    if (_disposed) throw VideoEngineClosed();
  }

  @override
  Future<VideoClipOpenResult> open(
    VideoSource source, {
    required int width,
    required int height,
  }) async {
    _requireOpen();
    return _core.open(source, width: width, height: height);
  }

  @override
  Future<VideoFrameResult> nextFrame(
    VideoClip clip, {
    required Uint8List destination,
  }) async {
    _requireOpen();
    return _core.nextFrame(clip.id, destination);
  }

  @override
  Future<bool> rewind(VideoClip clip) async {
    _requireOpen();
    return _core.rewind(clip.id);
  }

  @override
  Future<bool> seek(VideoClip clip, Duration position) async {
    _requireOpen();
    return _core.seek(clip.id, position);
  }

  @override
  Future<List<TextureFrameOutcome>> writeTextures(
    FrameTextureEntryPoints entryPoints,
    FrameTextureFormat format,
    List<VideoTextureJob> jobs,
  ) async {
    _requireOpen();
    final calls = TextureCalls.of(entryPoints);
    return [
      for (final job in jobs)
        VideoTextureWork.write(
          calls,
          format,
          job.texture,
          job.clip.width,
          job.clip.height,
          job.pixels,
        ),
    ];
  }

  @override
  Future<void> close(VideoClip clip) async => _core.close(clip.id);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _core.dispose();
  }
}
