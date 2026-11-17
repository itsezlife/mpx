import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// The shape of the blur kernel of one [PreviewBlurPass].
enum PreviewBlurKernel {
  /// A stack blur: a triangular kernel.
  stack,

  /// A box blur: a flat kernel.
  box,
}

/// One pass of a [PreviewBlur]: the picture is scaled so its longer edge is
/// at most [maxEdge] and at least [minEdge] (each when set), aspect kept,
/// then blurred at [radius] pixels of the scaled picture.
@immutable
final class PreviewBlurPass {
  /// Creates a pass.
  const PreviewBlurPass({
    required this.radius,
    this.maxEdge,
    this.minEdge,
    this.kernel = PreviewBlurKernel.stack,
  }) : assert(radius >= 0, 'A blur radius is not negative.');

  /// The longest the longer edge may be: a larger picture is scaled down.
  final int? maxEdge;

  /// The shortest the longer edge may be: a smaller picture is scaled up.
  final int? minEdge;

  /// The blur radius, in pixels of the scaled picture.
  final int radius;

  /// The kernel the radius describes.
  final PreviewBlurKernel kernel;

  /// The Gaussian sigma of the same spread as the kernel of [radius]: a
  /// triangle of radius `r` has variance `r * (r + 2) / 6`, a box of width
  /// `2r + 1` has `r * (r + 1) / 3`.
  double get sigma => math.sqrt(switch (kernel) {
    PreviewBlurKernel.stack => radius * (radius + 2) / 6,
    PreviewBlurKernel.box => radius * (radius + 1) / 3,
  });

  /// The size a picture of [width] x [height] takes in this pass.
  (int, int) sizeOf(int width, int height) {
    final longer = math.max(width, height);
    var scale = 1.0;
    if (maxEdge case final max? when longer > max) scale = max / longer;
    if (minEdge case final min? when longer < min) scale = min / longer;
    return (
      math.max(1, (width * scale).round()),
      math.max(1, (height * scale).round()),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PreviewBlurPass &&
      other.maxEdge == maxEdge &&
      other.minEdge == minEdge &&
      other.radius == radius &&
      other.kernel == kernel;

  @override
  int get hashCode => Object.hash(maxEdge, minEdge, radius, kernel);

  @override
  String toString() =>
      'PreviewBlurPass(max: $maxEdge, min: $minEdge, r: $radius, '
      '${kernel.name})';
}

/// How a preview, or a thumbnail too small to show sharp, is blurred: once,
/// when it is decoded, in one or more [passes].
///
/// A setting of the pipeline chosen once per stack from the target platform,
/// not per surface: one decoded preview serves every surface of the scope.
/// A paint-time wash over it belongs to the surface's style.
@immutable
final class PreviewBlur {
  /// Creates a blur of [passes], run in order.
  const PreviewBlur(this.passes);

  /// The passes, in order.
  final List<PreviewBlurPass> passes;

  /// At most 40 px, stack blur radius 3.
  static const PreviewBlur $Android = PreviewBlur([
    PreviewBlurPass(maxEdge: 40, radius: 3),
  ]);

  /// At most 90 px with radius 7, then scaled up to at least 150 px with
  /// radius 3.
  static const PreviewBlur $IOS = PreviewBlur([
    PreviewBlurPass(maxEdge: 90, radius: 7),
    PreviewBlurPass(minEdge: 150, radius: 3),
  ]);

  /// At most 40 px, box blur radius 3.
  static const PreviewBlur $Desktop = PreviewBlur([
    PreviewBlurPass(maxEdge: 40, radius: 3, kernel: PreviewBlurKernel.box),
  ]);

  /// The blur of [platform]. On the web, the platform is the one the
  /// browser runs on.
  static PreviewBlur forPlatform(TargetPlatform platform) => switch (platform) {
    TargetPlatform.iOS => $IOS,
    TargetPlatform.macOS ||
    TargetPlatform.windows ||
    TargetPlatform.linux => $Desktop,
    TargetPlatform.android || TargetPlatform.fuchsia => $Android,
  };

  @override
  bool operator ==(Object other) =>
      other is PreviewBlur && listEquals(other.passes, passes);

  @override
  int get hashCode => Object.hashAll(passes);

  @override
  String toString() => 'PreviewBlur($passes)';
}

/// Turns the bytes of a small preview still into the picture a surface shows
/// under content that is still loading: small, and blurred once, here.
///
/// The picture is kept small (at most 40 pixels a side by default) and
/// blurred when it is decoded; the surface then stretches the bitmap over the
/// whole box with bilinear filtering. Painting it is one image draw per
/// frame, never a blur: the cost of the blur is paid once per picture, on a
/// bitmap of a few dozen pixels.
abstract final class MiniThumbnail {
  /// The longer side the default blur decodes to; a smaller still is kept as
  /// it is.
  static const int maxEdge = 40;

  /// The default blur's stack-blur radius (3).
  static const int stackBlurRadius = 3;

  /// The Gaussian sigma whose spread equals a stack blur of
  /// [stackBlurRadius].
  static final double sigma = math.sqrt(
    stackBlurRadius * (stackBlurRadius + 2) / 6,
  );

  /// Decodes [bytes], an encoded still (JPEG, PNG, WebP, or the first frame of
  /// a GIF), and runs the passes of [blur] over it, aspect kept. The caller
  /// owns the image.
  ///
  /// Fails when [bytes] are not an image the engine reads.
  static Future<ui.Image> decode(
    Uint8List bytes, [
    PreviewBlur blur = PreviewBlur.$Android,
  ]) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        return await decodeDescriptor(descriptor, blur);
      } finally {
        descriptor.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  /// [decode] from an image the caller has already read the header of (and
  /// still owns), for a decoder that reads its size before it chooses.
  @internal
  static Future<ui.Image> decodeDescriptor(
    ui.ImageDescriptor descriptor,
    PreviewBlur blur,
  ) async {
    // The first pass's downscale is the codec's, so a large still is never
    // decoded whole.
    final (width, height) = switch (blur.passes) {
      [final first, ...] when first.maxEdge != null => first.sizeOf(
        descriptor.width,
        descriptor.height,
      ),
      _ => (descriptor.width, descriptor.height),
    };
    final codec = await descriptor.instantiateCodec(
      targetWidth: width,
      targetHeight: height,
    );
    try {
      final frame = await codec.getNextFrame();
      var image = frame.image;
      for (final pass in blur.passes) {
        try {
          final (w, h) = pass.sizeOf(image.width, image.height);
          final next = await _blurred(image, pass, w, h);
          image.dispose();
          image = next;
        } on Object {
          image.dispose();
          rethrow;
        }
      }
      return image;
    } finally {
      codec.dispose();
    }
  }

  static Future<ui.Image> _blurred(
    ui.Image source,
    PreviewBlurPass pass,
    int width,
    int height,
  ) {
    final recorder = ui.PictureRecorder();
    final sigma = pass.sigma;
    // Clamped edges: the border keeps its colour instead of fading to clear.
    ui.Canvas(recorder).drawImageRect(
      source,
      ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()
        ..filterQuality = ui.FilterQuality.medium
        ..imageFilter = sigma <= 0
            ? null
            : ui.ImageFilter.blur(
                sigmaX: sigma,
                sigmaY: sigma,
                tileMode: ui.TileMode.clamp,
              ),
    );
    final picture = recorder.endRecording();
    return picture.toImage(width, height).whenComplete(picture.dispose);
  }
}
