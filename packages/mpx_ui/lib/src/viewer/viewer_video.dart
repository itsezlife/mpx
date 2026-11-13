import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';

/// One quality of a video the host offers: a label ("720p", "Auto") and the
/// media that plays it. Choosing one moves the player to [key] at the same
/// position.
@immutable
final class ViewerQuality {
  /// Creates a quality.
  const ViewerQuality({required this.label, required this.key});

  /// What the quality list shows.
  final String label;

  /// The media of this quality.
  final MediaKey key;

  @override
  bool operator ==(Object other) =>
      other is ViewerQuality && other.label == label && other.key == key;

  @override
  int get hashCode => Object.hash(label, key);
}

/// Gives the frame of [key] at [position] for the seek preview, or null when
/// there is none (no storyboard, not decoded yet).
typedef ViewerPreviewFrame =
    Future<ui.Image?> Function(MediaKey key, Duration position);

/// The playback speeds chosen in viewers, kept as the policy's
/// [ViewerSpeedMemory] says: per item, for one viewer, or for the session.
///
/// A viewer makes its own when the host passes none; a host that wants the
/// session-wide speed to outlive one viewer keeps one instance and passes it
/// to every viewer.
final class ViewerSpeeds {
  final Map<MediaKey, double> _perItem = {};
  double _shared = 1;
  double _global = 1;

  /// The speed [key] starts at under [memory].
  double speedFor(MediaKey key, ViewerSpeedMemory memory) => switch (memory) {
    ViewerSpeedMemory.perItem => _perItem[key] ?? 1,
    ViewerSpeedMemory.shared => _shared,
    ViewerSpeedMemory.global => _global,
  };

  /// Records [speed] chosen for [key] under [memory].
  void remember(MediaKey key, double speed, ViewerSpeedMemory memory) {
    switch (memory) {
      case ViewerSpeedMemory.perItem:
        if (speed == 1) {
          _perItem.remove(key);
        } else {
          _perItem[key] = speed;
        }
      case ViewerSpeedMemory.shared:
        _shared = speed;
      case ViewerSpeedMemory.global:
        _global = speed;
    }
  }

  /// Starts a viewer: the speed shared by its items starts at normal again.
  void beginViewer() => _shared = 1;
}

/// The texts of the video controls.
@immutable
final class ViewerVideoStrings {
  /// Creates strings; the defaults are English.
  const ViewerVideoStrings({
    this.play = 'Play',
    this.pause = 'Pause',
    this.speed = 'Speed',
    this.quality = 'Quality',
  });

  /// The play button's semantic label.
  final String play;

  /// The pause button's semantic label.
  final String pause;

  /// The speed button's semantic label.
  final String speed;

  /// The quality button's semantic label.
  final String quality;
}

/// The controls over a video in the viewer: the play button in the middle,
/// and at the bottom the seek bar, the time, the speed and the quality.
///
/// Dragging the seek bar moves a preview (the time and, with
/// [previewFrame], the frame there); the seek happens on release. Every
/// touch is reported to [onInteraction], so the viewer restarts its
/// auto-hide.
class ViewerVideoControls extends StatefulWidget {
  /// Creates the controls of [lease].
  const ViewerVideoControls({
    required this.lease,
    required this.rules,
    required this.tokens,
    required this.visible,
    required this.showDuration,
    required this.hideDuration,
    required this.onInteraction,
    required this.onSpeed,
    super.key,
    this.slide = 0,
    this.qualities = const [],
    this.quality,
    this.onQuality,
    this.previewFrame,
    this.strings = const ViewerVideoStrings(),
  });

  /// The player.
  final PlayerLease lease;

  /// The policy's video rules: speeds and seek preview.
  final ViewerVideoRules rules;

  /// Colours and type.
  final ViewerTokens tokens;

  /// Whether the controls show.
  final bool visible;

  /// How long the controls take to show.
  final Duration showDuration;

  /// How long the controls take to hide.
  final Duration hideDuration;

  /// How far the bottom bar slides down as it hides.
  final double slide;

  /// Any touch on the controls.
  final VoidCallback onInteraction;

  /// A speed was chosen.
  final ValueChanged<double> onSpeed;

  /// The qualities offered; no quality button when there are fewer than
  /// two.
  final List<ViewerQuality> qualities;

  /// The quality playing.
  final ViewerQuality? quality;

  /// A quality was chosen.
  final ValueChanged<ViewerQuality>? onQuality;

  /// The seek preview's frames; the preview shows the time only when null.
  final ViewerPreviewFrame? previewFrame;

  /// The texts.
  final ViewerVideoStrings strings;

  /// The height of the bottom bar.
  static const double barHeight = 48;

  /// The diameter of the play button.
  static const double playButtonSize = 64;

  @override
  State<ViewerVideoControls> createState() => ViewerVideoControlsState();
}

enum _Panel { none, speed, quality }

/// The state of [ViewerVideoControls]; the preview position is readable for
/// tests.
class ViewerVideoControlsState extends State<ViewerVideoControls>
    with SingleTickerProviderStateMixin {
  // The playhead is read every frame, never pushed (the player's rule).
  late final Ticker _ticker = createTicker((_) => _readPlayhead());
  final ValueNotifier<Duration> _playhead = ValueNotifier(Duration.zero);
  Duration? _preview;
  ui.Image? _previewImage;
  int _previewRequest = 0;
  _Panel _panel = _Panel.none;

  /// Where a seek-bar drag would seek; null while none is in progress.
  Duration? get preview => _preview;

  @override
  void initState() {
    super.initState();
    widget.lease.state.addListener(_onState);
    _onState();
  }

  @override
  void didUpdateWidget(ViewerVideoControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lease, widget.lease)) {
      oldWidget.lease.state.removeListener(_onState);
      widget.lease.state.addListener(_onState);
      _onState();
    }
    if (!widget.visible && _panel != _Panel.none) _panel = _Panel.none;
  }

  @override
  void dispose() {
    widget.lease.state.removeListener(_onState);
    _ticker.dispose();
    _playhead.dispose();
    _previewImage?.dispose();
    super.dispose();
  }

  void _onState() {
    if (!mounted) return;
    final playing = widget.lease.state.value.playing;
    if (playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
    _readPlayhead();
    setState(() {});
  }

  void _readPlayhead() => _playhead.value = widget.lease.position;

  void _togglePlay() {
    widget.onInteraction();
    final lease = widget.lease;
    if (lease.state.value.playing) {
      lease.pause();
    } else {
      lease.play();
    }
  }

  // --- Seek -----------------------------------------------------------------

  Duration _positionAt(double x, double width) {
    final duration = widget.lease.state.value.duration ?? Duration.zero;
    final fraction = width <= 0 ? 0.0 : (x / width).clamp(0.0, 1.0);
    return duration * fraction;
  }

  void _previewAt(double x, double width) {
    widget.onInteraction();
    final position = _positionAt(x, width);
    setState(() => _preview = position);
    final frames = widget.previewFrame;
    if (frames == null || widget.rules.seekPreviewBox == null) return;
    final request = ++_previewRequest;
    unawaited(
      frames(widget.lease.key, position).then((image) {
        if (!mounted || request != _previewRequest || _preview == null) {
          image?.dispose();
          return;
        }
        setState(() {
          _previewImage?.dispose();
          _previewImage = image;
        });
      }),
    );
  }

  void _commitSeek() {
    final target = _preview;
    if (target == null) return;
    widget.lease.seekTo(target);
    _readPlayhead();
    setState(() {
      _preview = null;
      _previewRequest++;
      _previewImage?.dispose();
      _previewImage = null;
    });
    widget.onInteraction();
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = widget.lease.state.value;
    final tokens = widget.tokens;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return IgnorePointer(
      ignoring: !widget.visible,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: widget.visible ? 1 : 0),
        duration: widget.visible ? widget.showDuration : widget.hideDuration,
        builder: (context, t, child) =>
            Opacity(opacity: t.clamp(0.0, 1.0), child: child),
        child: Stack(
          children: [
            Center(
              child: _RoundButton(
                key: const ValueKey('mpx-viewer-play'),
                label: state.playing
                    ? widget.strings.pause
                    : widget.strings.play,
                size: ViewerVideoControls.playButtonSize,
                fill: tokens.barFill,
                onTap: _togglePlay,
                child: CustomPaint(
                  size: const Size.square(24),
                  painter: _PlayGlyph(
                    tokens.foreground,
                    paused: !state.playing,
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: bottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_preview case final preview?) _previewBox(preview),
                  if (_panel == _Panel.speed) _speedPanel(state.speed),
                  if (_panel == _Panel.quality) _qualityPanel(),
                  _bar(state),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bar(PlayerState state) {
    final tokens = widget.tokens;
    final duration = state.duration ?? Duration.zero;
    return ColoredBox(
      key: const ValueKey('mpx-viewer-video-bar'),
      color: tokens.barFill,
      child: SizedBox(
        height: ViewerVideoControls.barHeight,
        child: Row(
          children: [
            const SizedBox(width: 14),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return GestureDetector(
                    key: const ValueKey('mpx-viewer-seek-bar'),
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) =>
                        _previewAt(d.localPosition.dx, width),
                    onHorizontalDragUpdate: (d) =>
                        _previewAt(d.localPosition.dx, width),
                    onHorizontalDragEnd: (_) => _commitSeek(),
                    onTapDown: (d) => _previewAt(d.localPosition.dx, width),
                    onTapUp: (_) => _commitSeek(),
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: _playhead,
                      builder: (context, playhead, _) => CustomPaint(
                        size: Size(width, ViewerVideoControls.barHeight),
                        painter: _SeekBarPainter(
                          duration: duration,
                          position: _preview ?? playhead,
                          buffered: state.buffered,
                          foreground: tokens.foreground,
                          dragging: _preview != null,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<Duration>(
              valueListenable: _playhead,
              builder: (context, playhead, _) => Text(
                '${formatViewerTime(_preview ?? playhead)} / '
                '${formatViewerTime(duration)}',
                key: const ValueKey('mpx-viewer-time'),
                style: tokens.subtitle,
              ),
            ),
            _textButton(
              key: const ValueKey('mpx-viewer-speed'),
              label: widget.strings.speed,
              text: '${_speedText(state.speed)}x',
              onTap: () => _toggle(_Panel.speed),
            ),
            if (widget.qualities.length > 1)
              _textButton(
                key: const ValueKey('mpx-viewer-quality'),
                label: widget.strings.quality,
                text: widget.quality?.label ?? widget.qualities.first.label,
                onTap: () => _toggle(_Panel.quality),
              ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  void _toggle(_Panel panel) {
    widget.onInteraction();
    setState(() => _panel = _panel == panel ? _Panel.none : panel);
  }

  Widget _textButton({
    required Key key,
    required String label,
    required String text,
    required VoidCallback onTap,
  }) => Semantics(
    key: key,
    button: true,
    label: label,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Center(child: Text(text, style: widget.tokens.subtitle)),
      ),
    ),
  );

  static String _speedText(double speed) => speed == speed.roundToDouble()
      ? speed.toStringAsFixed(0)
      : speed.toStringAsFixed(1);

  Widget _previewBox(Duration position) {
    final box = widget.rules.seekPreviewBox;
    final image = _previewImage;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        key: const ValueKey('mpx-viewer-seek-preview'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (box != null && image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox.fromSize(
                size: _fit(Size(image.width / 1, image.height / 1), box),
                child: RawImage(image: image, fit: BoxFit.contain),
              ),
            ),
          Text(formatViewerTime(position), style: widget.tokens.subtitle),
        ],
      ),
    );
  }

  static Size _fit(Size size, Size box) {
    if (size.isEmpty) return box;
    final scale = math.min(box.width / size.width, box.height / size.height);
    return size * scale;
  }

  Widget _speedPanel(double speed) {
    final rule = widget.rules.speed;
    return ColoredBox(
      key: const ValueKey('mpx-viewer-speed-panel'),
      color: widget.tokens.menuBackground,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                void at(double x) {
                  final fraction = (x / width).clamp(0.0, 1.0);
                  widget.onSpeed(
                    rule.settle(rule.min + (rule.max - rule.min) * fraction),
                  );
                }

                return GestureDetector(
                  key: const ValueKey('mpx-viewer-speed-slider'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (d) => at(d.localPosition.dx),
                  onTapUp: (d) => at(d.localPosition.dx),
                  child: CustomPaint(
                    size: Size(width, 44),
                    painter: _SeekBarPainter(
                      duration: const Duration(seconds: 1),
                      position:
                          const Duration(seconds: 1) *
                          ((speed - rule.min) / (rule.max - rule.min)).clamp(
                            0.0,
                            1.0,
                          ),
                      buffered: const [],
                      foreground: widget.tokens.menuForeground,
                      dragging: false,
                    ),
                  ),
                );
              },
            ),
            Wrap(
              spacing: 8,
              children: [
                for (final preset in rule.presets)
                  GestureDetector(
                    key: ValueKey(('mpx-viewer-speed-preset', preset)),
                    onTap: () => widget.onSpeed(preset),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '${_speedText(preset)}x',
                        style: widget.tokens.subtitle.copyWith(
                          color: preset == speed
                              ? widget.tokens.link
                              : widget.tokens.menuForeground,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _qualityPanel() => ColoredBox(
    key: const ValueKey('mpx-viewer-quality-panel'),
    color: widget.tokens.menuBackground,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final quality in widget.qualities)
          GestureDetector(
            key: ValueKey(('mpx-viewer-quality-item', quality.label)),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              setState(() => _panel = _Panel.none);
              widget.onInteraction();
              widget.onQuality?.call(quality);
            },
            child: SizedBox(
              height: 44,
              child: Center(
                child: Text(
                  quality.label,
                  style: widget.tokens.subtitle.copyWith(
                    color: quality == widget.quality
                        ? widget.tokens.link
                        : widget.tokens.menuForeground,
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// [position] as m:ss, or h:mm:ss from an hour on.
String formatViewerTime(Duration position) {
  final total = position.inSeconds;
  final hours = total ~/ 3600;
  final minutes = (total ~/ 60) % 60;
  final seconds = (total % 60).toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${minutes.toString().padLeft(2, '0')}:$seconds'
      : '$minutes:$seconds';
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.label,
    required this.size,
    required this.fill,
    required this.onTap,
    required this.child,
    super.key,
  });

  final String label;
  final double size;
  final Color fill;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
        alignment: Alignment.center,
        child: child,
      ),
    ),
  );
}

class _PlayGlyph extends CustomPainter {
  const _PlayGlyph(this.color, {required this.paused});

  final Color color;
  final bool paused;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = size.width;
    final h = size.height;
    if (paused) {
      canvas.drawPath(
        Path()
          ..moveTo(w * 0.25, h * 0.15)
          ..lineTo(w * 0.85, h / 2)
          ..lineTo(w * 0.25, h * 0.85)
          ..close(),
        paint,
      );
    } else {
      canvas
        ..drawRect(Rect.fromLTWH(w * 0.22, h * 0.15, w * 0.2, h * 0.7), paint)
        ..drawRect(Rect.fromLTWH(w * 0.58, h * 0.15, w * 0.2, h * 0.7), paint);
    }
  }

  @override
  bool shouldRepaint(_PlayGlyph oldDelegate) =>
      oldDelegate.color != color || oldDelegate.paused != paused;
}

// A 4 px track centred in the bar: the background, the buffered ranges and
// the progress, with a 6 px thumb that grows to 8 px while dragged.
class _SeekBarPainter extends CustomPainter {
  const _SeekBarPainter({
    required this.duration,
    required this.position,
    required this.buffered,
    required this.foreground,
    required this.dragging,
  });

  final Duration duration;
  final Duration position;
  final List<PlayerTimeRange> buffered;
  final Color foreground;
  final bool dragging;

  static const double _track = 4;
  static const double _thumb = 6;
  static const double _thumbPressed = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final faint = Paint()..color = foreground.withValues(alpha: 0.2);
    final full = Paint()..color = foreground;
    final micros = duration.inMicroseconds;
    double xOf(Duration at) => micros <= 0
        ? 0
        : size.width * (at.inMicroseconds / micros).clamp(0.0, 1.0);
    RRect bar(double from, double to) => RRect.fromRectAndRadius(
      Rect.fromLTRB(from, y - _track / 2, to, y + _track / 2),
      const Radius.circular(_track / 2),
    );
    canvas.drawRRect(bar(0, size.width), faint);
    for (final range in buffered) {
      canvas.drawRRect(bar(xOf(range.start), xOf(range.end)), faint);
    }
    final x = xOf(position);
    canvas
      ..drawRRect(bar(0, x), full)
      ..drawCircle(Offset(x, y), dragging ? _thumbPressed : _thumb, full);
  }

  @override
  bool shouldRepaint(_SeekBarPainter oldDelegate) =>
      oldDelegate.duration != duration ||
      oldDelegate.position != position ||
      !listEquals(oldDelegate.buffered, buffered) ||
      oldDelegate.foreground != foreground ||
      oldDelegate.dragging != dragging;
}
