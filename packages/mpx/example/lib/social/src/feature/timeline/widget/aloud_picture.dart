import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_player/mpx_player.dart';

/// A clip's player drawn over the clip's own picture: the picture alone until
/// the player moves, then the player.
///
/// A cold player renders its first frame at its start, a moment before its
/// seek to where the clip is takes hold: drawn at once, that frame stands in
/// for the clip's and the tile flashes a frame of another moment. The player's
/// view is mounted from the start, transparent, so the pool counts it as a
/// view of the player.
class AloudPicture extends StatefulWidget {
  /// Draws [lease]'s player over [clip].
  const AloudPicture({required this.lease, required this.clip, super.key});

  /// The player that plays the clip aloud.
  final PlayerLease lease;

  /// The clip's own picture, drawn until the player moves.
  final Widget clip;

  @override
  State<AloudPicture> createState() => _AloudPictureState();
}

class _AloudPictureState extends State<AloudPicture>
    with SingleTickerProviderStateMixin {
  late final Ticker _watch;
  // Where the player stood when its first frame was seen; null before.
  Duration? _firstAt;
  bool _moving = false;

  @override
  void initState() {
    super.initState();
    _watch = createTicker(_check);
    _moving =
        widget.lease.state.value.firstFrameRendered &&
        widget.lease.state.value.playing &&
        widget.lease.position > Duration.zero;
    if (!_moving) _watch.start();
  }

  void _check(Duration _) {
    final state = widget.lease.state.value;
    if (!state.firstFrameRendered) return;
    // A player held paused shows the frame it stands on.
    if (!state.playing) return _show();
    final position = widget.lease.position;
    final first = _firstAt ??= position;
    if (position != first) _show();
  }

  void _show() {
    _watch.stop();
    setState(() => _moving = true);
  }

  @override
  void dispose() {
    _watch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Opacity(opacity: _moving ? 0 : 1, child: widget.clip),
      Opacity(
        opacity: _moving ? 1 : 0,
        child: PlayerView(lease: widget.lease, fit: BoxFit.cover),
      ),
    ],
  );
}
