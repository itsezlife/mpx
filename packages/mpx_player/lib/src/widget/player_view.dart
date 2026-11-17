import 'package:flutter/widgets.dart';
import 'package:mpx_player/src/player/player_state.dart';
import 'package:mpx_player/src/player/player_trace.dart';
import 'package:mpx_player/src/pool/player_pool.dart';

/// Shows the picture of a leased player: its texture, turned upright and
/// fitted into the space it is given.
///
/// Until the player has rendered its first frame the view shows [standIn]
/// (the frame a bubble showed, a thumbnail), so a hand-off from another
/// surface never flashes empty. While it is mounted it counts as a view of the
/// player (`PlayerLease.attachView`), which the pool's budget releases last.
///
/// The view does not own the lease: the surface that took it releases it.
class PlayerView extends StatefulWidget {
  /// Creates a view of [lease].
  const PlayerView({
    required this.lease,
    super.key,
    this.fit = BoxFit.contain,
    this.standIn,
  });

  /// The player to show.
  final PlayerLease lease;

  /// How the picture fills the view.
  final BoxFit fit;

  /// What shows until the first frame; nothing when null.
  final Widget? standIn;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  late PlayerViewAttachment _attachment;
  // Whether this view built the texture yet: its first build is marked in
  // the timeline (the frame it goes into reaches the screen after it).
  bool _textureMarked = false;

  @override
  void initState() {
    super.initState();
    _attachment = widget.lease.attachView();
  }

  @override
  void didUpdateWidget(PlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lease, widget.lease)) {
      _attachment.detach();
      _attachment = widget.lease.attachView();
      _textureMarked = false;
    }
  }

  @override
  void dispose() {
    _attachment.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlayerState>(
    valueListenable: widget.lease.state,
    builder: (context, state, _) {
      final textureId = state.textureId;
      final size = state.videoSize;
      final standIn = widget.standIn ?? const SizedBox.shrink();
      if (textureId == null || size == null || !state.firstFrameRendered) {
        return standIn;
      }
      if (!_textureMarked) {
        _textureMarked = true;
        PlayerTrace.mark(
          'texture',
          PlayerTrace.keyId(widget.lease.key),
          'id=$textureId',
        );
      }
      Widget picture = SizedBox.fromSize(
        size: size,
        child: Texture(textureId: textureId),
      );
      if (state.quarterTurns % 4 != 0) {
        picture = RotatedBox(quarterTurns: state.quarterTurns, child: picture);
      }
      return ClipRect(
        child: FittedBox(fit: widget.fit, child: picture),
      );
    },
  );
}
