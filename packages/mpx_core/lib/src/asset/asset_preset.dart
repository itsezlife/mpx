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
  /// `ContentView`.
  final Size size;

  /// What is decoded: the pixels [size] takes at the device density.
  final AssetSpec spec;

  /// How the surface uses the asset.
  final AssetProfile profile;

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

/// Recipes for the presets a host builds: a square box, and a box of the
/// media's own proportion with a capped decode.
///
/// A host names the presets of its own surfaces (a grid cell, media set in
/// text, media shown on its own) on top of these, with the size and playback
/// rules of its design.
abstract final class AssetPresets {
  /// A square of [extent] logical pixels decoded at [devicePixelRatio], used
  /// as [profile] says.
  ///
  /// The pixel size is the extent at the density, rounded up so the decode is
  /// never smaller than the box.
  static AssetPreset square({
    required double extent,
    required double devicePixelRatio,
    required AssetProfile profile,
    AssetDecodeMode decodeMode = AssetDecodeMode.original,
  }) => AssetPreset(
    size: Size.square(extent),
    spec: AssetSpec.atDensity(
      logicalWidth: extent,
      logicalHeight: extent,
      devicePixelRatio: devicePixelRatio,
      decodeMode: decodeMode,
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
  /// the box at the density, rounded up like [square].
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
    final spec = switch (maxPixelExtent) {
      final cap? when longer > cap => AssetSpec(
        pixelWidth: math.max(1, (full.pixelWidth * cap / longer).round()),
        pixelHeight: math.max(1, (full.pixelHeight * cap / longer).round()),
      ),
      _ => full,
    };
    return AssetPreset(size: size, spec: spec, profile: profile);
  }
}
