import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/prepare/preparation_codec.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:web/web.dart' as web;

/// The web's [PreparationCodec]: paths are object URLs of the picked blobs
/// (`URL.createObjectURL`), and every output is in memory
/// ([EncodedStill.bytes]; `PreparedMedia.bytes`).
///
/// `createImageBitmap` decodes (with the stored orientation) and resizes
/// off the main thread, and `OffscreenCanvas.convertToBlob` encodes off
/// it, so the main thread only draws one bitmap; a worker of its own would
/// make the host ship a second compiled script for no saving. A browser
/// without `OffscreenCanvas` encodes through a canvas element. Posters seek
/// a muted video to `min(duration, 1 s)`. A GIF counts as animated (the
/// browser tells no frame count).
final class WebPreparationCodec implements PreparationCodec {
  /// Creates the codec.
  const WebPreparationCodec();

  @override
  Future<StillSource> probeStill(String path) async {
    final blob = await _blob(path);
    if (!blob.type.startsWith('image/')) {
      throw CaptureFailed('not a still: $path');
    }
    final bitmap = await _bitmap(blob, path);
    try {
      return StillSource(
        dimensions: MediaDimensions(bitmap.width, bitmap.height),
        byteSize: blob.size,
        mimeType: blob.type,
        animated: blob.type == 'image/gif',
      );
    } finally {
      bitmap.close();
    }
  }

  @override
  Future<EncodedStill> encodeStill(
    String path, {
    required int maxSide,
    required int quality,
    bool progressive = false,
    String? outputPath,
  }) async {
    final blob = await _blob(path);
    final probe = await _bitmap(blob, path);
    final size = _fit(probe.width, probe.height, maxSide);
    probe.close();
    final options = web.ImageBitmapOptions(
      resizeWidth: size.width,
      resizeHeight: size.height,
      resizeQuality: 'high',
    );
    final web.ImageBitmap bitmap;
    try {
      bitmap = await web.window.createImageBitmap(blob, options).toDart;
    } on Object catch (error) {
      throw CaptureFailed('cannot decode $path: $error');
    }
    return _jpeg(bitmap, quality);
  }

  @override
  Future<EncodedStill> videoThumbnail(String path, ThumbnailSpec spec) async {
    final video = web.HTMLVideoElement()
      ..muted = true
      ..preload = 'auto'
      ..crossOrigin = 'anonymous'
      ..src = path;
    try {
      await _once(video, 'loadedmetadata', path);
      final duration = video.duration.isFinite ? video.duration : 0.0;
      video.currentTime = math.min(duration, 1);
      await _once(video, 'seeked', path);
      if (video.videoWidth == 0 || video.videoHeight == 0) {
        throw CaptureFailed('not a video: $path');
      }
      final size = _fit(video.videoWidth, video.videoHeight, spec.side);
      final bitmap = await web.window
          .createImageBitmap(
            video,
            web.ImageBitmapOptions(
              resizeWidth: size.width,
              resizeHeight: size.height,
              resizeQuality: 'high',
            ),
          )
          .toDart;
      return _jpeg(bitmap, spec.quality);
    } finally {
      video
        ..removeAttribute('src')
        ..load();
    }
  }

  // --- Helpers ---

  static Future<web.Blob> _blob(String path) async {
    try {
      final response = await web.window.fetch(path.toJS).toDart;
      if (!response.ok) throw CaptureFailed('cannot read $path');
      return await response.blob().toDart;
    } on CaptureException {
      rethrow;
    } on Object catch (error) {
      throw CaptureFailed('cannot read $path: $error');
    }
  }

  static Future<web.ImageBitmap> _bitmap(web.Blob blob, String path) async {
    try {
      return await web.window.createImageBitmap(blob).toDart;
    } on Object catch (error) {
      throw CaptureFailed('not a still: $path ($error)');
    }
  }

  static Future<EncodedStill> _jpeg(web.ImageBitmap bitmap, int quality) async {
    final width = bitmap.width;
    final height = bitmap.height;
    final q = quality.clamp(1, 100) / 100;
    web.Blob? out;
    try {
      if (_hasOffscreenCanvas) {
        final canvas = web.OffscreenCanvas(width, height);
        final context =
            canvas.getContext('2d')! as web.OffscreenCanvasRenderingContext2D;
        // JPEG has no alpha: transparent pixels go over white.
        context
          ..fillStyle = 'white'.toJS
          ..fillRect(0, 0, width, height)
          ..drawImage(bitmap, 0, 0);
        out = await canvas
            .convertToBlob(
              web.ImageEncodeOptions(type: 'image/jpeg', quality: q),
            )
            .toDart;
      } else {
        final canvas = web.HTMLCanvasElement()
          ..width = width
          ..height = height;
        final context =
            canvas.getContext('2d')! as web.CanvasRenderingContext2D;
        context
          ..fillStyle = 'white'.toJS
          ..fillRect(0, 0, width, height)
          ..drawImage(bitmap, 0, 0);
        final done = Completer<web.Blob?>();
        // A closure, not a tear-off: toJS needs a JS-typed signature.
        // ignore: unnecessary_lambdas
        void onBlob(web.Blob? blob) => done.complete(blob);
        canvas.toBlob(onBlob.toJS, 'image/jpeg', q.toJS);
        out = await done.future;
      }
    } finally {
      bitmap.close();
    }
    if (out == null) throw const CaptureFailed('cannot encode a JPEG');
    final bytes = (await out.arrayBuffer().toDart).toDart.asUint8List();
    return EncodedStill(
      dimensions: MediaDimensions(width, height),
      byteSize: bytes.length,
      bytes: Uint8List.fromList(bytes),
    );
  }

  static bool get _hasOffscreenCanvas => web.window.has('OffscreenCanvas');

  static Future<void> _once(
    web.HTMLVideoElement video,
    String name,
    String path,
  ) {
    final done = Completer<void>();
    void onEvent(web.Event _) {
      if (!done.isCompleted) done.complete();
    }

    void onError(web.Event _) {
      if (!done.isCompleted)
        done.completeError(CaptureFailed('not a video: $path'));
    }

    video
      ..addEventListener(name, onEvent.toJS)
      ..addEventListener('error', onError.toJS);
    return done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw CaptureFailed('video did not load: $path'),
    );
  }

  static MediaDimensions _fit(int width, int height, int side) {
    final longSide = math.max(width, height);
    if (longSide <= side) return MediaDimensions(width, height);
    final scale = side / longSide;
    return MediaDimensions(
      math.max(1, (width * scale).round()),
      math.max(1, (height * scale).round()),
    );
  }
}
