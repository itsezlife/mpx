import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mpx_example/social/src/common/theme/app_theme.dart';

/// Hearts that burst where a double tap landed and fade away upward, as a
/// reel's like does. Hold the state with a key and call [ReelHeartsState.burst]
/// with the touch's position in this widget's own coordinates.
///
/// It takes no touches: it sits over the video and the gestures of the page
/// under it keep working.
class ReelHearts extends StatefulWidget {
  const ReelHearts({super.key});

  @override
  State<ReelHearts> createState() => ReelHeartsState();
}

class ReelHeartsState extends State<ReelHearts> {
  final List<_Burst> _bursts = [];
  final math.Random _random = math.Random();
  int _next = 0;

  /// Bursts one heart at [position].
  void burst(Offset position) {
    setState(
      () => _bursts.add(
        _Burst(
          id: _next++,
          position: position,
          // A little tilt each time, so a run of taps is not a column.
          tilt: (_random.nextDouble() - 0.5) * math.pi / 6,
        ),
      ),
    );
  }

  void _done(_Burst burst) {
    if (mounted) setState(() => _bursts.remove(burst));
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        for (final burst in _bursts)
          _BurstView(
            key: ValueKey(burst.id),
            burst: burst,
            onDone: () => _done(burst),
          ),
      ],
    ),
  );
}

class _Burst {
  const _Burst({required this.id, required this.position, required this.tilt});

  final int id;
  final Offset position;
  final double tilt;
}

class _BurstView extends StatefulWidget {
  const _BurstView({required this.burst, required this.onDone, super.key});

  final _Burst burst;
  final VoidCallback onDone;

  @override
  State<_BurstView> createState() => _BurstViewState();
}

class _BurstViewState extends State<_BurstView>
    with SingleTickerProviderStateMixin {
  static const double _size = 96;

  late final AnimationController _controller =
      AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 800),
        )
        ..addStatusListener((status) {
          if (status == AnimationStatus.completed) widget.onDone();
        })
        ..forward();

  // Pops in with an overshoot in the first fifth, holds, then rises and fades.
  static final Animatable<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.3,
        end: 1.25,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 20,
    ),
    TweenSequenceItem(tween: Tween(begin: 1.25, end: 1), weight: 10),
    TweenSequenceItem(tween: ConstantTween(1), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.15), weight: 30),
  ]);
  static final Animatable<double> _opacity = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 10),
    TweenSequenceItem(tween: ConstantTween(1), weight: 55),
    TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 35),
  ]);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colors.like;
    final position = widget.burst.position;
    return Positioned(
      left: position.dx - _size / 2,
      top: position.dy - _size / 2,
      width: _size,
      height: _size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) => Opacity(
          opacity: _opacity.evaluate(_controller),
          child: Transform.translate(
            offset: Offset(0, -80 * Curves.easeIn.transform(_controller.value)),
            child: Transform.rotate(
              angle: widget.burst.tilt,
              child: Transform.scale(
                scale: _scale.evaluate(_controller),
                child: child,
              ),
            ),
          ),
        ),
        child: FilledHeart(size: _size, color: color),
      ),
    );
  }
}

/// A filled heart. Lucide draws outlines only, and a liked heart is filled.
class FilledHeart extends StatelessWidget {
  const FilledHeart({required this.size, required this.color, super.key});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _HeartPainter(color));
}

class _HeartPainter extends CustomPainter {
  const _HeartPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final path = Path()
      ..moveTo(w / 2, h * 0.92)
      ..cubicTo(-w * 0.12, h * 0.56, w * 0.08, h * 0.04, w / 2, h * 0.32)
      ..cubicTo(w * 0.92, h * 0.04, w * 1.12, h * 0.56, w / 2, h * 0.92)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_HeartPainter oldDelegate) => oldDelegate.color != color;
}
