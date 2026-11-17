import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/viewer_loading.dart';
import 'package:mpx_ui/src/viewer/viewer_photo_page.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';
import 'package:mpx_ui/src/viewer/viewer_video.dart';
import 'package:mpx_ui/src/viewer/viewer_video_session.dart';

/// One video of the viewer as a page a host places in its own pager or
/// screen: the player's picture with the policy's gestures (zoom, double-tap
/// seek, held press, a tap that shows or hides the controls) and the
/// policy's controls over it.
///
/// While [active] it plays [item] on [players] through a
/// [ViewerVideoSession] (the logic `MediaViewer` uses too) and shows
/// [standIn] until the first frame, then fades the player in over it
/// (`ViewerLoadingRules.playerFadeIn`), with the policy's buffering spinner
/// while the player waits for its media; inactive it shows [standIn] and
/// holds no player, so a pager keeps one lease for the page on screen.
class ViewerVideoPage extends StatefulWidget {
  /// Creates a page for [item].
  const ViewerVideoPage({
    required this.item,
    required this.players,
    super.key,
    this.policy = ViewerPolicy.$Android,
    this.tokens = const ViewerTokens(),
    this.active = true,
    this.standIn,
    this.contentSize,
    this.startAt,
    this.speeds,
    this.qualities = const [],
    this.previewFrame,
    this.strings = const ViewerVideoStrings(),
    this.drag,
    this.onZoomedChanged,
    this.onFullscreen,
  });

  /// The video.
  final GalleryItem item;

  /// The players.
  final PlayerPool players;

  /// The gestures and the video rules.
  final ViewerPolicy policy;

  /// The colours of the controls.
  final ViewerTokens tokens;

  /// Whether the page plays (holds a lease).
  final bool active;

  /// What shows until the first frame, and while inactive.
  final Widget? standIn;

  /// The picture's size at rest; the page's when null.
  final Size? contentSize;

  /// Where playback starts; the player's own position when null.
  final Duration? startAt;

  /// Where chosen speeds are kept.
  final ViewerSpeeds? speeds;

  /// The qualities offered.
  final List<ViewerQuality> qualities;

  /// The seek preview's frames.
  final ViewerPreviewFrame? previewFrame;

  /// The texts of the controls.
  final ViewerVideoStrings strings;

  /// Where dismiss drags go; none when null.
  final ViewerDragEvents? drag;

  /// Told when the picture leaves or returns to rest.
  final ValueChanged<bool>? onZoomedChanged;

  /// Asked to toggle fullscreen (a double tap, by the policy's rule).
  final VoidCallback? onFullscreen;

  @override
  State<ViewerVideoPage> createState() => ViewerVideoPageState();
}

/// The state of a [ViewerVideoPage]; [session] is its playback while active.
class ViewerVideoPageState extends State<ViewerVideoPage> {
  late final ValueNotifier<bool> _controls = ValueNotifier(
    widget.policy.video.controlsVisibleOnOpen,
  );
  ViewerVideoSession? _session;
  // How much the buffering spinner shows: the share of the centre it takes
  // from the play button.
  final ValueNotifier<double> _spinnerShown = ValueNotifier(0);

  /// The playback, while the page is active.
  ViewerVideoSession? get session => _session;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(ViewerVideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.item.key != oldWidget.item.key ||
        !identical(widget.players, oldWidget.players) ||
        widget.policy != oldWidget.policy) {
      _end();
    }
    _sync();
  }

  @override
  void dispose() {
    _end();
    _controls.dispose();
    _spinnerShown.dispose();
    super.dispose();
  }

  void _sync() {
    if (!widget.active) return _end();
    if (_session != null) return;
    _session = ViewerVideoSession(
      players: widget.players,
      item: widget.item,
      rules: widget.policy.video,
      controls: _controls,
      speeds: widget.speeds,
      startAt: widget.startAt,
      autoHide: true,
    )..addListener(_onSession);
  }

  void _end() {
    final session = _session;
    if (session == null) return;
    session
      ..removeListener(_onSession)
      ..dispose();
    _session = null;
    // Its spinner went with it; told after the frame, since this runs in
    // builds and in dispose.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) _spinnerShown.value = 0;
    });
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final standIn = widget.standIn ?? const SizedBox.expand();
    final policy = widget.policy;
    final page = ViewerPhotoPage(
      policy: policy,
      contentSize: widget.contentSize,
      drag: widget.drag,
      onZoomedChanged: widget.onZoomedChanged,
      onTap: () => _controls.value = !_controls.value,
      onDoubleTap: session == null
          ? null
          : (local, page) => session.doubleTap(
              local,
              page,
              onFullscreen: widget.onFullscreen,
            ),
      holdDelay: session == null ? null : policy.video.hold?.delay,
      onHoldStart: (local, page) => session?.holdStart(
        atFraction: page.width <= 0 ? 0 : local.dx / page.width,
      ),
      onHoldEnd: () => session?.holdEnd(),
      child: session == null
          ? standIn
          : PlayerOverStandIn(
              lease: session.lease,
              standIn: standIn,
              fadeIn: policy.loading.playerFadeIn,
              handedOverFadeIn: policy.loading.playerFadeInHandedOver,
            ),
    );
    if (session == null) return page;
    return Stack(
      fit: StackFit.expand,
      children: [
        page,
        ViewerBufferingSpinner(
          lease: session.lease,
          rules: policy.loading,
          presence: _spinnerShown,
        ),
        ValueListenableBuilder<bool>(
          valueListenable: _controls,
          builder: (context, visible, _) => ViewerVideoControls(
            lease: session.lease,
            rules: policy.video,
            tokens: widget.tokens,
            visible: visible,
            showDuration: policy.controlsDuration,
            hideDuration: policy.controlsHideDuration,
            onInteraction: session.interacted,
            onSpeed: session.setSpeed,
            qualities: widget.qualities,
            quality: session.quality,
            onQuality: session.setQuality,
            previewFrame: widget.previewFrame,
            strings: widget.strings,
            centreTaken: _spinnerShown,
          ),
        ),
      ],
    );
  }
}
