import 'package:flutter/animation.dart';
import 'package:meta/meta.dart';

/// How the arc of a status control follows a new progress: it eases from the
/// arc shown, or closes a share of the gap every frame.
@immutable
final class MediaArcSmoothing {
  /// Eases from the arc shown to the new progress over [duration] on
  /// [curve], plus up to [extraDuration] more as the step grows from
  /// [extraAbove] to all of it. With [forwardOnly] a lower progress (a
  /// download that started again) is shown at once.
  const MediaArcSmoothing.eased({
    required Duration this.duration,
    this.curve = Curves.linear,
    this.extraDuration = Duration.zero,
    this.extraAbove = 1,
    this.forwardOnly = false,
  }) : constant = null;

  /// Closes `1 − constant / (constant + dt)` of the gap each frame of `dt`:
  /// fast for a large gap, never overshooting.
  const MediaArcSmoothing.asymptotic(Duration this.constant)
    : duration = null,
      curve = Curves.linear,
      extraDuration = Duration.zero,
      extraAbove = 1,
      forwardOnly = false;

  /// The ease of an eased smoothing; null for an asymptotic one.
  final Duration? duration;

  /// The curve of an eased smoothing.
  final Curve curve;

  /// The most an eased smoothing adds for a large step.
  final Duration extraDuration;

  /// The step (0 to 1) above which [extraDuration] starts to apply.
  final double extraAbove;

  /// Whether a lower progress is shown at once.
  final bool forwardOnly;

  /// The time constant of an asymptotic smoothing; null for an eased one.
  final Duration? constant;

  /// How long an eased smoothing takes for a step of [delta] (0 to 1).
  Duration durationFor(double delta) {
    final base = duration ?? Duration.zero;
    if (extraDuration == Duration.zero || delta <= extraAbove) return base;
    final share = ((delta - extraAbove) / (1 - extraAbove)).clamp(0.0, 1.0);
    return base + extraDuration * share;
  }

  @override
  bool operator ==(Object other) =>
      other is MediaArcSmoothing &&
      other.duration == duration &&
      other.curve == curve &&
      other.extraDuration == extraDuration &&
      other.extraAbove == extraAbove &&
      other.forwardOnly == forwardOnly &&
      other.constant == constant;

  @override
  int get hashCode => Object.hash(
    duration,
    curve,
    extraDuration,
    extraAbove,
    forwardOnly,
    constant,
  );
}

/// The arc of a status control that knows no progress: it turns once per
/// [turn] while its sweep swings between [minSweepDegrees] and
/// [maxSweepDegrees] once per [sweepPeriod] (a sine), or holds when both
/// are equal.
@immutable
final class MediaSpinnerStyle {
  /// Creates a spinner.
  const MediaSpinnerStyle({
    required this.turn,
    required this.minSweepDegrees,
    required this.maxSweepDegrees,
    required this.sweepPeriod,
  });

  /// One full turn.
  final Duration turn;

  /// The shortest the arc gets, in degrees.
  final double minSweepDegrees;

  /// The longest the arc gets, in degrees.
  final double maxSweepDegrees;

  /// One swing of the sweep, short to long and back.
  final Duration sweepPeriod;

  /// This spinner with the given fields replaced.
  MediaSpinnerStyle copyWith({
    Duration? turn,
    double? minSweepDegrees,
    double? maxSweepDegrees,
    Duration? sweepPeriod,
  }) => MediaSpinnerStyle(
    turn: turn ?? this.turn,
    minSweepDegrees: minSweepDegrees ?? this.minSweepDegrees,
    maxSweepDegrees: maxSweepDegrees ?? this.maxSweepDegrees,
    sweepPeriod: sweepPeriod ?? this.sweepPeriod,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaSpinnerStyle &&
      other.turn == turn &&
      other.minSweepDegrees == minSweepDegrees &&
      other.maxSweepDegrees == maxSweepDegrees &&
      other.sweepPeriod == sweepPeriod;

  @override
  int get hashCode =>
      Object.hash(turn, minSweepDegrees, maxSweepDegrees, sweepPeriod);
}

/// How a status control comes and goes.
enum MediaStatusAppearance {
  /// The whole control scales from nothing and back.
  scale,

  /// The disc scales from a dot as the control fades in, and back.
  discScaleFade,

  /// The control fades in and out.
  fade,
}

/// How one icon of a status control turns into another.
enum MediaIconMorph {
  /// Download turns into cancel in three phases (the arrow shrinks away, a
  /// pause, the cross grows in turning) over the style's download-to-cancel
  /// time; other pairs scale and fade.
  phased,

  /// Every pair scales and fades: the old icon out, the new one in.
  scaleFade,
}

/// The look and motion of a status control (`MediaStatusControl`): a disc,
/// a progress arc, and an icon.
///
/// [$Android], [$IOS] and [$Desktop] are each platform's reference; a host
/// adjusts one with [copyWith] through `MediaLoadingStyleScope`. Lengths are
/// logical pixels; angles are degrees, clockwise from three o'clock.
@immutable
final class MediaStatusStyle {
  /// Creates a style.
  const MediaStatusStyle({
    required this.diameter,
    required this.compactDiameter,
    required this.roundVideoDiameter,
    required this.compactOffset,
    required this.discColor,
    required this.arcColor,
    required this.iconColor,
    required this.arcStroke,
    required this.minArcStroke,
    required this.arcInset,
    required this.minSweepDegrees,
    required this.spinPeriod,
    required this.spinStartDegrees,
    required this.smoothing,
    required this.spinner,
    required this.appearance,
    required this.appearDuration,
    required this.disappearDuration,
    required this.iconMorph,
    required this.morphDuration,
    required this.playPauseDuration,
    required this.downloadCancelDuration,
    required this.iconSize,
    required this.iconStroke,
    this.discColorDark,
    this.discHoverColor,
    this.hoverDuration = Duration.zero,
    this.downloadCancelPhases = const (0.5, 0.2, 0.3),
  });

  /// The disc of a control.
  final double diameter;

  /// The disc of a compact control (the corner control of streamable
  /// video).
  final double compactDiameter;

  /// The disc over a round video.
  final double roundVideoDiameter;

  /// Where a compact control sits from the top-left corner of the media.
  final Offset compactOffset;

  /// The disc's fill.
  final Color discColor;

  /// The disc's fill under a dark theme, or null for [discColor].
  final Color? discColorDark;

  /// The disc's fill under a hovering pointer, or null for no hover.
  final Color? discHoverColor;

  /// How long the disc takes to change to and from [discHoverColor].
  final Duration hoverDuration;

  /// The progress arc.
  final Color arcColor;

  /// The icon.
  final Color iconColor;

  /// The arc's stroke at [diameter]; it scales with the disc.
  final double arcStroke;

  /// The thinnest the arc's stroke gets on a smaller disc.
  final double minArcStroke;

  /// How far the arc sits inside the disc's edge.
  final double arcInset;

  /// The shortest the progress arc gets, in degrees.
  final double minSweepDegrees;

  /// One turn of the progress arc's start.
  final Duration spinPeriod;

  /// Where the arc of a new control starts.
  final double spinStartDegrees;

  /// How the arc follows a new progress.
  final MediaArcSmoothing smoothing;

  /// The arc while no progress is known.
  final MediaSpinnerStyle spinner;

  /// How the control comes and goes.
  final MediaStatusAppearance appearance;

  /// How long the control takes to come.
  final Duration appearDuration;

  /// How long the control takes to go.
  final Duration disappearDuration;

  /// How icons turn into one another.
  final MediaIconMorph iconMorph;

  /// A change of icon not named below.
  final Duration morphDuration;

  /// Play to pause and back.
  final Duration playPauseDuration;

  /// Download to cancel and back.
  final Duration downloadCancelDuration;

  /// The shares of [downloadCancelDuration] a [MediaIconMorph.phased] morph
  /// spends shrinking the old icon, pausing, and growing the new one; they
  /// add up to 1.
  final (double, double, double) downloadCancelPhases;

  /// The icon's size, as a share of the disc.
  final double iconSize;

  /// The stroke of a line icon (download, cancel) at [diameter].
  final double iconStroke;

  /// The arc's stroke on a disc of [disc] logical pixels.
  double arcStrokeAt(double disc) {
    final scaled = arcStroke * disc / diameter;
    return scaled < minArcStroke ? minArcStroke : scaled;
  }

  /// The Android reference: a 44 dp disc of `0x66000000` with a 3 dp white
  /// arc inset 4 dp, at least 4°, turning once per 2.5 s from 112°; a new
  /// progress eases in over 200 ms, decelerating, forward only. Download
  /// turns into cancel in 400 ms (0.5 / 0.2 / 0.3), play and pause in
  /// 300 ms, other icons in 220 ms; the control scales in and out in
  /// 220 ms. A compact control is 24 dp at (8, 8).
  static const MediaStatusStyle $Android = MediaStatusStyle(
    diameter: 44,
    compactDiameter: 24,
    roundVideoDiameter: 44,
    compactOffset: Offset(8, 8),
    discColor: Color(0x66000000),
    arcColor: Color(0xFFFFFFFF),
    iconColor: Color(0xFFFFFFFF),
    arcStroke: 3,
    minArcStroke: 2,
    arcInset: 4,
    minSweepDegrees: 4,
    spinPeriod: Duration(milliseconds: 2500),
    spinStartDegrees: 112,
    smoothing: MediaArcSmoothing.eased(
      duration: Duration(milliseconds: 200),
      curve: Curves.decelerate,
      forwardOnly: true,
    ),
    spinner: MediaSpinnerStyle(
      turn: Duration(milliseconds: 2000),
      minSweepDegrees: 4,
      maxSweepDegrees: 270,
      sweepPeriod: Duration(milliseconds: 1000),
    ),
    appearance: MediaStatusAppearance.scale,
    appearDuration: Duration(milliseconds: 220),
    disappearDuration: Duration(milliseconds: 220),
    iconMorph: MediaIconMorph.phased,
    morphDuration: Duration(milliseconds: 220),
    playPauseDuration: Duration(milliseconds: 300),
    downloadCancelDuration: Duration(milliseconds: 400),
    iconSize: 0.3,
    iconStroke: 2,
  );

  /// The iOS reference: a 50 pt disc of black at 0.45 (0.6 under a dark
  /// theme) with a white arc of `max(1.6, 2.25 · d / 50)` inset 2.5, at
  /// least about 10°, the whole arc turning once per 1.5 s; a new progress
  /// moves linearly over 0.2 s plus up to 0.45 s for a step above a
  /// quarter. The disc scales from a dot and fades in 200 ms; icons scale
  /// and fade in 200 ms. A compact control is 32 pt.
  static const MediaStatusStyle $IOS = MediaStatusStyle(
    diameter: 50,
    compactDiameter: 32,
    roundVideoDiameter: 54,
    compactOffset: Offset(6, 6),
    discColor: Color.from(alpha: 0.45, red: 0, green: 0, blue: 0),
    discColorDark: Color.from(alpha: 0.6, red: 0, green: 0, blue: 0),
    arcColor: Color(0xFFFFFFFF),
    iconColor: Color(0xFFFFFFFF),
    arcStroke: 2.25,
    minArcStroke: 1.6,
    arcInset: 2.5,
    minSweepDegrees: 0.027 * 360,
    spinPeriod: Duration(milliseconds: 1500),
    spinStartDegrees: -90,
    smoothing: MediaArcSmoothing.eased(
      duration: Duration(milliseconds: 200),
      extraDuration: Duration(milliseconds: 450),
      extraAbove: 0.25,
    ),
    spinner: MediaSpinnerStyle(
      turn: Duration(milliseconds: 1250),
      minSweepDegrees: 90,
      maxSweepDegrees: 90,
      sweepPeriod: Duration(milliseconds: 2500),
    ),
    appearance: MediaStatusAppearance.discScaleFade,
    appearDuration: Duration(milliseconds: 200),
    disappearDuration: Duration(milliseconds: 200),
    iconMorph: MediaIconMorph.scaleFade,
    morphDuration: Duration(milliseconds: 200),
    playPauseDuration: Duration(milliseconds: 200),
    downloadCancelDuration: Duration(milliseconds: 200),
    iconSize: 0.28,
    iconStroke: 2,
  );

  /// The desktop reference: a 44 px disc of `#00000054` (`#00000074` under
  /// a hovering pointer, over 200 ms) with a 3 px white arc inset 3, at
  /// least 1°, its start turning once per 3 s; a new progress closes on the
  /// arc asymptotically. The control fades in and out over 350 ms; icons
  /// scale and fade in 200 ms.
  static const MediaStatusStyle $Desktop = MediaStatusStyle(
    diameter: 44,
    compactDiameter: 44,
    roundVideoDiameter: 44,
    compactOffset: Offset(4, 4),
    discColor: Color(0x54000000),
    discHoverColor: Color(0x74000000),
    hoverDuration: Duration(milliseconds: 200),
    arcColor: Color(0xFFFFFFFF),
    iconColor: Color(0xFFFFFFFF),
    arcStroke: 3,
    minArcStroke: 3,
    arcInset: 3,
    minSweepDegrees: 1,
    spinPeriod: Duration(milliseconds: 3000),
    spinStartDegrees: -90,
    smoothing: MediaArcSmoothing.asymptotic(Duration(milliseconds: 350)),
    spinner: MediaSpinnerStyle(
      turn: Duration(milliseconds: 1000),
      minSweepDegrees: 0.0625 * 360,
      maxSweepDegrees: 0.75 * 360,
      sweepPeriod: Duration(milliseconds: 3000),
    ),
    appearance: MediaStatusAppearance.fade,
    appearDuration: Duration(milliseconds: 350),
    disappearDuration: Duration(milliseconds: 350),
    iconMorph: MediaIconMorph.scaleFade,
    morphDuration: Duration(milliseconds: 200),
    playPauseDuration: Duration(milliseconds: 200),
    downloadCancelDuration: Duration(milliseconds: 200),
    iconSize: 0.3,
    iconStroke: 2,
  );

  /// This style with the given fields replaced.
  MediaStatusStyle copyWith({
    double? diameter,
    double? compactDiameter,
    double? roundVideoDiameter,
    Offset? compactOffset,
    Color? discColor,
    Color? discColorDark,
    Color? discHoverColor,
    Duration? hoverDuration,
    Color? arcColor,
    Color? iconColor,
    double? arcStroke,
    double? minArcStroke,
    double? arcInset,
    double? minSweepDegrees,
    Duration? spinPeriod,
    double? spinStartDegrees,
    MediaArcSmoothing? smoothing,
    MediaSpinnerStyle? spinner,
    MediaStatusAppearance? appearance,
    Duration? appearDuration,
    Duration? disappearDuration,
    MediaIconMorph? iconMorph,
    Duration? morphDuration,
    Duration? playPauseDuration,
    Duration? downloadCancelDuration,
    (double, double, double)? downloadCancelPhases,
    double? iconSize,
    double? iconStroke,
  }) => MediaStatusStyle(
    diameter: diameter ?? this.diameter,
    compactDiameter: compactDiameter ?? this.compactDiameter,
    roundVideoDiameter: roundVideoDiameter ?? this.roundVideoDiameter,
    compactOffset: compactOffset ?? this.compactOffset,
    discColor: discColor ?? this.discColor,
    discColorDark: discColorDark ?? this.discColorDark,
    discHoverColor: discHoverColor ?? this.discHoverColor,
    hoverDuration: hoverDuration ?? this.hoverDuration,
    arcColor: arcColor ?? this.arcColor,
    iconColor: iconColor ?? this.iconColor,
    arcStroke: arcStroke ?? this.arcStroke,
    minArcStroke: minArcStroke ?? this.minArcStroke,
    arcInset: arcInset ?? this.arcInset,
    minSweepDegrees: minSweepDegrees ?? this.minSweepDegrees,
    spinPeriod: spinPeriod ?? this.spinPeriod,
    spinStartDegrees: spinStartDegrees ?? this.spinStartDegrees,
    smoothing: smoothing ?? this.smoothing,
    spinner: spinner ?? this.spinner,
    appearance: appearance ?? this.appearance,
    appearDuration: appearDuration ?? this.appearDuration,
    disappearDuration: disappearDuration ?? this.disappearDuration,
    iconMorph: iconMorph ?? this.iconMorph,
    morphDuration: morphDuration ?? this.morphDuration,
    playPauseDuration: playPauseDuration ?? this.playPauseDuration,
    downloadCancelDuration:
        downloadCancelDuration ?? this.downloadCancelDuration,
    downloadCancelPhases: downloadCancelPhases ?? this.downloadCancelPhases,
    iconSize: iconSize ?? this.iconSize,
    iconStroke: iconStroke ?? this.iconStroke,
  );

  @override
  bool operator ==(Object other) =>
      other is MediaStatusStyle &&
      other.diameter == diameter &&
      other.compactDiameter == compactDiameter &&
      other.roundVideoDiameter == roundVideoDiameter &&
      other.compactOffset == compactOffset &&
      other.discColor == discColor &&
      other.discColorDark == discColorDark &&
      other.discHoverColor == discHoverColor &&
      other.hoverDuration == hoverDuration &&
      other.arcColor == arcColor &&
      other.iconColor == iconColor &&
      other.arcStroke == arcStroke &&
      other.minArcStroke == minArcStroke &&
      other.arcInset == arcInset &&
      other.minSweepDegrees == minSweepDegrees &&
      other.spinPeriod == spinPeriod &&
      other.spinStartDegrees == spinStartDegrees &&
      other.smoothing == smoothing &&
      other.spinner == spinner &&
      other.appearance == appearance &&
      other.appearDuration == appearDuration &&
      other.disappearDuration == disappearDuration &&
      other.iconMorph == iconMorph &&
      other.morphDuration == morphDuration &&
      other.playPauseDuration == playPauseDuration &&
      other.downloadCancelDuration == downloadCancelDuration &&
      other.downloadCancelPhases == downloadCancelPhases &&
      other.iconSize == iconSize &&
      other.iconStroke == iconStroke;

  @override
  int get hashCode => Object.hashAll([
    diameter,
    compactDiameter,
    roundVideoDiameter,
    compactOffset,
    discColor,
    discColorDark,
    discHoverColor,
    hoverDuration,
    arcColor,
    iconColor,
    arcStroke,
    minArcStroke,
    arcInset,
    minSweepDegrees,
    spinPeriod,
    spinStartDegrees,
    smoothing,
    spinner,
    appearance,
    appearDuration,
    disappearDuration,
    iconMorph,
    morphDuration,
    playPauseDuration,
    downloadCancelDuration,
    downloadCancelPhases,
    iconSize,
    iconStroke,
  ]);
}
