import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/src/native/platform_still.dart';
import 'package:mpx_player/src/native/player_messages.g.dart';

/// A fallback `Decoder` for `MediaKind.video` that draws a clip's first frame
/// with the platform's decoders: the still of a video whose codec the
/// software decoder was built without (AV1, HEVC), which reports it as
/// `DecodeFailure.unsupported`.
///
/// Register it with `DecoderRegistry.registerFallback(MediaKind.video, ...)`.
/// It draws stills only: every content request ends at
/// `AssetStage.firstFrame`, which the pipeline makes final for the entry,
/// and the pipeline stores that frame as the content's derived preview, so
/// the platform draws each clip once. The central viewer page and the feed's
/// pager play such a clip through the platform player as before.
///
/// - **Reading.** A ranged resource is read through the bytes cache's native
///   reader and a file in place; content in memory is refused (no video is
///   loaded whole for a still). The content is given back once the platform
///   lets go of it.
/// - **Android** draws it with the platform's metadata retriever over a data
///   source on the reader (the frame at 0, nearest sync frame, scaled into
///   the spec); **iOS and macOS** with an asset image generator on an asset
///   read through the player's resource loader, with the track's transform
///   applied.
/// - **Elsewhere** nothing is wired: a platform without a backend leaves
///   the entry at its stand-ins.
final class PlatformStillDecoder implements Decoder {
  /// Creates the decoder over the platform's extractor.
  PlatformStillDecoder() : this.over(_NativeStillBackend());

  /// Creates the decoder over [backend], a stand-in for the platform in
  /// tests.
  PlatformStillDecoder.over(PlatformStillBackend backend) : _backend = backend;

  final PlatformStillBackend _backend;

  @override
  AssetTask decode(DecodeRequest request, AssetProgress progress) {
    final task = _StillDecode(request, progress);
    final source = switch ((request.part, request.content)) {
      (FetchPart.content, FetchedRanged(:final readerApi, :final key)) =>
        PlatformStillSource.ranged(readerApi: readerApi, key: key),
      (FetchPart.content, FetchedFile(:final path)) => PlatformStillSource.file(
        path,
      ),
      _ => null,
    };
    if (source == null) {
      request.content.release();
      progress.fail(
        UnsupportedError(
          'A platform still is drawn from a ranged resource or a file of '
          'content, not from ${request.part.name} '
          '${request.content.runtimeType}.',
        ),
        StackTrace.current,
        AssetFailureKind.permanent,
      );
      return task;
    }
    final spec = request.spec;
    unawaited(
      task.run(
        _backend.extract(
          PlatformStillRequest(
            source: source,
            maxWidth: math.max(1, spec.pixelWidth),
            maxHeight: math.max(1, spec.pixelHeight),
          ),
          task.cancellation,
        ),
      ),
    );
    return task;
  }
}

/// One still on its way from the platform to the cache.
final class _StillDecode implements AssetTask {
  _StillDecode(this._request, this._progress);

  final DecodeRequest _request;
  final AssetProgress _progress;
  final CancellationToken cancellation = CancellationToken();

  @override
  void cancel() => cancellation.cancel();

  Future<void> run(Future<PlatformStill?> extracting) async {
    final PlatformStill? still;
    try {
      still = await extracting;
    } on Object catch (error, stackTrace) {
      _request.content.release();
      _fail(error, stackTrace);
      return;
    }
    // The platform let go of the source: nothing reads it any more.
    _request.content.release();
    if (cancellation.isCancelled) return;
    if (still == null) {
      _fail(
        const DecodeFailure.unsupported('the platform drew no frame'),
        StackTrace.current,
      );
      return;
    }
    final ui.Image image;
    try {
      image = await _upload(still);
    } on Object catch (error, stackTrace) {
      _fail(error, stackTrace);
      return;
    }
    if (cancellation.isCancelled) {
      image.dispose();
      return;
    }
    _progress.advance(
      AssetStage.firstFrame,
      StillImagePaintable(image, template: false),
      bytes: still.width * still.height * 4,
    );
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (cancellation.isCancelled) return;
    _progress.fail(error, stackTrace, AssetFailureKind.permanent);
  }

  static Future<ui.Image> _upload(PlatformStill still) {
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      still.rgba,
      still.width,
      still.height,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }
}

/// The platform's extractor over the Pigeon channel.
final class _NativeStillBackend implements PlatformStillBackend {
  final PlayerStillHostApi _host = PlayerStillHostApi();
  int _nextId = 1;

  @override
  Future<PlatformStill?> extract(
    PlatformStillRequest request,
    CancellationToken cancellation,
  ) async {
    final id = _nextId++;
    cancellation.onCancel(() => unawaited(_cancel(id)));
    final source = request.source;
    final still = await _host.extractStill(
      NativeStillRequest(
        requestId: id,
        maxWidth: request.maxWidth,
        maxHeight: request.maxHeight,
        cacheKey: switch (source) {
          PlatformStillSource$Ranged(:final key) => key,
          PlatformStillSource$File() => null,
        },
        readerApi: switch (source) {
          PlatformStillSource$Ranged(:final readerApi) => readerApi,
          PlatformStillSource$File() => null,
        },
        path: switch (source) {
          PlatformStillSource$File(:final path) => path,
          PlatformStillSource$Ranged() => null,
        },
      ),
    );
    if (still == null) return null;
    return PlatformStill(
      width: still.width,
      height: still.height,
      rgba: still.rgba,
    );
  }

  Future<void> _cancel(int id) async {
    try {
      await _host.cancelStill(id);
    } on Object {
      // A platform without the extractor has nothing to wake.
      return;
    }
  }
}
