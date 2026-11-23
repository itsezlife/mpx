import 'dart:math' as math;
import 'dart:ui';

import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_profile.dart';
import 'package:mpx_core/src/asset/asset_spec.dart';

/// A named recipe a surface attaches with: the logical [size] it shows an
/// asset at, and the [spec] and [profile] that size and use imply.
///
/// A surface does not choose pixels, decode modes or playback flags itself; it
/// picks a preset, so two surfaces that mean the same thing share one decode
/// (the spec is part of the entry identity) and a host changes how a class of
/// surfaces looks in one place. Presets are plain values: a host builds its
/// own with the constructor or the recipes of `AssetPresets`.
@immutable
final class AssetPreset {
  /// Creates a preset showing assets at [size] (logical pixels), decoded as
  /// [spec] and used as [profile] says.
  const AssetPreset({
    required this.size,
    required this.spec,
    required this.profile,
  });

  /// The logical box the surface shows the asset in: the natural size of a
  /// `AssetView`.
  final Size size;

  /// What is decoded: the pixels [size] takes at the device density.
  final AssetSpec spec;

  /// How the surface uses the asset.
  final AssetProfile profile;

  /// Whether the surface is a circle: its profile's corner radius rounds
  /// the shorter side of [size] whole ([AssetPresets.round]). A round
  /// surface draws its stand-ins enlarged inside the circle
  /// (`MediaStageStyle.roundPreviewScale`) and its status control at the
  /// round size (`MediaStatusStyle.roundVideoDiameter`).
  bool get isRound =>
      profile.cornerRadius > 0 && profile.cornerRadius * 2 >= size.shortestSide;

  @override
  bool operator ==(Object other) =>
      other is AssetPreset &&
      other.size == size &&
      other.spec == spec &&
      other.profile == profile;

  @override
  int get hashCode => Object.hash(size, spec, profile);

  @override
  String toString() => 'AssetPreset($size, $spec, $profile)';
}

/// Recipes for the presets a host builds: a square box, a circle, and a box
/// of the media's own proportion with a capped decode.
///
/// A host names the presets of its own surfaces (a grid cell, media set in
/// text, media shown on its own) on top of these, with the size and playback
/// rules of its design.
///
/// The decodes of [square], [round] and [media] stand on a ladder of sizes:
/// each side is rounded up to the next rung, three to an octave (a power of
/// two, times 5/4, times 8/5: ... 256, 320, 410, 512, 640, 820, 1024 ...).
/// A box that follows a window being dragged asks for a new decode only when
/// it crosses a rung, not at every pixel, for a decode at most about a
/// quarter larger on a side than the box. The cache draws a finished still
/// of a larger rung for a smaller one (`AssetCacheScope.attach`), so a
/// shrinking box decodes nothing.
abstract final class AssetPresets {
  /// A square of [extent] logical pixels decoded at [devicePixelRatio], used
  /// as [profile] says.
  ///
  /// The pixel size is the extent at the density, rounded up to its rung
  /// (see [AssetPresets]), so the decode is never smaller than the box.
  static AssetPreset square({
    required double extent,
    required double devicePixelRatio,
    required AssetProfile profile,
    AssetDecodeMode decodeMode = AssetDecodeMode.original,
  }) => AssetPreset(
    size: Size.square(extent),
    spec: _onRung(
      AssetSpec.atDensity(
        logicalWidth: extent,
        logicalHeight: extent,
        devicePixelRatio: devicePixelRatio,
        decodeMode: decodeMode,
      ),
    ),
    profile: profile,
  );

  /// A circle of [diameter] logical pixels decoded at [devicePixelRatio]
  /// (a round video): a [square] whose profile, otherwise as [profile] says,
  /// clips the picture to the circle (`AssetProfile.cornerRadius`).
  static AssetPreset round({
    required double diameter,
    required double devicePixelRatio,
    required AssetProfile profile,
  }) => square(
    extent: diameter,
    devicePixelRatio: devicePixelRatio,
    profile: profile.copyWith(cornerRadius: diameter / 2),
  );

  /// The longest side, in pixels, an animation is decoded at by
  /// [animation]: the largest frame the animation frame pools hold, so a
  /// vector animation or a clip is rendered at it, and an image larger than
  /// it is scaled down to it.
  static const int animationPixelExtent = 512;

  /// Content that plays (an animated image, a vector animation, a silent
  /// clip) shown in a box of [size] logical pixels, used as [profile] says.
  ///
  /// The decode does not follow the box: every surface that shows the
  /// content as an animation asks for the same spec, the content's own size
  /// fitted into [animationPixelExtent] pixels (a decoder never scales up),
  /// so a thumbnail and the fullscreen copy of it are one cache entry with
  /// one playback, drawn in two places, and the fullscreen copy shows the
  /// thumbnail's frame. The price is a thumbnail decoded larger than its
  /// pixels and a fullscreen copy drawn from at most
  /// [animationPixelExtent] pixels; a vector animation renders at that size
  /// for both.
  static AssetPreset animation({
    required Size size,
    required AssetProfile profile,
  }) => AssetPreset(
    size: size,
    spec: const AssetSpec(
      pixelWidth: animationPixelExtent,
      pixelHeight: animationPixelExtent,
    ),
    profile: profile,
  );

  /// Media shown on its own: a box of [size] logical pixels, of the media's
  /// own proportion, decoded at [devicePixelRatio] and used as [profile]
  /// says.
  ///
  /// [maxPixelExtent] caps the decode's longer side, the shorter scaled with
  /// it: a large box on a dense screen draws a decode smaller than its pixels
  /// rather than one larger than the media holds. Under the cap the decode is
  /// the box at the density, on its rung like [square]; a rung past the cap
  /// is held to the cap.
  static AssetPreset media({
    required Size size,
    required double devicePixelRatio,
    required AssetProfile profile,
    int? maxPixelExtent,
  }) {
    final full = AssetSpec.atDensity(
      logicalWidth: size.width,
      logicalHeight: size.height,
      devicePixelRatio: devicePixelRatio,
    );
    final longer = math.max(full.pixelWidth, full.pixelHeight);
    final onRung = _onRung(full);
    // A rung past the cap is held to it: the cap is one fixed size, as
    // steady across a window drag as a rung.
    final spec = switch (maxPixelExtent) {
      final cap? when math.max(onRung.pixelWidth, onRung.pixelHeight) > cap =>
        AssetSpec(
          pixelWidth: math.max(1, (full.pixelWidth * cap / longer).round()),
          pixelHeight: math.max(1, (full.pixelHeight * cap / longer).round()),
        ),
      _ => onRung,
    };
    return AssetPreset(size: size, spec: spec, profile: profile);
  }

  // [spec] with each side rounded up to the ladder's next rung. Each side on
  // its own: the decoder fits the picture inside the spec keeping its
  // proportion, so the decode still covers the box, and a box whose
  // proportion wavers by a rounded pixel asks for the same spec.
  static AssetSpec _onRung(AssetSpec spec) => AssetSpec(
    pixelWidth: _rungOf(spec.pixelWidth),
    pixelHeight: _rungOf(spec.pixelHeight),
    decodeMode: spec.decodeMode,
    variant: spec.variant,
  );

  // The smallest rung at least [side]. Integer rungs, a power of two p and
  // its 5/8 and 4/5 rounded up, so an exact power never lands a pixel past
  // itself as a float root of two would.
  static int _rungOf(int side) {
    var power = 1;
    while (power < side) {
      power <<= 1;
    }
    final fiveEighths = (power * 5 + 7) ~/ 8;
    if (side <= fiveEighths) return fiveEighths;
    final fourFifths = (power * 4 + 4) ~/ 5;
    if (side <= fourFifths) return fourFifths;
    return power;
  }
}
