import 'dart:math' as math;

import 'package:flutter/widgets.dart';

// Controls of the capture surface that one policy shows and the other does
// not. Internal to the package: the surface builds them.

/// The accent of the selected mode and lens.
const Color captureAccent = Color(0xFFF8D74A);

/// The recording red.
const Color captureRed = Color(0xFFFE3B30);

/// A Video / Photo mode control: the selected mode centred, bold in the
/// accent, the other regular white; 14 px with 0.75 letter spacing. A tap
/// on a mode or a horizontal swipe switches, sliding over 300 ms.
class CaptureModeControl extends StatelessWidget {
  /// Creates the control.
  const CaptureModeControl({
    required this.video,
    required this.photo,
    required this.videoMode,
    required this.onVideoMode,
    super.key,
  });

  /// The video mode's name.
  final String video;

  /// The photo mode's name.
  final String photo;

  /// Whether video is the mode.
  final bool videoMode;

  /// Called with the mode chosen.
  final ValueChanged<bool> onVideoMode;

  static const double _gap = 20;

  TextStyle _style(bool selected) => TextStyle(
    color: selected ? captureAccent : const Color(0xFFFFFFFF),
    fontSize: 14,
    letterSpacing: 0.75,
    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
    decoration: TextDecoration.none,
  );

  double _width(String text, bool selected, TextDirection direction) =>
      (TextPainter(
        text: TextSpan(text: text, style: _style(selected)),
        textDirection: direction,
      )..layout()).width;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final videoWidth = _width(video, true, direction);
    final photoWidth = _width(photo, true, direction);
    // The row's offset that centres the selected mode.
    final shift = videoMode
        ? (photoWidth + _gap) / 2
        : -(videoWidth + _gap) / 2;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < 0 && videoMode) onVideoMode(false);
        if (v > 0 && !videoMode) onVideoMode(true);
      },
      child: SizedBox(
        height: 32,
        child: Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: shift),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            builder: (context, dx, child) =>
                Transform.translate(offset: Offset(dx, 0), child: child),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              textDirection: TextDirection.ltr,
              children: [
                GestureDetector(
                  key: const ValueKey('mpx-capture-mode-video'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onVideoMode(true),
                  child: Text(video, style: _style(videoMode)),
                ),
                const SizedBox(width: _gap),
                GestureDetector(
                  key: const ValueKey('mpx-capture-mode-photo'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onVideoMode(false),
                  child: Text(photo, style: _style(!videoMode)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The text of a lens button: `0.5`, `1`, `2`, or the factor in tenths
/// when the zoom sits between lenses; the selected one ends with `×`.
String lensLabel(double factor, {required bool selected}) {
  String tenths(double f) {
    final text = f.toStringAsFixed(1);
    return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
  }

  final text = factor == factor.roundToDouble() && factor >= 1
      ? '${factor.round()}'
      : tenths(factor);
  return selected ? '$text×' : text;
}

/// The lens buttons: a pill 43 high of 43-wide buttons, each a 37 circle at
/// 40 % black, the lens at or below the zoom selected (its label the
/// current factor, in the accent), the others shrunk to 0.7 (labels to
/// 0.85) over 300 ms. A tap goes to a lens; a horizontal drag zooms by
/// −dx / 60 (3.5 times that above 2×), catching on a lens it passes within
/// 0.05 until the finger moves 8 more.
class CaptureLensPill extends StatefulWidget {
  /// Creates the pill.
  const CaptureLensPill({
    required this.lenses,
    required this.factor,
    required this.minFactor,
    required this.maxFactor,
    required this.onLens,
    required this.onFactor,
    super.key,
  });

  /// The lens factors, ascending.
  final List<double> lenses;

  /// The zoom now.
  final double factor;

  /// The widest factor.
  final double minFactor;

  /// The longest factor.
  final double maxFactor;

  /// Called with a lens tapped.
  final ValueChanged<double> onLens;

  /// Called with each factor of a drag.
  final ValueChanged<double> onFactor;

  /// The selected lens's index for [factor].
  static int selectedOf(List<double> lenses, double factor) {
    var selected = 0;
    for (var i = 0; i < lenses.length; i++) {
      if ((lenses[i] - factor).abs() < 0.025) return i;
      if (factor >= lenses[i]) selected = i;
    }
    return selected;
  }

  @override
  State<CaptureLensPill> createState() => _CaptureLensPillState();
}

class _CaptureLensPillState extends State<CaptureLensPill> {
  static const double _item = 43;

  double? _level;
  bool _locked = false;
  double _held = 0;

  void _start(DragStartDetails _) {
    _level = widget.factor;
    _locked = false;
    _held = 0;
  }

  void _update(DragUpdateDetails details) {
    final level = _level;
    if (level == null) return;
    final dx = details.delta.dx;
    if (_locked) {
      _held += dx;
      if (_held.abs() <= 8) return;
      _locked = false;
      final next = (level + (_held > 0 ? -0.06 : 0.06)).clamp(
        widget.minFactor,
        widget.maxFactor,
      );
      _level = next;
      widget.onFactor(next);
      return;
    }
    var delta = -dx / 60;
    if (level > 2) delta *= 3.5;
    var next = (level + delta).clamp(widget.minFactor, widget.maxFactor);
    for (final lens in widget.lenses) {
      if ((next - lens).abs() < 0.05 && level != lens) {
        next = lens;
        _locked = true;
        _held = 0;
        break;
      }
    }
    _level = next;
    widget.onFactor(next);
  }

  @override
  Widget build(BuildContext context) {
    final lenses = widget.lenses;
    final selected = CaptureLensPill.selectedOf(lenses, widget.factor);
    final atLens = (lenses[selected] - widget.factor).abs() < 0.025;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: _start,
      onHorizontalDragUpdate: _update,
      onHorizontalDragEnd: (_) => _level = null,
      child: Container(
        height: _item,
        width: _item * lenses.length,
        decoration: BoxDecoration(
          color: const Color(0x26000000),
          borderRadius: BorderRadius.circular(_item / 2),
        ),
        child: Row(
          textDirection: TextDirection.ltr,
          children: [
            for (final (i, lens) in lenses.indexed)
              GestureDetector(
                key: ValueKey(('mpx-capture-lens', lens)),
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onLens(lens),
                child: SizedBox.square(
                  dimension: _item,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      AnimatedScale(
                        scale: i == selected ? 1 : 0.7,
                        duration: const Duration(milliseconds: 300),
                        child: const SizedBox.square(
                          dimension: 37,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Color(0x66000000),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                      AnimatedScale(
                        scale: i == selected ? 1 : 0.85,
                        duration: const Duration(milliseconds: 300),
                        child: Text(
                          lensLabel(
                            i == selected && !atLens
                                ? math.min(
                                    widget.factor,
                                    i + 1 < lenses.length
                                        ? lenses[i + 1] - 0.1
                                        : widget.factor,
                                  )
                                : lens,
                            selected: i == selected,
                          ),
                          style: TextStyle(
                            color: i == selected
                                ? captureAccent
                                : const Color(0xFFFFFFFF),
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The recording time in a red rounded box: `MM:SS`, `HH:MM:SS` past an
/// hour.
class CaptureRedTimer extends StatelessWidget {
  /// Shows [seconds].
  const CaptureRedTimer({required this.seconds, super.key});

  /// The seconds recorded.
  final int seconds;

  /// The text of [seconds].
  static String clock(int seconds) {
    String two(int n) => n.toString().padLeft(2, '0');
    final hours = seconds ~/ 3600;
    final rest = '${two(seconds ~/ 60 % 60)}:${two(seconds % 60)}';
    return hours > 0 ? '${two(hours)}:$rest' : rest;
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: captureRed,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      clock(seconds),
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 15,
        fontFeatures: [FontFeature.tabularFigures()],
        decoration: TextDecoration.none,
      ),
    ),
  );
}

/// The focus crosshair: a 75 square in the accent, scaled from 2 to 1 over
/// 150 ms; with [exposure] shown, a sun handle 5 to its right on a 144 track
/// whose place follows the exposure (up is brighter).
class CaptureCrosshairPainter extends CustomPainter {
  /// Paints the crosshair at [appear] (0..1 of its scale-in), at
  /// [opacity], with the exposure handle when [exposure] is non-null.
  const CaptureCrosshairPainter({
    required this.appear,
    required this.opacity,
    required this.exposure,
    required this.track,
  });

  /// 0..1 of the 150 ms scale-in.
  final double appear;

  /// The crosshair's opacity (it dims to 0.5 when idle).
  final double opacity;

  /// The exposure, -1..1, or null to hide the handle.
  final double? exposure;

  /// Whether the exposure track's lines show (while it is dragged).
  final bool track;

  /// The crosshair's side.
  static const double side = 75;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final scale = 2 - Curves.easeOut.transform(appear);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = captureAccent.withValues(alpha: opacity);
    final half = side / 2 * scale;
    canvas.drawRect(
      Rect.fromCenter(center: c, width: 2 * half, height: 2 * half),
      paint,
    );
    // Short ticks at each side's middle.
    for (final (dx, dy) in [(0.0, -1.0), (0.0, 1.0), (-1.0, 0.0), (1.0, 0.0)]) {
      final edge = c + Offset(dx * half, dy * half);
      canvas.drawLine(edge, edge - Offset(dx * 5, dy * 5), paint);
    }
    final value = exposure;
    if (value == null) return;
    final x = c.dx + side / 2 + 5 + 12.5;
    // Up is brighter: the handle sits above the middle for a positive value.
    final y = c.dy - value * (144 - 25) / 2;
    if (track) {
      final line = Paint()
        ..color = captureAccent.withValues(alpha: opacity)
        ..strokeWidth = 1;
      canvas
        ..drawLine(Offset(x, c.dy - 72), Offset(x, y - 15.5), line)
        ..drawLine(Offset(x, y + 15.5), Offset(x, c.dy + 72), line);
    }
    final sun = Paint()
      ..color = captureAccent.withValues(alpha: opacity)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(Offset(x, y), 5, sun);
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(Offset(x, y) + d * 8, Offset(x, y) + d * 11, sun);
    }
  }

  @override
  bool shouldRepaint(CaptureCrosshairPainter oldDelegate) =>
      oldDelegate.appear != appear ||
      oldDelegate.opacity != opacity ||
      oldDelegate.exposure != exposure ||
      oldDelegate.track != track;
}

/// The square-style shutter: a white ring 4 thick round a disc 6 in, white
/// for photos and red for videos; while recording the disc turns into a red
/// rounded square (radius 4) 23 in from the edge. [recording] runs 0..1
/// between the two.
class CaptureSquareShutterPainter extends CustomPainter {
  /// Paints the shutter.
  const CaptureSquareShutterPainter({
    required this.video,
    required this.recording,
    required this.enabled,
  });

  /// 0..1: white disc to red disc.
  final double video;

  /// 0..1: disc to recording square.
  final double recording;

  /// Whether it takes presses (dimmed when not).
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final w = size.shortestSide;
    final alpha = enabled ? 1.0 : 0.5;
    canvas.drawCircle(
      c,
      w / 2 - 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = const Color(0xFFFFFFFF).withValues(alpha: alpha),
    );
    final inset = 6 + (23 - 6) * recording;
    final side = w - 2 * inset;
    final discRadius = (w - 12) / 2;
    final radius = discRadius + (4 - discRadius) * recording;
    final color = Color.lerp(const Color(0xFFFFFFFF), captureRed, video)!;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: c, width: side, height: side),
        Radius.circular(radius),
      ),
      Paint()..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(CaptureSquareShutterPainter oldDelegate) =>
      oldDelegate.video != video ||
      oldDelegate.recording != recording ||
      oldDelegate.enabled != enabled;
}
