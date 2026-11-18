import 'dart:math' as math;
import 'dart:ui';

import 'package:mpx_core/src/widget/media_status_style.dart';

/// The progress arc of a status control in one frame: where it starts and
/// how far it sweeps, in degrees clockwise from three o'clock.
typedef MediaStatusArc = ({double startDegrees, double sweepDegrees});

/// The disc and the arc of a status control, drawn on a canvas: for a leaf
/// that paints its own cells (a `CustomPainter` of a grid) and draws the
/// control's look without a `MediaStatusControl` per cell.
///
/// The arcs are pure functions of the time the leaf has shown them, so a
/// painter keeps only that time: [spinnerArc] for a download whose size is
/// unknown (the style's [MediaSpinnerStyle]: one turn per `turn`, the sweep
/// swinging between its shortest and longest once per `sweepPeriod`), and
/// [progressArc] for a fraction (turning once per `spinPeriod`, never
/// shorter than `minSweepDegrees`). [paint] draws them as the control does.
/// A `MediaStatusControl` draws through the same code.
abstract final class MediaStatusPainting {
  /// The indeterminate arc of [style] after it has spun for [elapsed].
  static MediaStatusArc spinnerArc(MediaStatusStyle style, Duration elapsed) =>
      (
        startDegrees: _turned(
          style.spinStartDegrees,
          elapsed,
          style.spinner.turn,
        ),
        sweepDegrees: spinnerSweepDegrees(style.spinner, elapsed),
      );

  /// The arc of [progress] (0 to 1) under [style], [elapsed] after it showed.
  static MediaStatusArc progressArc(
    MediaStatusStyle style,
    double progress,
    Duration elapsed,
  ) => (
    startDegrees: _turned(style.spinStartDegrees, elapsed, style.spinPeriod),
    sweepDegrees: math.max(
      style.minSweepDegrees,
      360 * progress.clamp(0.0, 1.0),
    ),
  );

  /// How far the arc of [spinner] sweeps after it has spun for [spinning].
  static double spinnerSweepDegrees(
    MediaSpinnerStyle spinner,
    Duration spinning,
  ) {
    final swing = spinner.maxSweepDegrees - spinner.minSweepDegrees;
    final phase = spinner.sweepPeriod <= Duration.zero
        ? 0.0
        : _ratio(spinning, spinner.sweepPeriod) * 2 * math.pi;
    return spinner.minSweepDegrees + swing * (1 - math.cos(phase)) / 2;
  }

  /// Draws the disc of [style] around [center], [diameter] across (scaled
  /// by [discScale]), and [arc] over it, at [opacity]. [disc] replaces the
  /// style's disc colour (its dark one, a hovered one).
  static void paint(
    Canvas canvas,
    Offset center,
    double diameter,
    MediaStatusStyle style, {
    MediaStatusArc? arc,
    Color? disc,
    double opacity = 1,
    double discScale = 1,
  }) {
    canvas.drawCircle(
      center,
      diameter / 2 * discScale,
      Paint()..color = faded(disc ?? style.discColor, opacity),
    );
    if (arc == null) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: diameter / 2 - style.arcInset),
      arc.startDegrees * math.pi / 180,
      arc.sweepDegrees * math.pi / 180,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = style.arcStrokeAt(diameter)
        ..color = faded(style.arcColor, opacity),
    );
  }

  /// [color] at [opacity] of its own alpha.
  static Color faded(Color color, double opacity) => opacity >= 1
      ? color
      : color.withValues(alpha: color.a * opacity.clamp(0.0, 1.0));

  static double _turned(double from, Duration elapsed, Duration period) =>
      period <= Duration.zero
      ? from
      : (from + 360 * _ratio(elapsed, period)) % 360;

  static double _ratio(Duration part, Duration whole) =>
      part.inMicroseconds / whole.inMicroseconds;
}
