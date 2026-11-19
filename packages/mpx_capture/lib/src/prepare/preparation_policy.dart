import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mpx_capture/src/preset/compression_preset.dart';
import 'package:mpx_core/mpx_core.dart';

const int _mebibyte = 1024 * 1024;

/// The long side and JPEG quality of a thumbnail (a video's poster, a
/// still's small copy) made during media preparation.
@immutable
final class ThumbnailSpec {
  /// Creates a spec: the thumbnail fits a square of [side] pixels and is
  /// encoded at JPEG [quality] (1 to 100).
  const ThumbnailSpec({required this.side, required this.quality});

  /// The bounding square, in pixels.
  final int side;

  /// The JPEG quality, 1 to 100.
  final int quality;

  @override
  bool operator ==(Object other) =>
      other is ThumbnailSpec && other.side == side && other.quality == quality;

  @override
  int get hashCode => Object.hash(side, quality);

  @override
  String toString() => 'ThumbnailSpec(${side}px at $quality)';
}

/// What a preparation policy reads from a still before deciding.
@immutable
final class StillSource {
  /// Describes a still.
  const StillSource({
    required this.dimensions,
    required this.byteSize,
    this.mimeType,
    this.animated = false,
  });

  /// The pixel size as displayed (after the stored orientation).
  final MediaDimensions dimensions;

  /// The file size in bytes.
  final int byteSize;

  /// The MIME type, when known.
  final String? mimeType;

  /// Whether it has more than one frame (a GIF, an animated WebP).
  final bool animated;

  /// Whether it is a JPEG.
  bool get isJpeg => mimeType == 'image/jpeg' || mimeType == 'image/jpg';

  @override
  bool operator ==(Object other) =>
      other is StillSource &&
      other.dimensions == dimensions &&
      other.byteSize == byteSize &&
      other.mimeType == mimeType &&
      other.animated == animated;

  @override
  int get hashCode => Object.hash(dimensions, byteSize, mimeType, animated);

  @override
  String toString() =>
      'StillSource($dimensions, $byteSize B, ${mimeType ?? '?'}'
      '${animated ? ', animated' : ''})';
}

/// What media preparation does with a still: send it as it is, or encode a
/// JPEG.
@immutable
sealed class StillPlan {
  const StillPlan();

  /// Send the original bytes.
  const factory StillPlan.keep() = StillPlan$Keep;

  /// Encode a JPEG of [size] at [quality], [progressive] or baseline.
  const factory StillPlan.encode({
    required MediaDimensions size,
    required int quality,
    bool progressive,
  }) = StillPlan$Encode;
}

/// A [StillPlan] that sends the original.
final class StillPlan$Keep extends StillPlan {
  /// Creates the plan.
  const StillPlan$Keep();

  @override
  bool operator ==(Object other) => other is StillPlan$Keep;

  @override
  int get hashCode => (StillPlan$Keep).hashCode;

  @override
  String toString() => 'StillPlan.keep()';
}

/// A [StillPlan] that encodes a JPEG.
final class StillPlan$Encode extends StillPlan {
  /// Creates the plan.
  const StillPlan$Encode({
    required this.size,
    required this.quality,
    this.progressive = false,
  });

  /// The output pixel size.
  final MediaDimensions size;

  /// The JPEG quality, 1 to 100.
  final int quality;

  /// Whether the JPEG is progressive.
  final bool progressive;

  @override
  bool operator ==(Object other) =>
      other is StillPlan$Encode &&
      other.size == size &&
      other.quality == quality &&
      other.progressive == progressive;

  @override
  int get hashCode => Object.hash(size, quality, progressive);

  @override
  String toString() =>
      'StillPlan.encode($size at $quality'
      '${progressive ? ', progressive' : ''})';
}

/// How a policy treats stills; one of three rules.
///
/// An animated still is always kept: re-encoding it as a JPEG would stop it.
@immutable
sealed class StillRule {
  const StillRule();

  /// Always encode a JPEG fitted to [side] ([highQualitySide] in high
  /// quality) at [quality] ([highQualityQuality]).
  const factory StillRule.alwaysEncode({
    required int side,
    required int highQualitySide,
    required int quality,
    required int highQualityQuality,
  }) = StillRule$AlwaysEncode;

  /// Encode a [progressive] JPEG at [quality], fitted to [side]
  /// ([highQualitySide]), except a JPEG that needs no downscale and holds at
  /// most [maxBitsPerPixel], which is kept.
  const factory StillRule.keepLightJpeg({
    required int side,
    required int highQualitySide,
    required int quality,
    required bool progressive,
    required int maxBitsPerPixel,
  }) = StillRule$KeepLightJpeg;

  /// Keep the original unless it is past [side], a heavy format over
  /// [heavyBytes], or a format outside [acceptedMimeTypes]; GIFs are never
  /// re-encoded. A heavy one encodes at [heavyQuality], others at
  /// [quality]; a result over [maxBytes] encodes again at [heavyQuality].
  const factory StillRule.reencodeWhenNeeded({
    required int side,
    required int quality,
    required int heavyQuality,
    required Set<String> heavyMimeTypes,
    required int heavyBytes,
    required Set<String> acceptedMimeTypes,
    required int maxBytes,
  }) = StillRule$ReencodeWhenNeeded;

  /// The plan for [source].
  StillPlan plan(StillSource source, {required bool highQuality});

  /// The plan to encode again after [plan] produced [resultBytes], or null
  /// when the result stands.
  StillPlan$Encode? retry(StillPlan$Encode plan, {required int resultBytes}) =>
      null;

  static MediaDimensions _fit(MediaDimensions size, int side) {
    final longSide = math.max(size.width, size.height);
    if (longSide <= side) return size;
    final scale = side / longSide;
    return MediaDimensions(
      math.max(1, (size.width * scale).round()),
      math.max(1, (size.height * scale).round()),
    );
  }

  static bool _needsDownscale(MediaDimensions size, int side) =>
      math.max(size.width, size.height) > side;
}

/// See [StillRule.alwaysEncode].
final class StillRule$AlwaysEncode extends StillRule {
  /// Creates the rule.
  const StillRule$AlwaysEncode({
    required this.side,
    required this.highQualitySide,
    required this.quality,
    required this.highQualityQuality,
  });

  /// The long side of a standard still.
  final int side;

  /// The long side of a high-quality still.
  final int highQualitySide;

  /// The JPEG quality of a standard still.
  final int quality;

  /// The JPEG quality of a high-quality still.
  final int highQualityQuality;

  @override
  StillPlan plan(StillSource source, {required bool highQuality}) {
    if (source.animated) return const StillPlan.keep();
    return StillPlan.encode(
      size: StillRule._fit(
        source.dimensions,
        highQuality ? highQualitySide : side,
      ),
      quality: highQuality ? highQualityQuality : quality,
    );
  }
}

/// See [StillRule.keepLightJpeg].
final class StillRule$KeepLightJpeg extends StillRule {
  /// Creates the rule.
  const StillRule$KeepLightJpeg({
    required this.side,
    required this.highQualitySide,
    required this.quality,
    required this.progressive,
    required this.maxBitsPerPixel,
  });

  /// The long side of a standard still.
  final int side;

  /// The long side of a high-quality still.
  final int highQualitySide;

  /// The JPEG quality at both sizes.
  final int quality;

  /// Whether the JPEG is progressive.
  final bool progressive;

  /// The heaviest original JPEG kept as it is, in bits per pixel.
  final int maxBitsPerPixel;

  @override
  StillPlan plan(StillSource source, {required bool highQuality}) {
    if (source.animated) return const StillPlan.keep();
    final limit = highQuality ? highQualitySide : side;
    final size = source.dimensions;
    final light =
        source.byteSize * 8 <= maxBitsPerPixel * size.width * size.height;
    if (source.isJpeg && light && !StillRule._needsDownscale(size, limit)) {
      return const StillPlan.keep();
    }
    return StillPlan.encode(
      size: StillRule._fit(size, limit),
      quality: quality,
      progressive: progressive,
    );
  }
}

/// See [StillRule.reencodeWhenNeeded].
final class StillRule$ReencodeWhenNeeded extends StillRule {
  /// Creates the rule.
  const StillRule$ReencodeWhenNeeded({
    required this.side,
    required this.quality,
    required this.heavyQuality,
    required this.heavyMimeTypes,
    required this.heavyBytes,
    required this.acceptedMimeTypes,
    required this.maxBytes,
  });

  /// The long side past which a still is re-encoded.
  final int side;

  /// The JPEG quality of a re-encode that is not of a heavy file.
  final int quality;

  /// The JPEG quality of a heavy file's re-encode and of the second pass.
  final int heavyQuality;

  /// The formats that count as heavy past [heavyBytes].
  final Set<String> heavyMimeTypes;

  /// The size past which a heavy format is re-encoded.
  final int heavyBytes;

  /// The formats sent as they are.
  final Set<String> acceptedMimeTypes;

  /// The largest result kept; a larger one is encoded again.
  final int maxBytes;

  @override
  StillPlan plan(StillSource source, {required bool highQuality}) {
    final mime = source.mimeType;
    if (source.animated || mime == 'image/gif') return const StillPlan.keep();
    final heavy = heavyMimeTypes.contains(mime) && source.byteSize > heavyBytes;
    final needed =
        StillRule._needsDownscale(source.dimensions, side) ||
        heavy ||
        !acceptedMimeTypes.contains(mime);
    if (!needed) return const StillPlan.keep();
    return StillPlan.encode(
      size: StillRule._fit(source.dimensions, side),
      quality: heavy ? heavyQuality : quality,
    );
  }

  @override
  StillPlan$Encode? retry(StillPlan$Encode plan, {required int resultBytes}) {
    if (resultBytes <= maxBytes || plan.quality <= heavyQuality) return null;
    return StillPlan$Encode(
      size: plan.size,
      quality: heavyQuality,
      progressive: plan.progressive,
    );
  }
}

/// How a policy offers video compression; one of three rules.
@immutable
sealed class VideoRule {
  const VideoRule();

  /// Offer the first steps of [ladder], as many as the source's long side
  /// earns: past [thresholds]`[i]` it earns `thresholds.length - i + 1`
  /// steps, else one. The default is the host's remembered step, else
  /// [defaultCap], never above [defaultCap] or the top offered step. A file
  /// of [uncompressedFrom] bytes or more is not compressed.
  const factory VideoRule.byLongSide({
    required List<CompressionPreset> ladder,
    required List<int> thresholds,
    required CompressionPreset defaultCap,
    required int uncompressedFrom,
  }) = VideoRule$ByLongSide;

  /// Offer [CompressionPreset.offeredFor] the source; the default is the
  /// host's remembered step, else [fallback], clamped to the top offered.
  const factory VideoRule.clampedToSource({
    required CompressionPreset fallback,
  }) = VideoRule$ClampedToSource;

  /// Offer nothing: videos go as they are.
  const factory VideoRule.none() = VideoRule$None;

  /// The steps offered for [source].
  List<CompressionPreset> offered(SourceVideo source, {int? byteSize});

  /// The step chosen before the user picks, or null for no transcode.
  CompressionPreset? defaultFor(
    SourceVideo source, {
    CompressionPreset? remembered,
    int? byteSize,
  });

  // The highest of [offered] whose side is at most [cap]'s, else the lowest.
  static CompressionPreset? _clamp(
    List<CompressionPreset> offered,
    CompressionPreset cap,
  ) {
    if (offered.isEmpty) return null;
    CompressionPreset? best;
    for (final preset in offered) {
      if (preset.maxSide <= cap.maxSide) best = preset;
    }
    return best ?? offered.first;
  }
}

/// See [VideoRule.byLongSide].
final class VideoRule$ByLongSide extends VideoRule {
  /// Creates the rule.
  const VideoRule$ByLongSide({
    required this.ladder,
    required this.thresholds,
    required this.defaultCap,
    required this.uncompressedFrom,
  });

  /// The steps, lowest first.
  final List<CompressionPreset> ladder;

  /// Long sides, highest first, each one step more than the next.
  final List<int> thresholds;

  /// The highest default.
  final CompressionPreset defaultCap;

  /// The file size from which a video is not compressed.
  final int uncompressedFrom;

  @override
  List<CompressionPreset> offered(SourceVideo source, {int? byteSize}) {
    if (byteSize != null && byteSize >= uncompressedFrom) return const [];
    final longSide = math.max(
      source.dimensions.width,
      source.dimensions.height,
    );
    var count = 1;
    for (var i = 0; i < thresholds.length; i++) {
      if (longSide > thresholds[i]) {
        count = thresholds.length - i + 1;
        break;
      }
    }
    return ladder.take(math.min(count, ladder.length)).toList();
  }

  @override
  CompressionPreset? defaultFor(
    SourceVideo source, {
    CompressionPreset? remembered,
    int? byteSize,
  }) {
    final cap = remembered == null || remembered.maxSide > defaultCap.maxSide
        ? defaultCap
        : remembered;
    return VideoRule._clamp(offered(source, byteSize: byteSize), cap);
  }
}

/// See [VideoRule.clampedToSource].
final class VideoRule$ClampedToSource extends VideoRule {
  /// Creates the rule.
  const VideoRule$ClampedToSource({required this.fallback});

  /// The default when the host remembers none.
  final CompressionPreset fallback;

  @override
  List<CompressionPreset> offered(SourceVideo source, {int? byteSize}) =>
      CompressionPreset.offeredFor(source.dimensions);

  @override
  CompressionPreset? defaultFor(
    SourceVideo source, {
    CompressionPreset? remembered,
    int? byteSize,
  }) => VideoRule._clamp(offered(source), remembered ?? fallback);
}

/// See [VideoRule.none].
final class VideoRule$None extends VideoRule {
  /// Creates the rule.
  const VideoRule$None();

  @override
  List<CompressionPreset> offered(SourceVideo source, {int? byteSize}) =>
      const [];

  @override
  CompressionPreset? defaultFor(
    SourceVideo source, {
    CompressionPreset? remembered,
    int? byteSize,
  }) => null;
}

/// The per-platform values of media preparation: how stills are scaled and
/// encoded, how big thumbnails are, which video steps are offered, and how
/// many items prepare at once.
///
/// | Policy | Still long side (HQ) | JPEG (HQ) | Thumbnail | Video |
/// | --- | --- | --- | --- | --- |
/// | [$Android] | 1280 (2560) | 80 (99) | 90 px at 55 | 432 / 640 / 848 / 1280 by long side, default at most 848, none from 1000 MB |
/// | [$IOS] | 1280 (2560) | 60 (60) | 320 px at 40 | 480 to 1920 clamped to the source, default Medium |
/// | [$Desktop] | 1280 (2560) | 87, progressive; a light JPEG that fits is kept | 320 px at 87 | none |
/// | [$Web] | 2560 | kept unless past 2560, heavy PNG / BMP (90) or not accepted (92); over 6 MB again at 90 | poster 720 px at 90 | none |
///
/// [forPlatform] picks one; a host may pick any, or build its own from
/// [StillRule] and [VideoRule].
@immutable
final class PreparationPolicy {
  /// Creates a policy.
  const PreparationPolicy({
    required this.stills,
    required this.thumbnail,
    required this.video,
    this.concurrency = 2,
  });

  /// Android's values.
  static const PreparationPolicy $Android = PreparationPolicy(
    stills: StillRule.alwaysEncode(
      side: 1280,
      highQualitySide: 2560,
      quality: 80,
      highQualityQuality: 99,
    ),
    thumbnail: ThumbnailSpec(side: 90, quality: 55),
    video: VideoRule.byLongSide(
      ladder: [
        CompressionPreset.tiny,
        CompressionPreset.low,
        CompressionPreset.medium,
        CompressionPreset.high,
      ],
      thresholds: [1280, 854, 640],
      defaultCap: CompressionPreset.medium,
      uncompressedFrom: 1000 * _mebibyte,
    ),
  );

  /// iOS's values: JPEG 60 at both sizes; high quality changes the size only.
  static const PreparationPolicy $IOS = PreparationPolicy(
    stills: StillRule.alwaysEncode(
      side: 1280,
      highQualitySide: 2560,
      quality: 60,
      highQualityQuality: 60,
    ),
    thumbnail: ThumbnailSpec(side: 320, quality: 40),
    video: VideoRule.clampedToSource(fallback: CompressionPreset.medium),
  );

  /// The desktop values (macOS, Windows, Linux).
  static const PreparationPolicy $Desktop = PreparationPolicy(
    stills: StillRule.keepLightJpeg(
      side: 1280,
      highQualitySide: 2560,
      quality: 87,
      progressive: true,
      maxBitsPerPixel: 4,
    ),
    thumbnail: ThumbnailSpec(side: 320, quality: 87),
    video: VideoRule.none(),
  );

  /// The web values. 92 is the browsers' default JPEG quality, which a
  /// re-encode of a still that is not heavy uses.
  static const PreparationPolicy $Web = PreparationPolicy(
    stills: StillRule.reencodeWhenNeeded(
      side: 2560,
      quality: 92,
      heavyQuality: 90,
      heavyMimeTypes: {'image/png', 'image/bmp'},
      heavyBytes: 2 * _mebibyte,
      acceptedMimeTypes: {'image/jpeg', 'image/png', 'image/bmp', 'image/gif'},
      maxBytes: 6 * _mebibyte,
    ),
    thumbnail: ThumbnailSpec(side: 720, quality: 90),
    video: VideoRule.none(),
  );

  /// The policy of [platform]; [web] (the default on a web build) picks
  /// [$Web] whatever the platform.
  static PreparationPolicy forPlatform(
    TargetPlatform platform, {
    bool web = kIsWeb,
  }) {
    if (web) return $Web;
    return switch (platform) {
      TargetPlatform.android => $Android,
      TargetPlatform.iOS => $IOS,
      TargetPlatform.macOS ||
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.fuchsia => $Desktop,
    };
  }

  /// How stills are treated.
  final StillRule stills;

  /// The size and quality of thumbnails.
  final ThumbnailSpec thumbnail;

  /// How video compression is offered.
  final VideoRule video;

  /// How many items prepare at once.
  final int concurrency;

  /// The plan for a still [source], at standard or [highQuality].
  StillPlan planStill(StillSource source, {bool highQuality = false}) =>
      stills.plan(source, highQuality: highQuality);

  /// The plan to encode again after [plan] produced [resultBytes], or null
  /// when the result stands.
  StillPlan$Encode? retryStill(
    StillPlan$Encode plan, {
    required int resultBytes,
  }) => stills.retry(plan, resultBytes: resultBytes);

  /// The compression steps offered for [source] of [byteSize] bytes; empty
  /// when the video goes as it is.
  List<CompressionPreset> offeredPresets(SourceVideo source, {int? byteSize}) =>
      video.offered(source, byteSize: byteSize);

  /// The step chosen before the user picks, from the host's [remembered]
  /// one; null when the video goes as it is.
  CompressionPreset? defaultPreset(
    SourceVideo source, {
    CompressionPreset? remembered,
    int? byteSize,
  }) => video.defaultFor(source, remembered: remembered, byteSize: byteSize);
}
