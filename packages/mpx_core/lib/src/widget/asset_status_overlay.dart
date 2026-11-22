import 'package:flutter/widgets.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_profile.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/widget/asset_load_state.dart';
import 'package:mpx_core/src/widget/media_badge.dart';
import 'package:mpx_core/src/widget/media_loading_style.dart';
import 'package:mpx_core/src/widget/media_status.dart';
import 'package:mpx_core/src/widget/media_status_control.dart';
import 'package:mpx_core/src/widget/media_status_mode.dart';

/// The status control and the media badge of a binding's content over
/// [child], in its box: what a `AssetView` lays over its picture, for a
/// surface that paints the content through a binding of its own (an inline
/// embed, a sticker cell).
///
/// [status] places the control: centred (`MediaStatusMode.control`, the
/// round size when [round]), an arc only, or compact in the corner. A
/// streamable video that is missing and shows no frame gets play in the
/// centre, which [onPlay] handles (it streams), and the download in the
/// corner. [badge] adds the badge (the duration or "GIF", the bytes while
/// they arrive) at the top left of the picture's rounded area, beside the
/// corner control while one shows. Both follow the binding's one transfer
/// and repaint themselves; the overlay rebuilds only when their layout
/// changes. The look comes from the closest `MediaLoadingStyleScope`; a
/// [skin] (over the scope's) may replace the control and the badge, given
/// the binding's [AssetLoadState] and the stock widget.
class AssetStatusOverlay extends StatefulWidget {
  /// Lays [binding]'s status control and badge over [child].
  const AssetStatusOverlay({
    required this.binding,
    required this.child,
    this.status = const MediaStatusMode.control(),
    this.badge = false,
    this.onPlay,
    this.skin,
    this.width,
    this.round = false,
    super.key,
  });

  /// The binding whose transfer, stage and descriptor the controls show.
  final AssetBinding binding;

  /// Where the status control shows, if at all.
  final MediaStatusMode status;

  /// Whether the media badge shows.
  final bool badge;

  /// Told when the user taps play: on a streamable video that is missing,
  /// or with `MediaStatusMode.control(playAction: true)`.
  final VoidCallback? onPlay;

  /// The parts of the look this overlay replaces, over the scope's.
  final AssetViewSkin? skin;

  /// The width of the box, for the badge's narrow forms; null for a wide
  /// one.
  final double? width;

  /// Whether the box is a circle: its centre control is the round size.
  final bool round;

  /// What the controls lie over: the content's picture.
  final Widget child;

  @override
  State<AssetStatusOverlay> createState() => _AssetStatusOverlayState();
}

class _AssetStatusOverlayState extends State<AssetStatusOverlay> {
  bool _streaming = false;
  // The size of the picture, as far as it is known: the badge and the
  // compact control sit in the picture a contain fit letterboxes, not at the
  // corner of the box.
  Size? _picture;

  @override
  void initState() {
    super.initState();
    widget.binding.addListener(_bindingChanged);
    _streaming = _readStreaming();
    _picture = _readPicture();
  }

  @override
  void didUpdateWidget(AssetStatusOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.binding, widget.binding)) {
      oldWidget.binding.removeListener(_bindingChanged);
      widget.binding.addListener(_bindingChanged);
    }
    _streaming = _readStreaming();
    _picture = _readPicture();
  }

  Size? _readPicture() {
    final binding = widget.binding;
    if (binding.paintable.pictureSize case final size?) return size;
    final dimensions = binding.descriptor?.dimensions;
    if (dimensions == null) return null;
    return Size(dimensions.width.toDouble(), dimensions.height.toDouble());
  }

  @override
  void dispose() {
    widget.binding.removeListener(_bindingChanged);
    super.dispose();
  }

  // Streamable video that is not local and shows no frame: play streams it,
  // the corner control downloads it.
  bool _readStreaming() {
    if (widget.status is! MediaStatusMode$Control) return false;
    final binding = widget.binding;
    final descriptor = binding.descriptor;
    return descriptor != null &&
        descriptor.streamable &&
        descriptor.kind == MediaKind.video &&
        binding.transfer is! AssetTransfer$None &&
        binding.readiness.stage.index < AssetStage.firstFrame.index;
  }

  void _bindingChanged() {
    final streaming = _readStreaming();
    final picture = _readPicture();
    // What the media is decides its progress look (a GIF's arc, a video's
    // spinner): a descriptor that arrives later changes it.
    final descriptor = widget.binding.descriptor;
    if (streaming == _streaming &&
        picture == _picture &&
        descriptor == _descriptor) {
      return;
    }
    setState(() {
      _streaming = streaming;
      _picture = picture;
      _descriptor = descriptor;
    });
  }

  MediaDescriptor? _descriptor;

  // A skin's part, rebuilt with the binding's state; the stock part
  // repaints itself and needs no rebuild.
  Widget _skinned(AssetSkinBuilder? builder, Widget stock) {
    if (builder == null) return stock;
    return AssetLoadStateBuilder.binding(
      widget.binding,
      child: stock,
      builder: (context, state, stock) => builder(context, state, stock!),
    );
  }

  Widget _control(MediaStatusControl control) => _skinned(
    MediaLoadingStyleScope.resolveSkin(context, skin: widget.skin).status,
    control,
  );

  @override
  Widget build(BuildContext context) {
    final style = MediaLoadingStyleScope.resolve(context);
    final binding = widget.binding;
    final corner = style.status.compactOffset;
    // A GIF's arc stands from nothing until its bytes are measured; a
    // video's spins (the skin's choice per kind).
    final look = MediaLoadingStyleScope.resolveSkin(
      context,
      skin: widget.skin,
    ).progressOf(binding.descriptor);
    final centre = widget.round ? style.status.roundVideoDiameter : null;
    Widget compact() => Positioned.fill(
      child: CustomSingleChildLayout(
        delegate: _InPicture(
          profile: binding.profile,
          picture: _picture,
          offset: corner,
        ),
        child: _control(
          MediaStatusControl.binding(
            binding,
            compact: true,
            progressLook: look,
          ),
        ),
      ),
    );
    final controls = <Widget>[
      ...switch (widget.status) {
        MediaStatusMode$None() => const <Widget>[],
        MediaStatusMode$Arc(:final radius) => [
          Positioned.fill(
            // The control keeps its style's size whatever the box: never
            // stretched to a large tile, free to overflow a small one.
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: _control(
                MediaStatusControl.binding(
                  binding,
                  progressLook: look,
                  arcOnly: true,
                  diameter: 2 * radius,
                ),
              ),
            ),
          ),
        ],
        MediaStatusMode$Control() when _streaming => [
          Positioned.fill(
            // The control keeps its style's size whatever the box: never
            // stretched to a large tile, free to overflow a small one.
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: _control(
                MediaStatusControl(
                  status: const MediaStatus.icon(MediaStatusIcon.play),
                  onTap: widget.onPlay,
                  diameter: centre,
                ),
              ),
            ),
          ),
          compact(),
        ],
        MediaStatusMode$Control(:final playAction) => [
          Positioned.fill(
            // The control keeps its style's size whatever the box: never
            // stretched to a large tile, free to overflow a small one.
            child: OverflowBox(
              minWidth: 0,
              minHeight: 0,
              maxWidth: double.infinity,
              maxHeight: double.infinity,
              child: _control(
                MediaStatusControl.binding(
                  binding,
                  progressLook: look,
                  playAction: playAction,
                  onPlay: widget.onPlay,
                  diameter: centre,
                ),
              ),
            ),
          ),
        ],
        MediaStatusMode$Compact() => [compact()],
      },
    ];
    final badge = style.badge.offset;
    final failure = MediaLoadingStyleScope.resolveSkin(
      context,
      skin: widget.skin,
    ).failure;
    return Stack(
      children: [
        widget.child,
        // A host's mark of a failure, under the controls (whose download is
        // the retry); the stock part is nothing, the picture kept.
        if (failure != null)
          Positioned.fill(
            child: AssetLoadStateBuilder.binding(
              binding,
              builder: (context, state, _) => state.failed
                  ? failure(context, state, const SizedBox.shrink())
                  : const SizedBox.shrink(),
            ),
          ),
        ...controls,
        if (widget.badge)
          Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _InPicture(
                profile: binding.profile,
                picture: _picture,
                // Beside the corner control while it shows, as one row.
                offset: Offset(
                  _streaming
                      ? corner.dx + style.status.compactDiameter + 4
                      : badge.dx,
                  badge.dy,
                ),
              ),
              child: _skinned(
                MediaLoadingStyleScope.resolveSkin(
                  context,
                  skin: widget.skin,
                ).badge,
                MediaBadge.binding(
                  binding,
                  width: widget.width ?? double.infinity,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// A corner overlay (the badge, the compact control) at [offset] from the
// top-left of the picture as it shows in the box: the picture a contain fit
// letterboxes, or the box a cover fit fills (and cuts the picture to).
class _InPicture extends SingleChildLayoutDelegate {
  const _InPicture({
    required this.profile,
    required this.picture,
    required this.offset,
  });

  final AssetProfile profile;
  final Size? picture;
  final Offset offset;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      profile
          .roundedArea(Offset.zero & size, picture)
          .intersect(Offset.zero & size)
          .topLeft +
      offset;

  @override
  bool shouldRelayout(_InPicture oldDelegate) =>
      oldDelegate.profile != profile ||
      oldDelegate.picture != picture ||
      oldDelegate.offset != offset;
}
