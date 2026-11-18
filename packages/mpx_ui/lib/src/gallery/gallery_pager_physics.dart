import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

/// When a drag from the down point becomes a gesture along one axis: the
/// pager's page drag, or the viewer's dismiss drag.
///
/// Decided on the straight line from the down position, so the outcome does
/// not depend on how the platform samples the moves. `along` is the offset
/// on the gesture's axis and `across` the offset on the other, in logical
/// pixels.
sealed class GalleryClaim {
  const GalleryClaim._();

  /// Claims once the drag is longer along the axis than across by more than
  /// [margin]: `|along| > |across| + margin`.
  const factory GalleryClaim.margin(double margin) = GalleryClaim$Margin;

  /// Claims once the drag is [slop] long along the axis and more than
  /// [ratio] times as long along as across.
  const factory GalleryClaim.dominant({required double slop, double ratio}) =
      GalleryClaim$Dominant;

  /// Never claims: no drag along this axis.
  const factory GalleryClaim.none() = GalleryClaim$None;

  /// Whether a drag [along] the axis and [across] it has become this
  /// gesture.
  bool claims(double along, double across);
}

/// [GalleryClaim.margin].
@immutable
final class GalleryClaim$Margin extends GalleryClaim {
  /// Claims past [margin].
  const GalleryClaim$Margin(this.margin) : super._();

  /// How much longer along than across the drag must be.
  final double margin;

  @override
  bool claims(double along, double across) =>
      along.abs() > across.abs() + margin;

  @override
  bool operator ==(Object other) =>
      other is GalleryClaim$Margin && other.margin == margin;

  @override
  int get hashCode => margin.hashCode;
}

/// [GalleryClaim.dominant].
@immutable
final class GalleryClaim$Dominant extends GalleryClaim {
  /// Claims past [slop] when [ratio] times as long along as across.
  const GalleryClaim$Dominant({required this.slop, this.ratio = 1}) : super._();

  /// How far along the axis the drag travels first.
  final double slop;

  /// How many times longer along than across the drag must be.
  final double ratio;

  @override
  bool claims(double along, double across) =>
      along.abs() >= slop && along.abs() > across.abs() * ratio;

  @override
  bool operator ==(Object other) =>
      other is GalleryClaim$Dominant &&
      other.slop == slop &&
      other.ratio == ratio;

  @override
  int get hashCode => Object.hash(slop, ratio);
}

/// [GalleryClaim.none].
@immutable
final class GalleryClaim$None extends GalleryClaim {
  /// Never claims.
  const GalleryClaim$None() : super._();

  @override
  bool claims(double along, double across) => false;

  @override
  bool operator ==(Object other) => other is GalleryClaim$None;

  @override
  int get hashCode => (GalleryClaim$None).hashCode;
}

/// How a drag past the first or the last page moves the page.
sealed class GalleryEdge {
  const GalleryEdge._();

  /// The page follows [factor] of the drag past the edge.
  const factory GalleryEdge.damped(double factor) = GalleryEdge$Damped;

  /// The page follows a rubber band: `(1 - 1 / (x * c / d + 1)) * d` for a
  /// drag `x` past the edge of a page `d` long and a [coefficient] `c`, so
  /// it never travels further than a page however far it is dragged.
  const factory GalleryEdge.rubberBand([double coefficient]) =
      GalleryEdge$RubberBand;

  /// The page does not move past the edge.
  const factory GalleryEdge.hard() = GalleryEdge$Hard;

  /// How far the page moves for a drag [raw] past the edge of a page
  /// [extent] long (signed, like [raw]).
  double follow(double raw, double extent);
}

/// [GalleryEdge.damped].
@immutable
final class GalleryEdge$Damped extends GalleryEdge {
  /// Follows [factor] of the drag.
  const GalleryEdge$Damped(this.factor) : super._();

  /// The share of the drag followed.
  final double factor;

  @override
  double follow(double raw, double extent) => raw * factor;

  @override
  bool operator ==(Object other) =>
      other is GalleryEdge$Damped && other.factor == factor;

  @override
  int get hashCode => factor.hashCode;
}

/// [GalleryEdge.rubberBand].
@immutable
final class GalleryEdge$RubberBand extends GalleryEdge {
  /// A rubber band of [coefficient].
  const GalleryEdge$RubberBand([this.coefficient = 0.55]) : super._();

  /// How stiff the band is: the share followed at the start.
  final double coefficient;

  @override
  double follow(double raw, double extent) {
    if (extent <= 0) return 0;
    final x = raw.abs();
    return raw.sign * (1 - 1 / (x * coefficient / extent + 1)) * extent;
  }

  @override
  bool operator ==(Object other) =>
      other is GalleryEdge$RubberBand && other.coefficient == coefficient;

  @override
  int get hashCode => coefficient.hashCode;
}

/// [GalleryEdge.hard].
@immutable
final class GalleryEdge$Hard extends GalleryEdge {
  /// No movement past the edge.
  const GalleryEdge$Hard() : super._();

  @override
  double follow(double raw, double extent) => 0;

  @override
  bool operator ==(Object other) => other is GalleryEdge$Hard;

  @override
  int get hashCode => (GalleryEdge$Hard).hashCode;
}

/// The strips at the sides of a gallery where a tap goes to the
/// neighbouring page at once.
@immutable
final class GallerySideTap {
  /// Creates the rule: a strip [fraction] of the width wide, at most
  /// [maxWidth] logical pixels or [maxPhysicalWidth] physical ones.
  const GallerySideTap({
    required this.fraction,
    this.maxWidth,
    this.maxPhysicalWidth,
    this.top = 0,
    this.bottom = 0,
    this.onPress = false,
  });

  /// The share of the width a strip takes.
  final double fraction;

  /// The widest a strip is, in logical pixels; no limit when null.
  final double? maxWidth;

  /// The widest a strip is, in physical pixels; no limit when null.
  final double? maxPhysicalWidth;

  /// How far below the top a strip starts.
  final double top;

  /// How far above the bottom a strip ends.
  final double bottom;

  /// Whether the press pages at once (a mouse), rather than the lift.
  final bool onPress;

  /// The width of a strip in a gallery [width] wide at [devicePixelRatio].
  double widthIn(double width, double devicePixelRatio) {
    var side = width * fraction;
    if (maxWidth case final max?) side = math.min(side, max);
    if (maxPhysicalWidth case final max? when devicePixelRatio > 0) {
      side = math.min(side, max / devicePixelRatio);
    }
    return side;
  }

  /// The way a tap at [local] in a gallery of [size] pages: -1 to the
  /// previous page, 1 to the next, 0 outside the strips.
  int directionAt(Offset local, Size size, double devicePixelRatio) {
    if (local.dy < top || local.dy > size.height - bottom) return 0;
    final side = widthIn(size.width, devicePixelRatio);
    if (local.dx < side) return -1;
    if (local.dx > size.width - side) return 1;
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is GallerySideTap &&
      other.fraction == fraction &&
      other.maxWidth == maxWidth &&
      other.maxPhysicalWidth == maxPhysicalWidth &&
      other.top == top &&
      other.bottom == bottom &&
      other.onPress == onPress;

  @override
  int get hashCode =>
      Object.hash(fraction, maxWidth, maxPhysicalWidth, top, bottom, onPress);
}

/// The paging rules of a gallery pager, as pure values: when a drag becomes
/// a page drag, how the page follows past the ends, when a release goes on
/// to the next page, and how the settle runs.
///
/// Lengths are logical pixels; velocities logical pixels per second.
@immutable
final class GalleryPagerPhysics {
  /// Creates the rules.
  const GalleryPagerPhysics({
    required this.claim,
    required this.releaseFraction,
    required this.settleDuration,
    required this.settleCurve,
    required this.edge,
    this.releaseVelocity,
    this.velocityWhileZoomed = true,
    this.handOff = true,
    this.catchesSettle = true,
    this.sideTap,
  });

  /// The Android reference: a drag pages once it is 12 px longer
  /// horizontally than vertically; past the ends the page follows a third
  /// of the drag; a release a third of a page on, or faster than 650 px/s,
  /// goes on (by distance only while the picture is zoomed); the settle
  /// takes 250 ms, decelerating; a touch during the settle is ignored; a
  /// tap on a strip an eighth of the width wide (at most 135 physical
  /// pixels), below the bars, pages at once.
  static const GalleryPagerPhysics $Android = GalleryPagerPhysics(
    claim: GalleryClaim.margin(12),
    releaseFraction: 1 / 3,
    releaseVelocity: 650,
    velocityWhileZoomed: false,
    // A decelerate interpolator of factor 1.5: 1 - (1 - t)^3.
    settleDuration: Duration(milliseconds: 250),
    settleCurve: Curves.easeOutCubic,
    edge: GalleryEdge.damped(1 / 3),
    catchesSettle: false,
    sideTap: GallerySideTap(
      fraction: 1 / 8,
      maxPhysicalWidth: 135,
      // Below the action bar and 40 px more.
      top: 56 + 40,
    ),
  );

  /// The iOS reference: a drag pages past the platform pan slop when it is
  /// more horizontal than vertical; past the ends a rubber band; a release
  /// past half a page or with a flick goes on; the settle is a spring a
  /// touch catches.
  static const GalleryPagerPhysics $IOS = GalleryPagerPhysics(
    claim: GalleryClaim.dominant(slop: 10),
    releaseFraction: 1 / 2,
    releaseVelocity: 300,
    settleDuration: Duration(milliseconds: 400),
    settleCurve: _criticalSpring,
    edge: GalleryEdge.rubberBand(),
  );

  /// The desktop reference: no drag pages and items switch at once; a press
  /// on a 90 px strip at either side, clear of the 47 px bars, pages.
  static const GalleryPagerPhysics $Desktop = GalleryPagerPhysics(
    claim: GalleryClaim.none(),
    releaseFraction: 1 / 2,
    settleDuration: Duration.zero,
    settleCurve: Curves.linear,
    edge: GalleryEdge.hard(),
    handOff: false,
    sideTap: GallerySideTap(
      fraction: 1,
      maxWidth: 90,
      top: 47,
      bottom: 47,
      onPress: true,
    ),
  );

  /// A feed of full-screen clips: a drag pages past 10 px when it is more
  /// along the axis than across; past half a page or with a flick it goes
  /// on, settling in 300 ms.
  static const GalleryPagerPhysics feed = GalleryPagerPhysics(
    claim: GalleryClaim.dominant(slop: 10),
    releaseFraction: 1 / 2,
    releaseVelocity: 400,
    settleDuration: Duration(milliseconds: 300),
    settleCurve: Curves.easeOutCubic,
    edge: GalleryEdge.damped(1 / 3),
  );

  static const Curve _criticalSpring = _CriticalSpring();

  /// When a drag becomes a page drag.
  final GalleryClaim claim;

  /// How much of a page a drag covers to go on to the next one on release.
  final double releaseFraction;

  /// A release this fast toward a page goes on to it however short the
  /// drag; null for no velocity rule.
  final double? releaseVelocity;

  /// Whether [releaseVelocity] counts for a page drag a zoomed picture
  /// handed on at its edge.
  final bool velocityWhileZoomed;

  /// How long the settle after a release (or a step) takes; zero switches
  /// at once.
  final Duration settleDuration;

  /// The curve of the settle.
  final Curve settleCurve;

  /// How the page follows a drag past the first or the last page.
  final GalleryEdge edge;

  /// Whether a zoomed picture panned against its edge hands the rest of the
  /// drag to the pager.
  final bool handOff;

  /// Whether a touch during a settle catches the page; else the touch is
  /// ignored until the settle lands.
  final bool catchesSettle;

  /// The strips a tap pages on; none when null.
  final GallerySideTap? sideTap;

  /// The page a release lands on, from the page the drag started on:
  /// +1 the next, -1 the previous, 0 back.
  ///
  /// [fraction] is how far the drag moved, in pages, positive toward the
  /// next; [velocity] likewise, in logical pixels per second; [zoomed] when
  /// a zoomed picture handed the drag on. The next page is checked first.
  int release({
    required double fraction,
    required double velocity,
    required bool canNext,
    required bool canPrevious,
    bool zoomed = false,
  }) {
    final fast = zoomed && !velocityWhileZoomed ? null : releaseVelocity;
    if (canNext &&
        (fraction >= releaseFraction ||
            (fast != null && fraction >= 0 && velocity >= fast))) {
      return 1;
    }
    if (canPrevious &&
        (-fraction >= releaseFraction ||
            (fast != null && fraction <= 0 && -velocity >= fast))) {
      return -1;
    }
    return 0;
  }

  /// These rules with the given fields changed.
  ///
  /// A field passed as null keeps its value: a nullable field cannot be
  /// cleared here, only set.
  GalleryPagerPhysics copyWith({
    GalleryClaim? claim,
    double? releaseFraction,
    double? releaseVelocity,
    bool? velocityWhileZoomed,
    Duration? settleDuration,
    Curve? settleCurve,
    GalleryEdge? edge,
    bool? handOff,
    bool? catchesSettle,
    GallerySideTap? sideTap,
  }) => GalleryPagerPhysics(
    claim: claim ?? this.claim,
    releaseFraction: releaseFraction ?? this.releaseFraction,
    releaseVelocity: releaseVelocity ?? this.releaseVelocity,
    velocityWhileZoomed: velocityWhileZoomed ?? this.velocityWhileZoomed,
    settleDuration: settleDuration ?? this.settleDuration,
    settleCurve: settleCurve ?? this.settleCurve,
    edge: edge ?? this.edge,
    handOff: handOff ?? this.handOff,
    catchesSettle: catchesSettle ?? this.catchesSettle,
    sideTap: sideTap ?? this.sideTap,
  );

  @override
  bool operator ==(Object other) =>
      other is GalleryPagerPhysics &&
      other.claim == claim &&
      other.releaseFraction == releaseFraction &&
      other.releaseVelocity == releaseVelocity &&
      other.velocityWhileZoomed == velocityWhileZoomed &&
      other.settleDuration == settleDuration &&
      other.settleCurve == settleCurve &&
      other.edge == edge &&
      other.handOff == handOff &&
      other.catchesSettle == catchesSettle &&
      other.sideTap == sideTap;

  @override
  int get hashCode => Object.hash(
    claim,
    releaseFraction,
    releaseVelocity,
    velocityWhileZoomed,
    settleDuration,
    settleCurve,
    edge,
    handOff,
    catchesSettle,
    sideTap,
  );
}

/// A critically damped spring as a curve: fast at first, settling without
/// overshoot, the shape of a platform paging deceleration.
final class _CriticalSpring extends Curve {
  const _CriticalSpring();

  static const double _sharpness = 8;

  @override
  double transformInternal(double t) {
    double spring(double t) =>
        1 - (1 + _sharpness * t) * math.exp(-_sharpness * t);
    return spring(t) / spring(1);
  }
}
