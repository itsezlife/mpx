import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/src/image/image_head.dart';
import 'package:mpx_core/src/image/image_paintable.dart';

/// When a fetched thumbnail is blurred: one whose longer edge is below
/// [blurBelow] pixels is too small to show sharp, and goes through
/// `MiniThumbnail` with [blur]; a larger one is shown as it is.
@immutable
final class ThumbnailBlurRule {
  /// Creates a rule.
  const ThumbnailBlurRule({required this.blurBelow, required this.blur});

  /// The longer edge, in pixels of the encoded thumbnail, below which it is
  /// blurred.
  final int blurBelow;

  /// How a thumbnail below [blurBelow] is blurred.
  final PreviewBlur blur;

  /// Below 101 px, with the Android preview blur.
  static const ThumbnailBlurRule $Android = ThumbnailBlurRule(
    blurBelow: 101,
    blur: PreviewBlur.$Android,
  );

  /// Below 201 px, with the iOS preview blur.
  static const ThumbnailBlurRule $IOS = ThumbnailBlurRule(
    blurBelow: 201,
    blur: PreviewBlur.$IOS,
  );

  /// Below 240 px, with the desktop preview blur.
  static const ThumbnailBlurRule $Desktop = ThumbnailBlurRule(
    blurBelow: 240,
    blur: PreviewBlur.$Desktop,
  );

  /// The rule of [platform]. On the web, the platform is the one the browser
  /// runs on.
  static ThumbnailBlurRule forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => $IOS,
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux => $Desktop,
        TargetPlatform.android || TargetPlatform.fuchsia => $Android,
      };

  /// Whether a thumbnail of [width] x [height] is blurred.
  bool blurs(int width, int height) => math.max(width, height) < blurBelow;

  @override
  bool operator ==(Object other) =>
      other is ThumbnailBlurRule &&
      other.blurBelow == blurBelow &&
      other.blur == blur;

  @override
  int get hashCode => Object.hash(blurBelow, blur);

  @override
  String toString() => 'ThumbnailBlurRule(below $blurBelow, $blur)';
}

/// Decodes images with the engine's codecs, at the size of the spec.
///
/// The image is decoded to fit inside the spec's pixels, keeping its aspect
/// ratio and never larger than it is encoded, and painted centred in the
/// surface's rectangle. An image smaller than its surface is scaled up at
/// paint, so a pack meant to look sharp is encoded at its largest surface's
/// pixels. What it reports:
///
/// | Request | Reports |
/// | --- | --- |
/// | a thumbnail | the first frame, as `AssetStage.placeholder`; blurred small when [thumbnailBlur] says so |
/// | content, first frame only | the first frame, as `AssetStage.firstFrame` |
/// | content, one frame | the frame, as `AssetStage.full` |
/// | content, several frames | a playing image, as `AssetStage.full`, in the animated tier |
///
/// ## Frames are decoded as they are shown
///
/// A playing image keeps the codec and decodes one frame ahead of the one it
/// shows, instead of decoding every frame up front. Up front would cost every
/// frame's pixels for as long as the entry lives: a 100 px animation of 90 frames
/// is 3.6 MB that way and about 80 KB this way, and a screenful of them would
/// not fit the animated budget. The price is a decode per shown frame, which
/// the engine does off the UI thread, for animated WebP and GIF. The codec keeps the encoded data to decode from, so
/// a playing image is counted as its two frames plus that data (about 110 KB
/// for such an animation).
///
/// There is no frame report before the full stage: the first frame and the
/// playing image exist at the same moment.
///
/// ## SVG it is handed
///
/// Data it cannot decode whose first bytes are an SVG document (a host that
/// could not tell an SVG from a raster image, an `image/*` URL with no type)
/// fails with `DecodeFailure.unsupported`, so a vector decoder the host
/// registered as the still kind's fallback draws it. Other undecodable data
/// is an ordinary, permanent failure.
///
/// ## Not covered
///
/// Vector animations and video codecs are other media forms with adapters of
/// their own. Content in a file is read with `ImmutableBuffer.fromFilePath`,
/// which the web does not support: there a file is a permanent failure that
/// says so, and a fetcher for the web hands bytes.
final class ImageCodecDecoder implements Decoder {
  /// Creates a decoder. It keeps no state between requests.
  const ImageCodecDecoder({this.thumbnailBlur});

  /// When a thumbnail is blurred; null for the rule of the platform the app
  /// runs on (`ThumbnailBlurRule.forPlatform`).
  final ThumbnailBlurRule? thumbnailBlur;

  @override
  AssetTask decode(DecodeRequest request, AssetProgress progress) {
    final task = _DecodeTask(
      request,
      progress,
      thumbnailBlur ?? ThumbnailBlurRule.forPlatform(defaultTargetPlatform),
    );
    unawaited(task.run());
    return task;
  }
}

/// One decode, from encoded data to the reported stage.
final class _DecodeTask implements AssetTask {
  _DecodeTask(this._request, this._progress, this._thumbnailBlur);

  final DecodeRequest _request;
  final AssetProgress _progress;
  final ThumbnailBlurRule _thumbnailBlur;
  bool _cancelled = false;

  // The content's first bytes, read before it is released, for a decode that
  // fails: SVG is then told apart from damaged data.
  Future<Uint8List?>? _head;

  @override
  void cancel() => _cancelled = true;

  Future<void> run() async {
    final ui.Codec codec;
    final ui.FrameInfo first;
    final int encodedBytes;
    ui.Codec? decoding;
    try {
      final ui.ImmutableBuffer buffer;
      try {
        // A file is read by the engine, not through this isolate's heap.
        buffer = await switch (_request.content) {
          FetchedBytes(:final bytes) => ui.ImmutableBuffer.fromUint8List(bytes),
          FetchedFile() when kIsWeb => throw UnsupportedError(
            'ImageCodecDecoder reads no file on the web: the fetcher must '
            'hand bytes (FetchedContent.bytes).',
          ),
          FetchedFile(:final path) => ui.ImmutableBuffer.fromFilePath(path),
          FetchedRanged() => throw UnsupportedError(
            'ImageCodecDecoder reads whole files: the fetcher must not hand '
            'it a ranged resource.',
          ),
        };
      } finally {
        // The buffer holds the bytes now; the file may go once its head is
        // read, which a decode that fails looks at.
        final content = _request.content;
        final head = _head = ImageHead.read(content);
        unawaited(head.whenComplete(content.release));
      }
      encodedBytes = buffer.length;
      // Cancelled while the data was read: no codec, no decoded frame.
      if (_cancelled) {
        buffer.dispose();
        return;
      }
      if (_request.part == FetchPart.thumbnail &&
          await _blurredThumbnail(buffer)) {
        return;
      }
      // Takes the buffer over and disposes it.
      decoding = await ui.instantiateImageCodecWithSize(
        buffer,
        getTargetSize: _fitIn(_request.spec),
      );
      if (_cancelled) {
        decoding.dispose();
        return;
      }
      first = await decoding.getNextFrame();
      codec = decoding;
    } on Object catch (error, stackTrace) {
      decoding?.dispose();
      if (_cancelled) return;
      // SVG is for a vector decoder: the still kind's fallback, if any.
      final head = await _head;
      if (_cancelled) return;
      // Undecodable data stays undecodable, whatever the network does.
      _progress.fail(
        head != null && ImageHead.isSvg(head)
            ? DecodeFailure.unsupported(error)
            : error,
        stackTrace,
        AssetFailureKind.permanent,
      );
      return;
    }
    if (_cancelled) {
      first.image.dispose();
      codec.dispose();
      return;
    }
    // Outside the try: from here the codec and the frame belong to the
    // paintable handed over, and an error the progress throws is not a
    // decode failure. Caught above, it would dispose what the cache now
    // owns, and the cache would dispose it again.
    _report(codec, first, encodedBytes);
  }

  // A thumbnail too small to show sharp is decoded small and blurred,
  // reported, and the buffer disposed; says whether it was. A larger one is
  // left to the codec, the buffer untouched.
  Future<bool> _blurredThumbnail(ui.ImmutableBuffer buffer) async {
    final ui.Image image;
    final ui.ImageDescriptor descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
    } on Object {
      // Not an image: the codec says so the usual way.
      return false;
    }
    try {
      if (!_thumbnailBlur.blurs(descriptor.width, descriptor.height)) {
        return false;
      }
      try {
        image = await MiniThumbnail.decodeDescriptor(
          descriptor,
          _thumbnailBlur.blur,
        );
      } on Object catch (error, stackTrace) {
        if (!_cancelled) {
          _progress.fail(error, stackTrace, AssetFailureKind.permanent);
        }
        buffer.dispose();
        return true;
      }
    } finally {
      descriptor.dispose();
    }
    buffer.dispose();
    if (_cancelled) {
      image.dispose();
      return true;
    }
    _progress.advance(
      AssetStage.placeholder,
      StillImagePaintable(
        image,
        template: _request.spec.decodeMode == AssetDecodeMode.template,
      ),
      bytes: image.width * image.height * 4,
    );
    return true;
  }

  void _report(ui.Codec codec, ui.FrameInfo first, int encodedBytes) {
    final spec = _request.spec;
    final template = spec.decodeMode == AssetDecodeMode.template;
    final frameBytes = first.image.width * first.image.height * 4;
    final stage = switch ((_request.part, spec.variant)) {
      (FetchPart.thumbnail, _) => AssetStage.placeholder,
      (FetchPart.content, AssetVariant.firstFrame) => AssetStage.firstFrame,
      (FetchPart.content, AssetVariant.full) => AssetStage.full,
    };
    if (stage == AssetStage.full && codec.frameCount > 1) {
      _progress.advance(
        stage,
        PlayingImagePaintable(codec, first, template: template),
        // The frame shown, the one decoded ahead, the first frame kept as a
        // still (`firstFrame`) and the encoded data the codec keeps to decode
        // the next from. Whatever else the engine's codec holds (a frame kept
        // for blending) is not visible here.
        bytes: frameBytes * 3 + encodedBytes,
        tier: AssetTier.animated,
      );
      return;
    }
    codec.dispose();
    _progress.advance(
      stage,
      StillImagePaintable(first.image, template: template),
      bytes: frameBytes,
    );
  }

  /// The decode size of an image that fits inside [spec], keeping its aspect
  /// ratio. An image already smaller than the spec is decoded as it is:
  /// scaling up at decode costs pixels and adds no detail.
  static ui.TargetImageSizeCallback _fitIn(AssetSpec spec) => (width, height) {
    final scale = math.min(
      1,
      math.min(spec.pixelWidth / width, spec.pixelHeight / height),
    );
    if (scale >= 1) return const ui.TargetImageSize();
    return ui.TargetImageSize(
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  };
}
