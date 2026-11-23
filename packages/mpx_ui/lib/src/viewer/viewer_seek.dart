import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_player/mpx_player.dart';

/// The playhead of one video and the seek a finger asks of it, with no
/// widget: the rules the viewer's seek bar has, for any surface that draws its
/// own ([ViewerSeekBar] is the bar the viewer draws over it).
///
/// - The playhead is read from the lease every frame while the video plays,
///   by a ticker (`PlayerLease.position` is a read, not a stream), and once
///   when it stops or is moved.
/// - A finger on the bar only moves a [preview]: where a seek would land. The
///   seek is made when the finger leaves ([commit]), so a drag costs one seek,
///   not one per touch event, and a host can draw the time (and a frame) at
///   [preview] meanwhile.
/// - The length is the player's, else [knownDuration], else none: a video
///   still downloading reads "0:00 / 0:52", not "0:00 / 0:00".
///
/// Listeners hear every change of the playhead, the preview and the player's
/// state. Call [dispose] when done.
final class ViewerSeekController extends ChangeNotifier {
  /// Follows [lease], reading its playhead on [vsync]'s frames.
  ViewerSeekController({
    required TickerProvider vsync,
    required PlayerLease lease,
    this.knownDuration,
    this.onInteraction,
  }) : _lease = lease {
    _ticker = vsync.createTicker((_) => _readPlayhead());
    _lease.state.addListener(_onState);
    _onState();
  }

  /// The length the host knows (the item's descriptor), for the time before
  /// the player reports one.
  Duration? knownDuration;

  /// Told of every touch on the bar, so the host restarts its auto-hide.
  VoidCallback? onInteraction;

  late final Ticker _ticker;
  PlayerLease _lease;
  Duration _playhead = Duration.zero;
  Duration? _preview;
  bool _disposed = false;

  /// The player.
  PlayerLease get lease => _lease;
  set lease(PlayerLease value) {
    if (identical(value, _lease)) return;
    _lease.state.removeListener(_onState);
    _lease = value;
    _lease.state.addListener(_onState);
    _preview = null;
    _onState();
  }

  /// Where the video is.
  Duration get playhead => _playhead;

  /// Where a seek would land: set while a finger is down on the bar, null
  /// otherwise.
  Duration? get preview => _preview;

  /// Whether a finger is down on the bar.
  bool get isDragging => _preview != null;

  /// What the bar shows: the preview while dragging, else the playhead.
  Duration get shown => _preview ?? _playhead;

  /// The length of the video: the player's, else the host's, else zero.
  Duration get duration => durationOf(_lease.state.value);

  /// The length of the video for [state].
  Duration durationOf(PlayerState state) =>
      state.duration ?? knownDuration ?? Duration.zero;

  void _onState() {
    if (_disposed) return;
    final playing = _lease.state.value.playing;
    if (playing && !_ticker.isActive) {
      _ticker.start();
    } else if (!playing && _ticker.isActive) {
      _ticker.stop();
    }
    _readPlayhead();
  }

  void _readPlayhead() {
    if (_disposed) return;
    _playhead = _lease.position;
    notifyListeners();
  }

  /// A finger is at [x] of a bar [width] wide: previews that position.
  void previewAt(double x, double width) {
    onInteraction?.call();
    final fraction = width <= 0 ? 0.0 : (x / width).clamp(0.0, 1.0);
    _preview = duration * fraction;
    notifyListeners();
  }

  /// The finger left: the video goes to the preview.
  void commit() {
    final target = _preview;
    if (target == null) return;
    _lease.seekTo(target);
    _readPlayhead();
    _preview = null;
    notifyListeners();
    onInteraction?.call();
  }

  /// The drag was taken away (the bar went, the system took the touch): the
  /// preview ends and the video stays where it was.
  void cancel() {
    if (_preview == null) return;
    _preview = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lease.state.removeListener(_onState);
    _ticker.dispose();
    super.dispose();
  }
}

/// How a [ViewerSeekBar] draws: the track and the thumb, in logical pixels.
@immutable
final class ViewerSeekBarStyle {
  /// Creates a style; the defaults are the viewer's bar.
  const ViewerSeekBarStyle({
    this.track = 4,
    this.trackWhileDragging = 4,
    this.thumb = 6,
    this.thumbWhileDragging = 8,
    this.alignment = 0,
    this.faintOpacity = 0.2,
  });

  /// The viewer's bar: a 4 px track centred in its height, with a 6 px thumb
  /// that grows to 8 px under a finger.
  static const ViewerSeekBarStyle standard = ViewerSeekBarStyle();

  /// The thickness of the track at rest.
  final double track;

  /// The thickness of the track under a finger.
  final double trackWhileDragging;

  /// The radius of the thumb at rest; 0 for none.
  final double thumb;

  /// The radius of the thumb under a finger; 0 for none.
  final double thumbWhileDragging;

  /// Where the track sits in the bar's height: -1 at the top, 0 in the
  /// middle, 1 at the bottom.
  final double alignment;

  /// How faint the track behind the progress, and the buffered ranges, are,
  /// of the foreground.
  final double faintOpacity;

  @override
  bool operator ==(Object other) =>
      other is ViewerSeekBarStyle &&
      other.track == track &&
      other.trackWhileDragging == trackWhileDragging &&
      other.thumb == thumb &&
      other.thumbWhileDragging == thumbWhileDragging &&
      other.alignment == alignment &&
      other.faintOpacity == faintOpacity;

  @override
  int get hashCode => Object.hash(
    track,
    trackWhileDragging,
    thumb,
    thumbWhileDragging,
    alignment,
    faintOpacity,
  );
}

/// The seek bar of a video: the track with its buffered ranges and progress,
/// dragged or tapped to seek. What it does is the [controller]'s; it draws
/// and reports where the finger is.
///
/// The bar is as wide as the space it is given and [height] tall (that is the
/// touch target; the track is drawn inside it as [style] says).
class ViewerSeekBar extends StatelessWidget {
  /// Creates the bar of [controller], drawn in [foreground].
  const ViewerSeekBar({
    required this.controller,
    required this.foreground,
    this.style = ViewerSeekBarStyle.standard,
    this.height = defaultHeight,
    super.key,
  });

  /// The height the viewer's bar has.
  static const double defaultHeight = 48;

  /// The playhead and the seek.
  final ViewerSeekController controller;

  /// The colour of the progress; the track behind it is a fainter one.
  final Color foreground;

  /// How the bar draws.
  final ViewerSeekBarStyle style;

  /// The height of the touch target.
  final double height;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (d) =>
            controller.previewAt(d.localPosition.dx, width),
        onHorizontalDragUpdate: (d) =>
            controller.previewAt(d.localPosition.dx, width),
        onHorizontalDragEnd: (_) => controller.commit(),
        onHorizontalDragCancel: controller.cancel,
        onTapDown: (d) => controller.previewAt(d.localPosition.dx, width),
        onTapUp: (_) => controller.commit(),
        onTapCancel: controller.cancel,
        child: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => CustomPaint(
            size: Size(width, height),
            painter: ViewerSeekBarPainter(
              duration: controller.duration,
              position: controller.shown,
              buffered: controller.lease.state.value.buffered,
              foreground: foreground,
              dragging: controller.isDragging,
              style: style,
            ),
          ),
        ),
      );
    },
  );
}

/// Draws a seek bar: the track behind, the buffered ranges, the progress and
/// the thumb.
class ViewerSeekBarPainter extends CustomPainter {
  /// Creates the painter of [position] in [duration].
  const ViewerSeekBarPainter({
    required this.duration,
    required this.position,
    required this.buffered,
    required this.foreground,
    required this.dragging,
    this.style = ViewerSeekBarStyle.standard,
  });

  /// The length of the video.
  final Duration duration;

  /// Where the progress ends: the playhead, or the preview under a finger.
  final Duration position;

  /// What the player has loaded.
  final List<PlayerTimeRange> buffered;

  /// The colour of the progress.
  final Color foreground;

  /// Whether a finger is on the bar.
  final bool dragging;

  /// How it draws.
  final ViewerSeekBarStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final track = dragging ? style.trackWhileDragging : style.track;
    final thumb = dragging ? style.thumbWhileDragging : style.thumb;
    // The track's centre: the middle of the bar, or pushed to an edge by the
    // room the track and the thumb leave.
    final room = (size.height - math.max(track, thumb * 2)) / 2;
    final y = size.height / 2 + style.alignment * room;
    final faint = Paint()
      ..color = foreground.withValues(alpha: style.faintOpacity);
    final full = Paint()..color = foreground;
    final micros = duration.inMicroseconds;
    double xOf(Duration at) => micros <= 0
        ? 0
        : size.width * (at.inMicroseconds / micros).clamp(0.0, 1.0);
    RRect bar(double from, double to) => RRect.fromRectAndRadius(
      Rect.fromLTRB(from, y - track / 2, to, y + track / 2),
      Radius.circular(track / 2),
    );
    canvas.drawRRect(bar(0, size.width), faint);
    for (final range in buffered) {
      canvas.drawRRect(bar(xOf(range.start), xOf(range.end)), faint);
    }
    final x = xOf(position);
    canvas.drawRRect(bar(0, x), full);
    if (thumb > 0) canvas.drawCircle(Offset(x, y), thumb, full);
  }

  @override
  bool shouldRepaint(ViewerSeekBarPainter oldDelegate) =>
      oldDelegate.duration != duration ||
      oldDelegate.position != position ||
      !listEquals(oldDelegate.buffered, buffered) ||
      oldDelegate.foreground != foreground ||
      oldDelegate.dragging != dragging ||
      oldDelegate.style != style;
}
