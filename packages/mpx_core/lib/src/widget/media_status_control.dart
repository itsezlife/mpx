import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/widget/media_loading_style.dart';
import 'package:mpx_core/src/widget/media_status.dart';
import 'package:mpx_core/src/widget/media_status_motion.dart';
import 'package:mpx_core/src/widget/media_status_style.dart';

/// The round control over media: a disc, a progress arc and an icon
/// (download, cancel, play, pause), or an arc turning without progress.
///
/// It draws a plain [status] ([MediaStatusControl.new]) or maps a binding's
/// download to one ([MediaStatusControl.binding]), and morphs between them
/// as the platform's style says ([MediaStatusStyle], resolved through
/// `MediaLoadingStyleScope` from the theme's platform unless [style] is
/// given): it comes in and goes, an icon turns into the next, a new
/// progress eases in, the arc turns. A status that arrives with the control
/// is shown at once.
///
/// The motion runs on the control's own ticker, which a disabled
/// [TickerMode] above stops, and which stops by itself once the control has
/// gone (status none) or holds still. A change of progress repaints the
/// control; it never rebuilds it.
class MediaStatusControl extends StatefulWidget {
  /// Shows [status]; a tap calls [onTap] while the status shows an icon.
  const MediaStatusControl({
    required MediaStatus this.status,
    this.onTap,
    this.compact = false,
    this.diameter,
    this.style,
    this.strings = const MediaStatusStrings(),
    super.key,
  }) : binding = null,
       playAction = false,
       onPlay = null,
       arcOnly = false;

  /// Shows the download of [binding] (`MediaStatus.forTransfer`): cancel and
  /// an arc while it downloads, download while it waits for the user or
  /// failed, play once its first frame shows when [playAction] is set. A tap
  /// downloads (`AssetBinding.download`), cancels
  /// (`AssetBinding.cancelDownload`) or calls [onPlay].
  ///
  /// With [arcOnly] it is a bare arc on its disc while the content downloads
  /// and has no frame, and nothing otherwise, a failure included (it offers
  /// no retry); taps do nothing.
  const MediaStatusControl.binding(
    AssetBinding this.binding, {
    this.playAction = false,
    this.onPlay,
    this.arcOnly = false,
    this.compact = false,
    this.diameter,
    this.style,
    this.strings = const MediaStatusStrings(),
    super.key,
  }) : status = null,
       onTap = null;

  /// The status shown, or null when [binding] gives it.
  final MediaStatus? status;

  /// The binding whose download is shown, or null for a plain [status].
  final AssetBinding? binding;

  /// Whether content with a first frame shows play.
  final bool playAction;

  /// Called on a tap on play or pause of a [binding]'s control.
  final VoidCallback? onPlay;

  /// Whether a [binding]'s control is a bare arc, without icon or taps.
  final bool arcOnly;

  /// Called on a tap on a plain [status] that shows an icon.
  final VoidCallback? onTap;

  /// Whether the control is the compact one (`MediaStatusStyle.compactDiameter`).
  final bool compact;

  /// The disc's diameter, or null for the style's.
  final double? diameter;

  /// The style, or null to resolve the platform's through
  /// `MediaLoadingStyleScope`.
  final MediaStatusStyle? style;

  /// What a screen reader says.
  final MediaStatusStrings strings;

  @override
  State<MediaStatusControl> createState() => _MediaStatusControlState();
}

class _MediaStatusControlState extends State<MediaStatusControl>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final _Repaint _repaint = _Repaint();
  MediaStatusMotion? _motion;
  MediaStatusStyle? _style;
  AssetBinding? _listened;
  Duration _lastTick = Duration.zero;
  bool _hovered = false;
  double _hover = 0;
  // The label last built, to rebuild only when it changes.
  String? _label;

  MediaStatus _read() {
    final binding = widget.binding;
    if (binding == null) return widget.status ?? MediaStatus.none;
    final stage = binding.readiness.stage;
    final transfer = binding.transfer;
    if (widget.arcOnly) {
      return transfer.isActive && stage.index < AssetStage.firstFrame.index
          ? MediaStatus.progress(transfer.fraction, icon: MediaStatusIcon.none)
          : MediaStatus.none;
    }
    return MediaStatus.forTransfer(
      transfer,
      stage,
      playAction: widget.playAction,
    );
  }

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restyle();
  }

  @override
  void didUpdateWidget(MediaStatusControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) _listen();
    _restyle();
    _retarget(rebuild: false);
  }

  void _restyle() {
    final style =
        widget.style ?? MediaLoadingStyleScope.resolve(context).status;
    _style = style;
    final motion = _motion;
    if (motion == null) {
      _motion = MediaStatusMotion(_read(), style);
      _label = widget.strings.labelOf(_motion!.target);
      _sync();
    } else {
      motion.style = style;
    }
  }

  void _listen() {
    _listened?.removeListener(_bindingChanged);
    _listened = widget.binding?..addListener(_bindingChanged);
  }

  void _bindingChanged() {
    if (!mounted) return;
    _retarget();
  }

  // A widget update builds anyway; a binding's change rebuilds only when the
  // label (and with it the taps) changes, so progress only repaints.
  void _retarget({bool rebuild = true}) {
    final motion = _motion;
    if (motion == null) return;
    motion.retarget(_read());
    final label = widget.strings.labelOf(motion.target);
    if (label != _label) {
      if (rebuild) {
        setState(() => _label = label);
      } else {
        _label = label;
      }
    }
    _sync();
  }

  // Runs the ticker while the motion or the hover moves; repaints.
  void _sync() {
    final moving =
        (_motion?.isAnimating ?? false) || _hover != (_hovered ? 1 : 0);
    if (moving && !_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!moving && _ticker.isActive) {
      _ticker.stop();
    }
    _repaint.changed();
  }

  void _onTick(Duration elapsed) {
    final dt = elapsed - _lastTick;
    _lastTick = elapsed;
    _motion?.advance(dt);
    final hoverLength = _style?.hoverDuration ?? Duration.zero;
    final goal = _hovered ? 1.0 : 0.0;
    if (_hover != goal) {
      final step = hoverLength <= Duration.zero
          ? 1.0
          : dt.inMicroseconds / hoverLength.inMicroseconds;
      _hover = goal > _hover
          ? math.min(goal, _hover + step)
          : math.max(goal, _hover - step);
    }
    _sync();
  }

  void _onTap() {
    final status = _motion?.target ?? MediaStatus.none;
    final binding = widget.binding;
    if (binding == null) {
      if (status.icon != MediaStatusIcon.none) widget.onTap?.call();
      return;
    }
    if (widget.arcOnly) return;
    switch (status.icon) {
      case MediaStatusIcon.download:
        binding.download();
      case MediaStatusIcon.cancel:
        binding.cancelDownload();
      case MediaStatusIcon.play || MediaStatusIcon.pause:
        widget.onPlay?.call();
      case MediaStatusIcon.none:
        break;
    }
  }

  @override
  void dispose() {
    _listened?.removeListener(_bindingChanged);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = _style!;
    final diameter =
        widget.diameter ??
        (widget.compact ? style.compactDiameter : style.diameter);
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget control = SizedBox.square(
      dimension: diameter,
      child: CustomPaint(
        painter: _StatusPainter(
          motion: _motion!,
          repaint: _repaint,
          hover: () => _hover,
          disc: dark ? style.discColorDark ?? style.discColor : style.discColor,
        ),
      ),
    );
    final tappable =
        _label != null && !widget.arcOnly && _motion!.target.isVisible;
    if (tappable) {
      control = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onTap,
        child: control,
      );
    }
    if (style.discHoverColor != null) {
      control = MouseRegion(
        onEnter: (_) {
          _hovered = true;
          _sync();
        },
        onExit: (_) {
          _hovered = false;
          _sync();
        },
        child: control,
      );
    }
    final label = _label;
    if (label != null) {
      control = Semantics(button: tappable, label: label, child: control);
    }
    // Sized by its style, never by the box it is put in: tight constraints
    // (a large tile) centre the disc instead of stretching it.
    return Align(widthFactor: 1, heightFactor: 1, child: control);
  }
}

final class _Repaint extends ChangeNotifier {
  void changed() => notifyListeners();
}

class _StatusPainter extends CustomPainter {
  _StatusPainter({
    required this.motion,
    required this.hover,
    required this.disc,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final MediaStatusMotion motion;
  final double Function() hover;
  final Color disc;

  @override
  void paint(Canvas canvas, Size size) {
    final visibility = motion.visibility;
    if (visibility <= 0) return;
    final style = motion.style;
    final center = size.center(Offset.zero);
    final diameter = size.shortestSide;
    var opacity = 1.0;
    var discScale = 1.0;
    canvas.save();
    switch (style.appearance) {
      case MediaStatusAppearance.scale:
        canvas
          ..translate(center.dx, center.dy)
          ..scale(visibility)
          ..translate(-center.dx, -center.dy);
      case MediaStatusAppearance.discScaleFade:
        opacity = visibility;
        discScale = 0.01 + 0.99 * visibility;
      case MediaStatusAppearance.fade:
        opacity = visibility;
    }
    final hovered = style.discHoverColor;
    final discColor = hovered == null
        ? disc
        : Color.lerp(disc, hovered, hover())!;
    canvas.drawCircle(
      center,
      diameter / 2 * discScale,
      Paint()..color = _faded(discColor, opacity),
    );
    if (motion.arc case final arc?) {
      final stroke = style.arcStrokeAt(diameter);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: diameter / 2 - style.arcInset),
        arc.startDegrees * math.pi / 180,
        arc.sweepDegrees * math.pi / 180,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke
          ..color = _faded(style.arcColor, opacity),
      );
    }
    final iconSize = diameter * style.iconSize;
    final stroke = math.max(1.3, style.iconStroke * diameter / style.diameter);
    for (final layer in motion.icons) {
      if (layer.scale <= 0 || layer.opacity <= 0) continue;
      canvas
        ..save()
        ..translate(center.dx, center.dy)
        ..rotate(layer.turnDegrees * math.pi / 180)
        ..scale(layer.scale);
      _paintIcon(
        canvas,
        layer.icon,
        iconSize,
        stroke,
        _faded(style.iconColor, opacity * layer.opacity),
      );
      canvas.restore();
    }
    canvas.restore();
  }

  static void _paintIcon(
    Canvas canvas,
    MediaStatusIcon icon,
    double size,
    double stroke,
    Color color,
  ) {
    final half = size / 2;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = stroke
      ..color = color;
    final fill = Paint()..color = color;
    switch (icon) {
      case MediaStatusIcon.download:
        canvas
          ..drawLine(Offset(0, -half), Offset(0, half), line)
          ..drawPath(
            Path()
              ..moveTo(-half * 0.8, half * 0.15)
              ..lineTo(0, half)
              ..lineTo(half * 0.8, half * 0.15),
            line,
          );
      case MediaStatusIcon.cancel:
        final r = half * 0.8;
        canvas
          ..drawLine(Offset(-r, -r), Offset(r, r), line)
          ..drawLine(Offset(r, -r), Offset(-r, r), line);
      case MediaStatusIcon.play:
        canvas.drawPath(
          Path()
            ..moveTo(-half * 0.6, -half)
            ..lineTo(half, 0)
            ..lineTo(-half * 0.6, half)
            ..close(),
          fill,
        );
      case MediaStatusIcon.pause:
        final bar = size * 0.28;
        canvas
          ..drawRect(Rect.fromLTWH(-half * 0.8, -half, bar, size), fill)
          ..drawRect(Rect.fromLTWH(half * 0.8 - bar, -half, bar, size), fill);
      case MediaStatusIcon.none:
        break;
    }
  }

  static Color _faded(Color color, double opacity) => opacity >= 1
      ? color
      : color.withValues(alpha: color.a * opacity.clamp(0.0, 1.0));

  @override
  bool shouldRepaint(_StatusPainter oldDelegate) =>
      !identical(oldDelegate.motion, motion) || oldDelegate.disc != disc;
}
