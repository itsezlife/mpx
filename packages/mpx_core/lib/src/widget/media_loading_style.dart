import 'package:flutter/material.dart';
import 'package:mpx_core/src/asset/outline_paintable.dart';
import 'package:mpx_core/src/widget/media_badge_style.dart';
import 'package:mpx_core/src/widget/media_status_control.dart';
import 'package:mpx_core/src/widget/media_status_style.dart';

/// How a media item rises through its stages (nothing, a preview, a
/// thumbnail, the content) on one platform: the fades between them, the
/// content's scale-in, and how a preview and an outline are drawn.
///
/// A value, resolved per platform as the viewer policy is: [$Android],
/// [$IOS] and [$Desktop], changed with [copyWith] (a host that wants fades
/// on the desktop sets [stageFade]).
@immutable
final class MediaStageStyle {
  /// Creates a style.
  const MediaStageStyle({
    required this.stageFade,
    required this.gifFade,
    required this.outlineFill,
    this.fill,
    this.contentScaleIn = 0,
    this.previewWash,
    this.outlineTintOpacity = 1,
    this.outlineShimmer,
    this.roundPreviewScale = 1.2,
  }) : assert(contentScaleIn >= 0, 'A scale-in is not negative.'),
       assert(
         outlineTintOpacity >= 0 && outlineTintOpacity <= 1,
         'An opacity is within 0..1.',
       );

  /// What a surface paints under its media before any stage, or null for
  /// nothing (the surface behind shows through).
  final Color? fill;

  /// How long a rise takes to fade in over the stand-in it replaces (a
  /// thumbnail over a preview, still content over its stand-in);
  /// [Duration.zero] swaps at once.
  final Duration stageFade;

  /// How long a playing surface's content (a loop, an animation) takes to
  /// fade in over its stand-in; [Duration.zero] swaps at once.
  final Duration gifFade;

  /// How much larger the content is drawn as its fade starts: it shrinks to
  /// its size as `1 + contentScaleIn · (1 − easeIn(t))` over the fade, about
  /// the box's centre. 0 for none.
  final double contentScaleIn;

  /// A colour washed over a raster preview, or null for none.
  final Color? previewWash;

  /// The fill of an outline preview where the surface gives no tint.
  final Color outlineFill;

  /// The opacity an outline takes in the surface's tint (the host's token
  /// for a quiet fill), where one is given.
  final double outlineTintOpacity;

  /// The sweep over an outline preview, or null for a flat fill.
  final OutlineShimmer? outlineShimmer;

  /// How much a round preview is enlarged inside its circle, so the blur's
  /// soft edge falls outside the clip.
  final double roundPreviewScale;

  /// Android: 150 ms linear fades (250 ms for a loop) with a 5 % scale-in,
  /// a flat outline at 70 / 255 of the host's quiet fill.
  static const MediaStageStyle $Android = MediaStageStyle(
    stageFade: Duration(milliseconds: 150),
    gifFade: Duration(milliseconds: 250),
    contentScaleIn: 0.05,
    outlineFill: Color(0x46000000),
    outlineTintOpacity: 70 / 255,
  );

  /// iOS: 200 ms linear fades, an outline in a muted blue-grey at 0.25 with
  /// a 1.3 s ease-out sweep.
  static const MediaStageStyle $IOS = MediaStageStyle(
    stageFade: Duration(milliseconds: 200),
    gifFade: Duration(milliseconds: 200),
    outlineFill: Color(0x40748391),
    outlineTintOpacity: 0.25,
    outlineShimmer: OutlineShimmer(
      sweep: Duration(milliseconds: 1300),
      curve: Curves.easeOut,
    ),
  );

  /// Desktop: every stage swaps at once, a preview has a black wash at
  /// 48 / 255, and an outline in the host's quiet fill slides a highlight
  /// across for 1000 ms and rests 1000 ms.
  static const MediaStageStyle $Desktop = MediaStageStyle(
    stageFade: Duration.zero,
    gifFade: Duration.zero,
    previewWash: Color(0x30000000),
    outlineFill: Color(0x40000000),
    outlineShimmer: OutlineShimmer(
      sweep: Duration(milliseconds: 1000),
      wait: Duration(milliseconds: 1000),
    ),
  );

  /// A copy with the given fields changed. The `clear` flags set a nullable
  /// field to null.
  MediaStageStyle copyWith({
    Color? fill,
    bool clearFill = false,
    Duration? stageFade,
    Duration? gifFade,
    double? contentScaleIn,
    Color? previewWash,
    bool clearPreviewWash = false,
    Color? outlineFill,
    double? outlineTintOpacity,
    OutlineShimmer? outlineShimmer,
    bool clearOutlineShimmer = false,
    double? roundPreviewScale,
  }) => MediaStageStyle(
    fill: clearFill ? null : fill ?? this.fill,
    stageFade: stageFade ?? this.stageFade,
    gifFade: gifFade ?? this.gifFade,
    contentScaleIn: contentScaleIn ?? this.contentScaleIn,
    previewWash: clearPreviewWash ? null : previewWash ?? this.previewWash,
    outlineFill: outlineFill ?? this.outlineFill,
    outlineTintOpacity: outlineTintOpacity ?? this.outlineTintOpacity,
    outlineShimmer: clearOutlineShimmer
        ? null
        : outlineShimmer ?? this.outlineShimmer,
    roundPreviewScale: roundPreviewScale ?? this.roundPreviewScale,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaStageStyle &&
      other.fill == fill &&
      other.stageFade == stageFade &&
      other.gifFade == gifFade &&
      other.contentScaleIn == contentScaleIn &&
      other.previewWash == previewWash &&
      other.outlineFill == outlineFill &&
      other.outlineTintOpacity == outlineTintOpacity &&
      other.outlineShimmer == outlineShimmer &&
      other.roundPreviewScale == roundPreviewScale;

  @override
  int get hashCode => Object.hash(
    fill,
    stageFade,
    gifFade,
    contentScaleIn,
    previewWash,
    outlineFill,
    outlineTintOpacity,
    outlineShimmer,
    roundPreviewScale,
  );

  @override
  String toString() =>
      'MediaStageStyle(fade: $stageFade, loop fade: $gifFade, '
      'scale-in: $contentScaleIn)';
}

/// How media loads on one platform: the rise through its stages ([stages]),
/// the status control ([status]) and the badge ([badge]).
///
/// One value per platform, as the viewer policy: [$Android], [$IOS],
/// [$Desktop] and [forPlatform], each changed with [copyWith] (a host sets
/// its theme's colours and text, say). Resolved for a surface by
/// [MediaLoadingStyleScope.resolve].
@immutable
final class MediaLoadingStyle {
  /// Creates a style.
  const MediaLoadingStyle({
    required this.stages,
    required this.status,
    required this.badge,
  });

  /// How a media item rises through its stages.
  final MediaStageStyle stages;

  /// The status control (`MediaStatusControl`).
  final MediaStatusStyle status;

  /// The duration and size label (`MediaBadge`).
  final MediaBadgeStyle badge;

  /// The Android style.
  static const MediaLoadingStyle $Android = MediaLoadingStyle(
    stages: MediaStageStyle.$Android,
    status: MediaStatusStyle.$Android,
    badge: MediaBadgeStyle.$Android,
  );

  /// The iOS style.
  static const MediaLoadingStyle $IOS = MediaLoadingStyle(
    stages: MediaStageStyle.$IOS,
    status: MediaStatusStyle.$IOS,
    badge: MediaBadgeStyle.$IOS,
  );

  /// The desktop style.
  static const MediaLoadingStyle $Desktop = MediaLoadingStyle(
    stages: MediaStageStyle.$Desktop,
    status: MediaStatusStyle.$Desktop,
    badge: MediaBadgeStyle.$Desktop,
  );

  /// The style of [platform]. On the web, the platform is the one the
  /// browser runs on; there is no web style of its own yet.
  static MediaLoadingStyle forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.iOS => $IOS,
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux => $Desktop,
        TargetPlatform.android || TargetPlatform.fuchsia => $Android,
      };

  /// A copy with the given fields changed.
  MediaLoadingStyle copyWith({
    MediaStageStyle? stages,
    MediaStatusStyle? status,
    MediaBadgeStyle? badge,
  }) => MediaLoadingStyle(
    stages: stages ?? this.stages,
    status: status ?? this.status,
    badge: badge ?? this.badge,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaLoadingStyle &&
      other.stages == stages &&
      other.status == status &&
      other.badge == badge;

  @override
  int get hashCode => Object.hash(stages, status, badge);

  @override
  String toString() => 'MediaLoadingStyle($stages)';
}

/// Builds the status control of a surface in place of the default one: the
/// host's own widget for the [control] mpx would build (its status, or the
/// binding it maps, and its taps).
typedef MediaStatusBuilder =
    Widget Function(BuildContext context, MediaStatusControl control);

/// Changes the loading style of the media below it: [style] is applied to
/// the style of the theme's platform, so `(platform) => platform.copyWith(...)`
/// changes a field and keeps the platform's other values.
///
/// [statusBuilder] replaces the status control of every surface below that
/// names none of its own.
class MediaLoadingStyleScope extends InheritedWidget {
  /// Applies [style] and [statusBuilder] below.
  const MediaLoadingStyleScope({
    required super.child,
    this.style,
    this.statusBuilder,
    super.key,
  });

  /// The style below, from the platform's default; null keeps it.
  final MediaLoadingStyle Function(MediaLoadingStyle platform)? style;

  /// The host's status control, or null for the default one.
  final MediaStatusBuilder? statusBuilder;

  /// The style a surface at [context] uses: its own [style] when given, else
  /// the closest scope's function applied to the style of the theme's
  /// platform (`Theme.of(context).platform`), else that platform style.
  static MediaLoadingStyle resolve(
    BuildContext context, {
    MediaLoadingStyle? style,
  }) {
    if (style != null) return style;
    final platform = MediaLoadingStyle.forPlatform(Theme.of(context).platform);
    final scope = context
        .dependOnInheritedWidgetOfExactType<MediaLoadingStyleScope>();
    return scope?.style?.call(platform) ?? platform;
  }

  /// The host's status control of the closest scope, or null.
  static MediaStatusBuilder? statusBuilderOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MediaLoadingStyleScope>()
      ?.statusBuilder;

  @override
  bool updateShouldNotify(MediaLoadingStyleScope oldWidget) =>
      !identical(style, oldWidget.style) ||
      !identical(statusBuilder, oldWidget.statusBuilder);
}
