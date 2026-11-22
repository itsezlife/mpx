import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/gallery/gallery_keep_alive.dart';
import 'package:mpx_ui/src/gallery/gallery_pager.dart';
import 'package:mpx_ui/src/known_descriptors.dart';
import 'package:mpx_ui/src/text/mpx_text_root.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/origin_bridge.dart';
import 'package:mpx_ui/src/viewer/viewer_actions.dart';
import 'package:mpx_ui/src/viewer/viewer_backdrop.dart';
import 'package:mpx_ui/src/viewer/viewer_chrome_overlay.dart';
import 'package:mpx_ui/src/viewer/viewer_loading.dart';
import 'package:mpx_ui/src/viewer/viewer_origin.dart';
import 'package:mpx_ui/src/viewer/viewer_photo_page.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_policy_scope.dart';
import 'package:mpx_ui/src/viewer/viewer_tokens.dart';
import 'package:mpx_ui/src/viewer/viewer_video.dart';
import 'package:mpx_ui/src/viewer/viewer_video_session.dart';

// --- Controller -------------------------------------------------------------

/// Drives and observes a [MediaViewer] from the host: the item shown,
/// whether it is open, the controls, the zoom and the video's lease.
///
/// A host creates one, passes it to the viewer (or to `MediaViewer.show`)
/// and disposes it. It is attached while the viewer is mounted
/// ([isAttached]); commands before or after do nothing. Listeners hear when
/// the item, the open state, the controls or the video's lease change.
final class ViewerController extends ChangeNotifier {
  MediaViewerState? _viewer;

  /// Whether a viewer is mounted with this controller.
  bool get isAttached => _viewer != null;

  /// The index of the item shown; null while no viewer is attached.
  int? get index => _viewer?.index;

  /// Whether the viewer is open: its open transition has run and the close
  /// has not begun.
  bool get isOpen => _viewer?.isOpen ?? false;

  /// Whether the chrome and the video's controls show.
  bool get controlsVisible => _viewer?.controlsVisible ?? false;
  set controlsVisible(bool value) => _viewer?._controls.value = value;

  /// The lease of the video on screen, or null.
  PlayerLease? get videoLease => _viewer?.videoLease;

  /// True from the start of a dismiss drag until it closes the viewer or
  /// springs back.
  ValueListenable<bool> get dismissing => _dismissing;
  final ValueNotifier<bool> _dismissing = ValueNotifier(false);

  /// Pages to [index] with the policy's controls timing.
  Future<void> animateTo(int index) async => _viewer?._pageTo(index);

  /// Pages to [index] at once.
  void jumpTo(int index) => _viewer?._pageTo(index, animate: false);

  /// Brings the picture shown back to rest.
  void resetZoom() => _viewer?._resetZoom();

  /// Closes the viewer as the back button does; completes when it has run.
  Future<void> close() async => _viewer?.close();

  bool _notifyPending = false;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _dismissing.dispose();
    super.dispose();
  }

  void _attach(MediaViewerState viewer) {
    assert(
      _viewer == null || identical(_viewer, viewer),
      'A ViewerController drives one viewer at a time.',
    );
    _viewer = viewer;
    _changed();
  }

  void _detach(MediaViewerState viewer) {
    if (!identical(_viewer, viewer)) return;
    _viewer = null;
    _changed();
  }

  // The viewer attaches in initState and detaches in dispose, and takes or
  // gives back its video's lease there and in layout: inside a build, or
  // while the tree is locked. A listener elsewhere in the tree cannot
  // rebuild then (Flutter asserts), so a change heard during the frame's
  // build, layout or paint is told once, at the end of that frame.
  void _changed() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      notifyListeners();
      return;
    }
    if (_notifyPending) return;
    _notifyPending = true;
    binding.addPostFrameCallback((_) {
      _notifyPending = false;
      if (!_disposed) notifyListeners();
    });
  }
}

// --- Viewer -----------------------------------------------------------------

/// The fullscreen viewer: pages through a [GallerySource], opening from and
/// closing to each item's place on the host's surface through an
/// [OriginBridge], with the gestures and timings of a [ViewerPolicy] and the
/// colours of the host's [ViewerTokens].
///
/// ## Open and close
///
/// The picture morphs from its origin (rectangle, corners, clip) to its
/// fitted place while the background fades in, and the origin is hidden on
/// the surface ([OriginBridge.setHidden]) as long as the viewer stands over
/// it. Closing on another item asks the bridge to reveal that item's origin
/// first. Without an origin the picture slides off the way it was dragged,
/// or the viewer shrinks and fades when it closes without a drag.
///
/// ## Gestures
///
/// A vertical drag (past the policy's slop, twice as vertical as horizontal)
/// moves the picture and fades the background down to the policy's floor;
/// released past the policy's fraction of the height it closes, otherwise
/// it springs back. Double tap zooms around the tap, a pinch zooms within
/// the policy's range, and a horizontal swipe pages while the picture is not
/// zoomed.
///
/// ## Chrome
///
/// With [chrome] the viewer draws the top bar, the counter, the caption, the
/// thumbnail strip and the overflow menu; a tap on the picture shows or hides
/// them. The host supplies the actions per item and the title, subtitle and
/// caption builders. An action gets the item's cached file (through
/// [ViewerChrome.openFile], released when the action completes) and the
/// picture as it shows.
///
/// The viewer covers the whole screen and asks for clear system bars: a
/// zoomed picture runs under the status and navigation bars, which the
/// chrome covers with its bar fill while it shows. On Android before 15 the
/// window reaches under the navigation bar only when the host is
/// edge-to-edge (`SystemUiMode.edgeToEdge`).
///
/// ## Video
///
/// With [players] a video item plays on the player pool: it opens where the
/// origin's loop is ([GalleryOrigin.position]), shows the origin's frame
/// until the player's first frame, and hands its position back on close
/// ([OriginBridge.handBack]). Its controls (play, seek bar with preview,
/// time, speed, quality) hide after the policy's auto-hide while it plays;
/// double tap seeks or toggles fullscreen and a held press plays faster, as
/// the policy says. Short or silent videos loop by the policy's rule; a
/// video that ends otherwise goes back to its start, paused, with the
/// controls shown. Animations (GIFs) loop muted on the software path, with
/// no controls.
///
/// ## Desktop input
///
/// With [ViewerPolicy.desktopInput] the keyboard and the wheel drive the
/// viewer: Esc closes; the arrows page (or seek 5 s in fullscreen); J and L
/// seek 10 s; K plays or pauses; Space does too, and held plays faster;
/// 0 to 9 jump to that tenth of the video; Ctrl (or Cmd) with + - 0 zooms in
/// steps, F toggles fullscreen; the wheel pages, and zooms with Ctrl. A
/// mouse move shows the controls. Fullscreen is the host's window:
/// [onFullscreenChanged] is told to enter or leave it.
///
/// Media is drawn through the core's asset cache ([scope], or the closest
/// `AssetCacheProvider`); until the item's own picture arrives the origin's
/// current frame shows.
class MediaViewer extends StatefulWidget {
  /// Creates a viewer on [source], opened at [initialIndex].
  const MediaViewer({
    required this.source,
    required this.initialIndex,
    super.key,
    this.bridge,
    this.policy,
    this.tokens = const ViewerTokens(),
    this.scope,
    this.onClosed,
    this.onIndexChanged,
    this.onBackdropScale,
    this.chrome,
    this.players,
    this.speeds,
    this.qualitiesOf,
    this.previewFrame,
    this.onFullscreenChanged,
    this.videoStrings = const ViewerVideoStrings(),
    this.controller,
    this.videoStartOf,
    this.onVideoLeft,
    this.onOpenElsewhere,
    this.onPictureTap,
  });

  /// The items.
  final GallerySource source;

  /// The item the viewer opens on.
  final int initialIndex;

  /// The link to the surface the viewer opened from; null opens and closes
  /// without a morph.
  final OriginBridge? bridge;

  /// The gestures, transitions, timings and playback choices. Null takes the
  /// closest [ViewerPolicyScope]'s, else the reference of the platform the
  /// theme names ([ViewerPolicyScope.resolve]).
  final ViewerPolicy? policy;

  /// The colours and type.
  final ViewerTokens tokens;

  /// The cache the pictures attach to.
  final AssetCacheScope? scope;

  /// Called once the close transition has run: remove the viewer.
  final VoidCallback? onClosed;

  /// Told the index of the item shown when it changes.
  final ValueChanged<int>? onIndexChanged;

  /// Told the scale the host draws its surface behind the viewer at, as the
  /// viewer opens, is dragged and closes; see
  /// [ViewerPolicy.backdropScale].
  final ValueChanged<double>? onBackdropScale;

  /// The bars, menu and caption, and the host's actions; none when null.
  final ViewerChrome? chrome;

  /// The players videos play on; videos show their still when null.
  final PlayerPool? players;

  /// Where chosen speeds are kept; the viewer keeps its own when null. A
  /// host passes one instance to every viewer for a session-wide speed.
  final ViewerSpeeds? speeds;

  /// The qualities of a video item; one quality when null.
  final List<ViewerQuality> Function(int index, GalleryItem item)? qualitiesOf;

  /// The seek preview's frames; the preview shows the time only when null.
  final ViewerPreviewFrame? previewFrame;

  /// Told to put the app window into fullscreen (true) or back (false).
  final ValueChanged<bool>? onFullscreenChanged;

  /// The texts of the video controls.
  final ViewerVideoStrings videoStrings;

  /// Drives and observes the viewer from the host; none when null.
  final ViewerController? controller;

  /// Where a video with sound starts, from the host's own record (a
  /// position it saved when the viewer last left the item), or null to start
  /// as the policy says (`ViewerVideoRules.start`). The viewer keeps no
  /// record of its own.
  final Duration? Function(int index, GalleryItem item)? videoStartOf;

  /// Told where the player of a video with sound stood as the viewer left
  /// the item (closed, or paged away), for a host that keeps a record for
  /// [videoStartOf].
  final void Function(int index, GalleryItem item, Duration position)?
  onVideoLeft;

  /// Opens the item at [index] in another app, for a video that cannot be
  /// played here: the alert of [ViewerVideoFailure.alert] offers it; without
  /// it the viewer shows its card instead.
  final Future<void> Function(int index, GalleryItem item)? onOpenElsewhere;

  /// A single tap on the picture of an item with no player under it: the
  /// host takes it (a picker toggles the item's selection) in place of the
  /// policy's own (the chrome shows or hides, or the viewer closes). A
  /// video with a player under it plays or pauses as the policy says.
  final void Function(int index, GalleryItem item)? onPictureTap;

  /// Pushes a viewer as a transparent route over [context]'s navigator and
  /// completes when it has closed.
  ///
  /// Without a [bridge] the viewer opens from and closes to the
  /// `ViewerOrigin`s of the closest `ViewerOriginScope` above [context], if
  /// any. Without a [policy] it takes the one [ViewerPolicyScope.resolve]
  /// gives for [context].
  static Future<void> show(
    BuildContext context, {
    required GallerySource source,
    required int initialIndex,
    OriginBridge? bridge,
    ViewerPolicy? policy,
    ViewerController? controller,
    ViewerTokens tokens = const ViewerTokens(),
    AssetCacheScope? scope,
    ValueChanged<double>? onBackdropScale,
    ViewerChrome? chrome,
    PlayerPool? players,
    ViewerSpeeds? speeds,
    List<ViewerQuality> Function(int index, GalleryItem item)? qualitiesOf,
    ViewerPreviewFrame? previewFrame,
    ValueChanged<bool>? onFullscreenChanged,
    Duration? Function(int index, GalleryItem item)? videoStartOf,
    void Function(int index, GalleryItem item, Duration position)? onVideoLeft,
    Future<void> Function(int index, GalleryItem item)? onOpenElsewhere,
  }) {
    final cache = scope ?? AssetCacheProvider.of(context);
    final origins =
        bridge ?? ViewerOriginScope.maybeOf(context)?.bridgeFor(source);
    final rules = ViewerPolicyScope.resolve(context, policy: policy);
    final text = MpxTextRoot.styleOf(context);
    return Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (routeContext, _, _) => MpxTextRoot.over(
          text,
          MediaViewer(
            source: source,
            initialIndex: initialIndex,
            bridge: origins,
            policy: rules,
            controller: controller,
            tokens: tokens,
            scope: cache,
            onBackdropScale: onBackdropScale,
            chrome: chrome,
            players: players,
            speeds: speeds,
            qualitiesOf: qualitiesOf,
            previewFrame: previewFrame,
            onFullscreenChanged: onFullscreenChanged,
            videoStartOf: videoStartOf,
            onVideoLeft: onVideoLeft,
            onOpenElsewhere: onOpenElsewhere,
            onClosed: () => Navigator.of(routeContext).pop(),
          ),
        ),
      ),
    );
  }

  @override
  State<MediaViewer> createState() => MediaViewerState();
}

enum _Phase { opening, open, closing, closed }

/// The state of a [MediaViewer]: [close] closes it as the back button does.
class MediaViewerState extends State<MediaViewer>
    with TickerProviderStateMixin {
  late int _index = widget.initialIndex;

  // The item the viewer opened on, by its content: indexes move when the
  // source learns of items before it. Null until the source has loaded it.
  late MediaKey? _opened = widget.source.itemAt(widget.initialIndex)?.key;
  late final GalleryPagerController _pages = GalleryPagerController(
    initialPage: widget.initialIndex,
  );
  late final AnimationController _transition;
  late final AnimationController _springBack;
  final ValueNotifier<bool> _controls = ValueNotifier(true);
  // How much the buffering spinner shows: the share of the centre it takes
  // from the play button.
  final ValueNotifier<double> _spinnerShown = ValueNotifier(0);
  // Whether the video page's download radial shows: the spinner holds back.
  final ValueNotifier<bool> _pageStatusShows = ValueNotifier(false);

  _Phase _phase = _Phase.opening;
  Size _size = Size.zero;
  // The morph in progress: from and to, in global coordinates.
  _Frame? _from;
  _Frame? _to;
  // The background opacity the close starts from.
  double _closeFromBackground = 1;
  // How the picture leaves when nothing morphs: slide or shrink.
  bool _fadeOut = false;
  // The vertical offset of a dismiss drag, and the one a spring back left.
  double _drag = 0;
  double _springFrom = 0;
  final Set<int> _hidden = {};

  // The video on screen and the index it plays.
  ViewerVideoSession? _session;
  int? _sessionIndex;
  // Holds the origin's loop of the video the player plays.
  AssetPlaybackHold? _loopHold;
  // The prepared players of the video items next to the one shown, by
  // index (_syncNeighbours).
  final Map<int, PlayerLease> _neighbours = {};
  // The lease of the item shown, while the neighbours wait for its first
  // frame.
  PlayerLease? _neighboursWaitOn;
  // The session whose player has moved, so every picture of it (the page,
  // the morph) shows the player from the start.
  ViewerVideoSession? _movingSession;
  // Whether the close already told the host where the player stood.
  bool _leftReported = false;
  Timer? _spaceHold;
  bool _fullscreen = false;
  Offset? _lastHover;
  late final ViewerSpeeds _speeds = widget.speeds ?? ViewerSpeeds();
  final FocusNode _focus = FocusNode(debugLabel: 'mpx-viewer');
  final Map<int, GlobalKey<ViewerPhotoPageState>> _pageKeys = {};
  // The origins' pictures the pages draw until their own arrive, owned by
  // the viewer: the bridge hands out clones. A video page paged away from
  // keeps its player's last picture here too (_keepFrame). Kept for the pages that can
  // show (the item and its neighbours), freed as the viewer leaves them.
  final Map<int, ui.Image> _originFrames = {};

  /// The index of the item shown.
  int get index => _index;

  /// The policy the viewer follows: its own, else its scope's, else the
  /// platform's ([ViewerPolicyScope.resolve]).
  ViewerPolicy get policy => _policy;

  /// Whether the open transition has finished and the close has not begun.
  bool get isOpen => _phase == _Phase.open;

  /// Whether the chrome shows.
  bool get controlsVisible => _controls.value;

  /// The vertical offset of the picture from where it rests, positive down.
  double get dragOffset => _drag;

  /// Whether the viewer asked the host for a fullscreen window.
  bool get fullscreen => _fullscreen;

  /// The lease of the video on screen, or null when the item is not a video
  /// or the viewer has no players.
  PlayerLease? get videoLease => _session?.lease;

  /// The indexes of the video items whose players the viewer holds
  /// prepared beside the one on screen ([ViewerVideoRules.prepareNeighbours]).
  @visibleForTesting
  Set<int> get preparedNeighbours => _neighbours.keys.toSet();

  /// The background's opacity now.
  double get backgroundOpacity => switch (_phase) {
    _Phase.opening => _openingBackground,
    _Phase.open => _policy.backgroundOpacityAt(_drag, _size.width),
    _Phase.closing => _closeFromBackground * (1 - _transitionT),
    _Phase.closed => 0,
  };

  double get _transitionT => _policy.openCurve.transform(_transition.value);

  // The background fades in over its own duration when the policy has one,
  // linearly; else it follows the open transition.
  double get _openingBackground {
    final policy = _policy;
    final fade = policy.backgroundFadeDuration;
    if (fade == null || fade == Duration.zero) return _transitionT;
    final elapsed = _transition.value * policy.openDuration.inMicroseconds;
    return math.min(1, elapsed / fade.inMicroseconds);
  }

  ViewerVideoRules get _video => _policy.video;

  bool _isVideo(int index) =>
      widget.source.itemAt(index)?.kind == GalleryMediaKind.video;

  @override
  void initState() {
    super.initState();
    _transition = AnimationController(vsync: this)..addListener(_onTransition);
    _springBack = AnimationController(vsync: this)..addListener(_onSpringBack);
    _speeds.beginViewer();
    _controls.addListener(_notifyController);
    widget.controller?._attach(this);
    widget.source.addListener(_onSource);
    widget.source.loadAround(_index);
  }

  // The policy reads the theme and the scope, so the viewer starts here, on
  // its first dependencies, rather than in initState.
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolvePolicy();
    _backdropScale = ViewerBackdropScope.maybeOf(context);
    if (_started) return;
    _started = true;
    _controls.value = _isVideo(_index)
        ? _video.controlsVisibleOnOpen
        : _policy.controlsVisibleOnOpen;
    // The player is leased before the first frame, so its way to a first
    // frame of its own (creating, reading, decoding, all off the UI
    // isolate) overlaps the whole morph. The rest of the open waits for that
    // frame, the morph's start.
    _syncVideo();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  late ViewerPolicy _policy;

  void _resolvePolicy() {
    _policy = ViewerPolicyScope.resolve(context, policy: widget.policy);
    _springBack.duration = _policy.settleDuration;
  }

  @override
  void dispose() {
    _releaseTransitionHold();
    _spaceHold?.cancel();
    widget.controller?._detach(this);
    _releaseVideo();
    _releaseNeighbours();
    _focus.dispose();
    widget.source.removeListener(_onSource);
    for (final index in _hidden) {
      widget.bridge?.setHidden(index, hidden: false);
    }
    // A viewer gone without its close leaves the surfaces behind as they
    // were; after the frame, as they may rebuild with it.
    if (_backdropReport case final report?) {
      SchedulerBinding.instance.addPostFrameCallback((_) => report(1));
    }
    if (_covered case final index?) {
      widget.bridge?.setCovered(index, covered: false);
    }
    _dropOriginFrames();
    _transition.dispose();
    _springBack.dispose();
    _pages.dispose();
    _controls.dispose();
    _spinnerShown.dispose();
    _dismissedFailure.dispose();
    _pageStatusShows.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(MediaViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.policy, oldWidget.policy)) _resolvePolicy();
    if (!identical(widget.controller, oldWidget.controller)) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (!identical(widget.source, oldWidget.source)) {
      oldWidget.source.removeListener(_onSource);
      widget.source.addListener(_onSource);
      widget.source.loadAround(_index);
      // The index may name another item now.
      _releaseVideo();
      _releaseNeighbours();
      _syncVideo();
      _syncNeighbours();
    }
    if (!identical(widget.bridge, oldWidget.bridge)) {
      // The new surface hides what the viewer stands over; the old one shows
      // it again. Its pictures came from the old surface.
      for (final index in _hidden) {
        oldWidget.bridge?.setHidden(index, hidden: false);
        widget.bridge?.setHidden(index, hidden: true);
      }
      if (_covered case final index?) {
        oldWidget.bridge?.setCovered(index, covered: false);
        widget.bridge?.setCovered(index, covered: true);
      }
      if (widget.bridge == null) _hidden.clear();
      _dropOriginFrames();
    }
  }

  ui.Image? _originFrame(int index) {
    final kept = _originFrames[index];
    if (kept != null) return kept;
    final frame = widget.bridge?.frameOf(index);
    if (frame != null) _originFrames[index] = frame;
    return frame;
  }

  // Frees the origin pictures, all of them or those of pages more than one
  // away from [around]. A page still drawing one keeps its own clone
  // (its placeholder holds one), so freeing ours never pulls a picture off
  // screen.
  void _dropOriginFrames({int? around}) {
    _originFrames.removeWhere((index, frame) {
      if (around != null && (index - around).abs() <= 1) return false;
      frame.dispose();
      return true;
    });
  }

  void _notifyController() => widget.controller?._changed();

  void _pageTo(int index, {bool animate = true}) {
    if (index < 0 || index >= widget.source.count) return;
    if (animate) {
      unawaited(_pages.animateTo(index));
    } else {
      _pages.jumpTo(index);
    }
  }

  void _resetZoom() => _pageKeys[_index]?.currentState?.zoomTo(_policy.minZoom);

  void _onSource() {
    if (!mounted) return;
    _opened ??= widget.source.itemAt(widget.initialIndex)?.key;
    _syncVideo();
    _syncNeighbours();
    setState(() {});
  }

  // --- Video ----------------------------------------------------------------

  // Plays the item on screen when it is a video (or prepares it, paused,
  // when the policy does not autoplay), and gives back the lease
  // of the one before. Only the item on screen holds a lease: the pool keeps
  // the one left warm until its budget needs it.
  void _syncVideo() {
    final players = widget.players;
    final item = widget.source.itemAt(_index);
    if (players == null ||
        item == null ||
        item.kind != GalleryMediaKind.video) {
      _releaseVideo(keepFrame: true);
      return;
    }
    if (_sessionIndex == _index && _session != null) return;
    _releaseVideo(keepFrame: true);
    final cache = _cache;
    final startAt = _startOf(_index, item);
    // The loop stands still while the player plays the item: one decode of
    // the content at a time. It stands on the frame its surface showed, read
    // before the hold: every surface of it (the origin, the page under the
    // player) draws that frame and no other until the hold ends, whatever
    // its texture keeps meanwhile.
    _loopHold = cache?.holdPlayback(
      item.key,
      _loopSpec,
      picture: _heldPicture(_index),
    );
    _session = ViewerVideoSession(
      players: players,
      item: item,
      rules: _video,
      controls: _controls,
      speeds: _speeds,
      startAt: startAt,
      play: _video.autoplay,
      autoHide: _phase == _Phase.open,
    )..addListener(_onSession);
    _sessionIndex = _index;
    _notifyController();
  }

  // Where the player of the item at [index] starts: the host's word for
  // it, else where the origin's loop is (the loop of the content the
  // surface plays through the cache, which the page draws too).
  Duration? _startOf(int index, GalleryItem item) =>
      widget.videoStartOf?.call(index, item) ??
      switch (_video.start) {
        ViewerVideoStart.origin =>
          (index == widget.initialIndex
                  ? widget.bridge?.originOf(index)?.position
                  : null) ??
              _cache?.playbackPosition(item.key, _loopSpec),
        ViewerVideoStart.beginning => _video.restarts ? Duration.zero : null,
      };

  // Prepares the players of the video items next to the one shown, paused,
  // so paging to one shows its first frame at once: while the viewer is
  // open, up to the pool's prepared budget, the next first. They wait for
  // the item shown to have its first frame, so they never compete with it
  // for the decoders. A neighbour that falls out of the window is given
  // back; the pool keeps it warm until its budget needs it.
  void _syncNeighbours() {
    final players = widget.players;
    final wanted = <int>{};
    if (players != null &&
        !players.isDisposed &&
        _video.prepareNeighbours &&
        _phase == _Phase.open &&
        _shownIsReady()) {
      final room = players.budget.prepared;
      for (final index in [_index + 1, _index - 1]) {
        if (wanted.length >= room) break;
        if (index >= 0 && index < widget.source.count && _isVideo(index)) {
          wanted.add(index);
        }
      }
    }
    _neighbours.removeWhere((index, lease) {
      if (wanted.contains(index)) return false;
      lease.release();
      return true;
    });
    for (final index in wanted) {
      if (_neighbours.containsKey(index)) continue;
      final item = widget.source.itemAt(index)!;
      final lease = players!.lease(item.key);
      // A warm player stays where it was left, unless the policy restarts.
      if (_video.restarts || !lease.state.value.holdsEngine) {
        final startAt = _startOf(index, item);
        if (startAt != null) lease.seekTo(startAt);
      }
      lease.prepare();
      _neighbours[index] = lease;
    }
  }

  // Whether the item shown lets the neighbours prepare: it is no video, or
  // its player has its first frame (or failed). Else waits for that.
  bool _shownIsReady() {
    final lease = _session?.lease;
    final state = lease?.state.value;
    final ready =
        state == null ||
        state.firstFrameRendered ||
        state.phase == PlayerPhase.failed;
    if (ready) {
      _waitForShown(null);
    } else {
      _waitForShown(lease);
    }
    return ready;
  }

  void _waitForShown(PlayerLease? lease) {
    if (identical(lease, _neighboursWaitOn)) return;
    _neighboursWaitOn?.state.removeListener(_onShownState);
    _neighboursWaitOn = lease;
    lease?.state.addListener(_onShownState);
  }

  void _onShownState() {
    if (mounted) _syncNeighbours();
  }

  void _releaseNeighbours() {
    _waitForShown(null);
    for (final lease in _neighbours.values) {
      lease.release();
    }
    _neighbours.clear();
  }

  void _onSession() {
    if (mounted) setState(() {});
    _notifyController();
  }

  // Gives the video session back. With [keepFrame] (the viewer pages away
  // from it) the page keeps the picture the player showed last as its
  // stand-in, as an origin's frame: content still downloading would
  // otherwise fall back to its blurred preview, below what the page showed.
  void _releaseVideo({bool keepFrame = false}) {
    _loopHold?.release();
    _loopHold = null;
    final session = _session;
    if (session == null) return;
    if (keepFrame && session.lease.state.value.firstFrameRendered) {
      _keepFrame(_sessionIndex!);
    }
    if (widget.source.itemAt(_sessionIndex!) case final item?
        when !_leftReported) {
      widget.onVideoLeft?.call(_sessionIndex!, item, session.lease.position);
    }
    _leftReported = false;
    session
      ..removeListener(_onSession)
      ..dispose();
    _session = null;
    _sessionIndex = null;
    // The spinner of the session went with it. Told after the frame: this
    // runs in builds and while the tree is locked, and the next session's
    // spinner waits its delay before it shows.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _spinnerShown.value = 0;
      _pageStatusShows.value = false;
    });
    _notifyController();
  }

  /// Asks the host to put its window into fullscreen, or back.
  void toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    widget.onFullscreenChanged?.call(_fullscreen);
  }

  // --- Desktop input --------------------------------------------------------

  // How far the arrows seek a video in fullscreen, and J / L anywhere.
  static const Duration _arrowSeek = Duration(seconds: 5);
  static const Duration _keySeek = Duration(seconds: 10);

  // A mouse move this far shows the controls again.
  static const double _hoverWake = 5;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final space = key == LogicalKeyboardKey.space;
    if (event is KeyUpEvent) {
      if (!space) return KeyEventResult.ignored;
      final waiting = _spaceHold;
      _spaceHold = null;
      if (waiting != null && waiting.isActive) {
        waiting.cancel();
        _session?.togglePlay();
      } else {
        _session?.holdEnd();
      }
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) {
      return space ? KeyEventResult.handled : KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (command) {
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.add ||
          key == LogicalKeyboardKey.numpadAdd) {
        _zoomStep(zoomIn: true);
      } else if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        _zoomStep(zoomIn: false);
      } else if (key == LogicalKeyboardKey.digit0) {
        _pageKeys[_index]?.currentState?.zoomTo(_policy.minZoom);
      } else if (key == LogicalKeyboardKey.keyF) {
        toggleFullscreen();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    final digit = _digits.indexOf(key);
    if (digit >= 0) {
      final session = _session;
      if (session?.lease.state.value.duration == null) {
        return KeyEventResult.ignored;
      }
      session!.seekToFraction(digit / 10);
      return KeyEventResult.handled;
    }
    switch (key) {
      case LogicalKeyboardKey.escape:
        unawaited(close());
      case LogicalKeyboardKey.arrowLeft || LogicalKeyboardKey.arrowRight:
        final forward = key == LogicalKeyboardKey.arrowRight;
        if (_fullscreen && _session != null) {
          _session!.seekBy(forward ? _arrowSeek : -_arrowSeek);
        } else {
          _pageBy(forward ? 1 : -1);
        }
      case LogicalKeyboardKey.keyJ:
        _session?.seekBy(-_keySeek);
      case LogicalKeyboardKey.keyL:
        _session?.seekBy(_keySeek);
      case LogicalKeyboardKey.keyK:
        _session?.togglePlay();
      case LogicalKeyboardKey.space:
        final hold = _video.hold;
        final session = _session;
        if (session == null) return KeyEventResult.ignored;
        _spaceHold?.cancel();
        if (hold == null) {
          session.togglePlay();
        } else {
          _spaceHold = Timer(hold.delay, session.holdStart);
        }
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  static const List<LogicalKeyboardKey> _digits = [
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];

  void _pageBy(int delta) => _pageTo(_pages.page + delta);

  void _zoomStep({required bool zoomIn, Offset? focal}) {
    final page = _pageKeys[_index]?.currentState;
    if (page == null) return;
    final fitted = _fittedRect(_index, null).size;
    final next = _policy.stepZoom(
      page.zoom,
      fitted,
      _size,
      zoomIn: zoomIn,
      pixels: widget.source.itemAt(_index)?.size,
    );
    if (next != null) page.zoomTo(next, focal: focal);
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _phase != _Phase.open) return;
    final keyboard = HardwareKeyboard.instance;
    final delta = event.scrollDelta.dy != 0
        ? event.scrollDelta.dy
        : event.scrollDelta.dx;
    if (delta == 0) return;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      _zoomStep(zoomIn: delta < 0, focal: event.localPosition);
    } else {
      _pageBy(delta > 0 ? 1 : -1);
    }
  }

  // --- Trackpad ---------------------------------------------------------------

  // A trackpad's vertical pan pages like the wheel: one item per this much,
  // a wheel notch's worth.
  static const double _trackpadStep = 120;
  // Its horizontal swipe is slowed to this share and goes to the
  // neighbour once it passes [_swipeCommit], once per gesture.
  static const double _swipeSlow = 0.2;
  static const double _swipeCommit = 50 * 0.35;
  // A pinch zooms one step per this much change of its scale.
  static const double _pinchStep = 0.25;

  Axis? _trackpadAxis;
  double _trackpadPan = 0;
  bool _swiped = false;
  double _pinchAt = 1;

  void _onPanZoomStart(PointerPanZoomStartEvent event) {
    _trackpadAxis = null;
    _trackpadPan = 0;
    _swiped = false;
    _pinchAt = 1;
  }

  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_phase != _Phase.open) return;
    if ((event.scale - _pinchAt).abs() >= _pinchStep) {
      final zoomIn = event.scale > _pinchAt;
      _pinchAt += zoomIn ? _pinchStep : -_pinchStep;
      _zoomStep(zoomIn: zoomIn, focal: event.localPosition);
      return;
    }
    final pan = event.pan;
    // The swipe's orientation locks once one axis leads by a pixel.
    _trackpadAxis ??= (pan.dx.abs() - pan.dy.abs()).abs() > 1
        ? (pan.dx.abs() > pan.dy.abs() ? Axis.horizontal : Axis.vertical)
        : null;
    switch (_trackpadAxis) {
      case Axis.vertical:
        // Fingers up scroll on, as the wheel turned down.
        _trackpadPan -= event.panDelta.dy;
        while (_trackpadPan.abs() >= _trackpadStep) {
          final forward = _trackpadPan > 0;
          _trackpadPan -= forward ? _trackpadStep : -_trackpadStep;
          _pageBy(forward ? 1 : -1);
        }
      case Axis.horizontal:
        if (_swiped || (pan.dx * _swipeSlow).abs() < _swipeCommit) return;
        _swiped = true;
        // Fingers to the right bring the previous item.
        _pageBy(pan.dx > 0 ? -1 : 1);
      case null:
        break;
    }
  }

  void _onHover(PointerHoverEvent event) {
    final last = _lastHover;
    _lastHover = event.position;
    if (last != null && (event.position - last).distance < _hoverWake) return;
    _session?.interacted();
  }

  // The item the viewer shows, whose overlays on the surface fade out; none
  // once the close starts, so they are back as the picture lands.
  int? _covered;

  void _cover(int? index) {
    final bridge = widget.bridge;
    if (index == _covered) return;
    if (_covered case final old?) bridge?.setCovered(old, covered: false);
    _covered = index;
    if (index != null) bridge?.setCovered(index, covered: true);
  }

  void _hide(int index, {required bool hidden}) {
    final bridge = widget.bridge;
    if (bridge == null) return;
    if (hidden ? _hidden.add(index) : _hidden.remove(index)) {
      bridge.setHidden(index, hidden: hidden);
    }
  }

  // --- Actions --------------------------------------------------------------

  final Map<int, GlobalKey> _frameKeys = {};

  /// Runs [action] for the item at [index]: hands it the item, a way to open
  /// its cached file and the picture as shown, waits for it, then releases
  /// the files it opened.
  Future<void> runAction(ViewerAction action, int index) async {
    final item = widget.source.itemAt(index);
    if (item == null) return;
    final opener = widget.chrome?.openFile;
    final request = ViewerActionRequest(
      index: index,
      item: item,
      openFile: () async => opener == null ? null : await opener(item.key),
      captureFrame: () => _captureFrame(index),
    );
    try {
      await action.onSelected(request);
    } finally {
      request.complete();
    }
  }

  // An animation the policy restarts as the viewer opens and closes
  // ([ViewerLoopOpen.restart]): the shared playback goes back to its first
  // frame.
  void _restartLoop() {
    final item = widget.source.itemAt(_index);
    if (item?.kind != GalleryMediaKind.animation ||
        _video.loopOpen != ViewerLoopOpen.restart) {
      return;
    }
    _cache?.seekPlayback(item!.key, _loopSpec, Duration.zero);
  }

  // The page's picture as it shows now, the player's included, or null when
  // the page has none painted.
  ui.Image? _pictureNow(int index) {
    final boundary = _frameKeys[index]?.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return boundary.toImageSync(pixelRatio: dpr);
  }

  // The frame the content's surfaces stand on while the player plays it.
  // As the viewer opens it is the origin's (the morph flies that picture).
  // Paged to, the page already shows a frame of its own, painted: held on
  // the origin's instead (a grid thumbnail of another moment), every surface
  // of the content, the page under the player included, would swap to it
  // and back as the player fades in, a flash.
  ui.Image? _heldPicture(int index) {
    if (_phase != _Phase.opening) {
      final boundary = _frameKeys[index]?.currentContext?.findRenderObject();
      if (boundary is RenderRepaintBoundary &&
          boundary.attached &&
          boundary.hasSize &&
          !(kDebugMode && boundary.debugNeedsPaint)) {
        final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
        return boundary.toImageSync(pixelRatio: dpr);
      }
    }
    return _originFrame(index)?.clone();
  }

  // Keeps the page's picture as it shows now (the player's frame) as the
  // stand-in the page draws until its content has a frame of its own.
  void _keepFrame(int index) {
    final boundary = _frameKeys[index]?.currentContext?.findRenderObject();
    // A boundary not painted yet has nothing to read; the flag exists only
    // in debug builds, where the read would assert.
    if (boundary is! RenderRepaintBoundary ||
        !boundary.attached ||
        (kDebugMode && boundary.debugNeedsPaint)) {
      return;
    }
    final frame = _pictureNow(index);
    if (frame == null) return;
    _originFrames.remove(index)?.dispose();
    _originFrames[index] = frame;
  }

  Future<ui.Image?> _captureFrame(int index) async {
    final boundary = _frameKeys[index]?.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return boundary.toImage(pixelRatio: dpr);
  }

  // --- Open -----------------------------------------------------------------

  // --- Transition hold -----------------------------------------------------

  // Held while the open or close morph runs: every other surface of the
  // scope keeps its frame and asks no decode, and preloads wait, so the
  // morph's frames have the UI isolate to themselves. The item that morphs
  // plays on.
  AssetBackgroundHold? _transitionHold;

  void _holdForTransition() {
    _transitionHold?.release();
    final item = widget.source.itemAt(_index);
    _transitionHold = _cache?.holdBackground(
      except: {if (item != null) item.key},
    );
  }

  void _releaseTransitionHold() {
    _transitionHold?.release();
    _transitionHold = null;
  }

  void _open() {
    if (!mounted) return;
    _syncVideo();
    _holdForTransition();
    _restartLoop();
    final origin = widget.bridge?.originOf(_index);
    final fitted = _fittedRect(_index, origin);
    _hide(_index, hidden: true);
    _cover(_index);
    _from = origin == null
        ? _Frame(fitted, opacity: 0)
        : _Frame(
            _shownIn(origin, fitted),
            radius: origin.radius,
            clip: origin.clip,
          );
    _to = _Frame(fitted);
    _transition
      ..duration = _policy.openDuration
      ..forward(from: 0).whenComplete(() {
        if (!mounted || _phase != _Phase.opening) return;
        _releaseTransitionHold();
        setState(() => _phase = _Phase.open);
        _session?.autoHide = true;
        _notifyController();
        _syncNeighbours();
      });
  }

  // --- Close ----------------------------------------------------------------

  /// Closes the viewer on the item it shows.
  Future<void> close() async {
    // Ignored while the viewer opens, as while it closes.
    if (_phase != _Phase.open) return;
    // Every close fades the chrome out with it, as a dismiss drag does: a
    // back press, a close button, a call from the host.
    _controls.value = false;
    // The surface the viewer closes onto gets the decoders back.
    _releaseNeighbours();
    final session = _session;
    if (session != null) {
      final position = session.lease.position;
      final item = widget.source.itemAt(_index);
      if (item != null) {
        widget.onVideoLeft?.call(_index, item, position);
        _leftReported = true;
        switch (_video.originReturn) {
          case ViewerOriginReturn.atPlayer:
            widget.bridge?.handBack(_index, position);
            // The surface's loop of the content goes to the player's place,
            // showing the player's last picture until its own frame there
            // is drawn.
            _cache?.seekPlayback(
              item.key,
              _loopSpec,
              position,
              picture: _pictureNow(_index),
            );
          case ViewerOriginReturn.restart:
            _cache?.seekPlayback(item.key, _loopSpec, Duration.zero);
          case ViewerOriginReturn.whereItPaused:
            break;
        }
      }
      _loopHold?.release();
      _loopHold = null;
      session.autoHide = false;
    }
    _restartLoop();
    if (_fullscreen) toggleFullscreen();
    final from = _fittedRect(_index, null).shift(Offset(0, _drag));
    final startBackground = backgroundOpacity;
    final bridge = widget.bridge;
    if (bridge != null && _index != widget.initialIndex) {
      _hide(widget.initialIndex, hidden: false);
      await bridge.reveal(_index);
      if (!mounted) return;
      _hide(_index, hidden: true);
    }
    final origin = bridge?.originOf(_index);
    final policy = _policy;
    _transition.stop();
    _springBack.stop();
    _holdForTransition();
    setState(() {
      _phase = _Phase.closing;
      _closeFromBackground = startBackground;
      _from = _Frame(from);
      _fadeOut = origin == null;
      if (origin != null) {
        _to = _Frame(
          _shownIn(origin, from),
          radius: origin.radius,
          clip: origin.clip,
        );
        _transition.duration = policy.closeDuration;
      } else if (_drag != 0 || policy.plainCloseSlides) {
        // The origin is gone: the picture leaves the way it was dragged
        // (down when it was not).
        _to = _Frame(
          from.shift(Offset(0, (_drag < 0 ? -1 : 1) * _size.height)),
          opacity: 0,
        );
        _transition.duration = policy.slideOffDuration;
      } else {
        final shrunk = Rect.fromCenter(
          center: from.center,
          width: from.width * policy.plainCloseScale,
          height: from.height * policy.plainCloseScale,
        );
        _to = _Frame(shrunk, opacity: 0);
        _transition.duration = policy.closeDuration;
      }
    });
    _notifyController();
    await _transition.forward(from: 0);
    if (!mounted) return;
    _releaseTransitionHold();
    _hide(_index, hidden: false);
    // The surface's overlays (a cell's check and marks) come back only once
    // the picture has landed in its place, as the close ends.
    _cover(null);
    setState(() => _phase = _Phase.closed);
    _notifyController();
    widget.onClosed?.call();
  }

  // --- Drag -----------------------------------------------------------------

  late final ViewerDragEvents _dragEvents = ViewerDragEvents(
    onStart: () {
      _springBack.stop();
      _controls.value = false;
      widget.controller?._dismissing.value = true;
    },
    onUpdate: (offset) {
      if (_phase != _Phase.open) return;
      // A policy that dismisses only downward holds the picture at rest
      // against an upward drag.
      final drag = _policy.dismissDownOnly && offset < 0 ? 0.0 : offset;
      setState(() => _drag = drag);
      _reportBackdrop();
    },
    onEnd: (offset, velocity) {
      widget.controller?._dismissing.value = false;
      if (_phase != _Phase.open) return;
      _drag = offset;
      if (_policy.dismisses(offset, _size.height, velocity: velocity)) {
        unawaited(close());
      } else {
        _springFrom = offset;
        _springBack.forward(from: 0);
        // The controls come back with the spring when the policy says so.
        if (_policy.controlsReturnOnSpringBack) _controls.value = true;
      }
    },
  );

  void _onSpringBack() {
    final t = _policy.settleCurve.transform(_springBack.value);
    setState(() => _drag = _springFrom * (1 - t));
    _reportBackdrop();
  }

  // --- Transition -----------------------------------------------------------

  void _onTransition() {
    setState(() {});
    _reportBackdrop();
  }

  // The host's own report, else the scope's shared scale.
  ValueNotifier<double>? _backdropScale;
  ValueChanged<double>? get _backdropReport =>
      widget.onBackdropScale ??
      switch (_backdropScale) {
        final scale? => (value) => scale.value = value,
        null => null,
      };

  void _reportBackdrop() {
    final report = _backdropReport;
    if (report == null || _size.height <= 0) return;
    final opened = switch (_phase) {
      _Phase.opening => _transitionT,
      _Phase.open => 1.0,
      _Phase.closing => 1 - _transitionT,
      _Phase.closed => 0.0,
    };
    final pulled = math.min(1, _drag.abs() / (_size.height / 2));
    report(1 + _policy.backdropScale * opened * (1 - pulled));
  }

  // --- Layout ---------------------------------------------------------------

  // The item's picture fitted into the viewer, in global coordinates (the
  // viewer covers the screen, so local and global agree).
  Rect _fittedRect(int index, GalleryOrigin? origin) {
    final size = _size;
    final aspect = _aspectOf(index, origin);
    if (size.isEmpty || aspect <= 0) return Offset.zero & size;
    final fitsWidth = size.width / size.height < aspect;
    final width = fitsWidth ? size.width : size.height * aspect;
    final height = fitsWidth ? size.width / aspect : size.height;
    return Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
  }

  // The picture where the origin shows it: its box for a surface that covers
  // the box with it, the part of the box it fills for one that shows it
  // whole. [fitted] has the picture's proportion.
  static Rect _shownIn(GalleryOrigin origin, Rect fitted) {
    if (fitted.isEmpty || origin.rect.isEmpty) return origin.rect;
    final shown = applyBoxFit(origin.fit, fitted.size, origin.rect.size);
    return Alignment.center.inscribe(shown.destination, origin.rect);
  }

  // The picture's proportion: the item's size, else the picture a cache
  // entry of it draws, else the player's picture, else the origin's frame or
  // box, never a square guessed for it.
  double _aspectOf(int index, GalleryOrigin? origin) {
    final item = widget.source.itemAt(index);
    final itemSize = item?.size;
    if (itemSize != null && !itemSize.isEmpty) {
      return itemSize.width / itemSize.height;
    }
    if (item?.descriptor?.dimensions case final dimensions?
        when dimensions.width > 0 && dimensions.height > 0) {
      return dimensions.width / dimensions.height;
    }
    final decoded = item == null ? null : _cache?.pictureSizeOf(item.key);
    if (decoded != null && !decoded.isEmpty) {
      return decoded.width / decoded.height;
    }
    if (_sessionIndex == index) {
      final state = _session?.lease.state.value;
      if (state?.videoSize case final video? when !video.isEmpty) {
        return state!.quarterTurns.isOdd
            ? video.height / video.width
            : video.width / video.height;
      }
    }
    if (_originFrames[index] case final frame?) {
      return frame.width / frame.height;
    }
    final rect = (origin ?? widget.bridge?.originOf(index))?.rect;
    if (rect != null && !rect.isEmpty) return rect.width / rect.height;
    return _size.isEmpty ? 1 : _size.width / _size.height;
  }

  // --- Build ----------------------------------------------------------------

  // Text below takes the viewer's style, not whatever the host has above:
  // a route with no text style of its own shows the framework's warning
  // underline.
  @override
  Widget build(BuildContext context) => MpxTextRoot.wrap(
    context,
    DefaultTextStyle.merge(
      style: widget.tokens.subtitle,
      child: _build(context),
    ),
  );

  Widget _build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      _size = constraints.biggest;
      final background = widget.tokens.background;
      final desktop = _policy.desktopInput;
      Widget viewer = PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(close());
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            IgnorePointer(
              child: ColoredBox(
                color: background.withValues(
                  alpha: background.a * backgroundOpacity.clamp(0.0, 1.0),
                ),
              ),
            ),
            if (_phase == _Phase.open)
              _pagesView()
            // Landed: the origin shows again; a picture left here for the
            // frames the route takes to go would cover it with a stale one.
            else if (_phase != _Phase.closed)
              _morph(),
            if (_session case final session? when _phase == _Phase.open)
              ValueListenableBuilder<bool>(
                valueListenable: _controls,
                builder: (context, visible, _) => ViewerVideoControls(
                  lease: session.lease,
                  rules: _video,
                  tokens: widget.tokens,
                  visible: visible,
                  showDuration: _policy.controlsDuration,
                  hideDuration: _policy.controlsHideDuration,
                  onInteraction: session.interacted,
                  onSpeed: session.setSpeed,
                  qualities: _qualities(),
                  quality: session.quality,
                  onQuality: session.setQuality,
                  previewFrame: widget.previewFrame,
                  strings: widget.videoStrings,
                  centreTaken: _spinnerShown,
                  knownDuration: widget.source
                      .itemAt(_index)
                      ?.descriptor
                      ?.duration,
                ),
              ),
            // A player that waits for its media longer than the policy's
            // delay shows the spinner in the play button's place.
            if (_session case final session? when _phase == _Phase.open)
              ViewerBufferingSpinner(
                lease: session.lease,
                rules: _policy.loading,
                presence: _spinnerShown,
                suppressed: _pageStatusShows,
              ),
            // A video that failed says so over the controls, in the
            // middle, where the play button would be.
            if (_session case final session? when _phase == _Phase.open)
              ValueListenableBuilder<PlayerState>(
                valueListenable: session.lease.state,
                builder: (context, state, _) =>
                    state.phase != PlayerPhase.failed
                    ? const SizedBox.shrink()
                    : _failure(session),
              ),
            if (widget.chrome case final chrome? when _phase == _Phase.open)
              ViewerChromeOverlay(
                chrome: chrome,
                index: _index,
                source: widget.source,
                controls: _controls,
                tokens: widget.tokens,
                policy: _policy,
                scope: widget.scope,
                bottomInset: _session == null
                    ? 0
                    : ViewerVideoControls.barHeight,
                onBack: () => unawaited(close()),
                onSelectIndex: _pageTo,
                onAction: (action, index) =>
                    unawaited(runAction(action, index)),
              ),
          ],
        ),
      );
      if (desktop) {
        viewer = Focus(
          focusNode: _focus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            onPointerPanZoomStart: _onPanZoomStart,
            onPointerPanZoomUpdate: _onPanZoomUpdate,
            // The cursor hides with a video's controls.
            child: ValueListenableBuilder<bool>(
              valueListenable: _controls,
              builder: (context, visible, child) => MouseRegion(
                onHover: _onHover,
                cursor: visible || _session == null
                    ? MouseCursor.defer
                    : SystemMouseCursors.none,
                child: child,
              ),
              child: viewer,
            ),
          ),
        );
      }
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: _systemBars(background),
        child: viewer,
      );
    },
  );

  // The system bars over the viewer: clear, so the picture runs under them
  // (the chrome brings its own scrims), with icons that read on the
  // viewer's background. Without it the bars keep the host's style: dark
  // icons lost on the black, and the platform's contrast scrim drawn over
  // the navigation bar as a band the picture stops at.
  static SystemUiOverlayStyle _systemBars(Color background) {
    final dark = background.computeLuminance() < 0.5;
    final icons = dark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: const Color(0x00000000),
      statusBarIconBrightness: icons,
      // iOS names the bar's background, not its icons.
      statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: const Color(0x00000000),
      systemNavigationBarDividerColor: const Color(0x00000000),
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  List<ViewerQuality> _qualities() {
    final item = widget.source.itemAt(_index);
    final qualitiesOf = widget.qualitiesOf;
    if (item == null || qualitiesOf == null) return const [];
    return qualitiesOf(_index, item);
  }

  Widget _pagesView() {
    final policy = _policy;
    return Transform.translate(
      offset: Offset(0, _drag),
      child: GalleryPager(
        controller: _pages,
        count: widget.source.count,
        gap: policy.pageGap,
        physics: policy.pager,
        transition: policy.transition,
        taps: policy.taps,
        // The item and its neighbours keep their state (zoom, the origin's
        // frame); preparation beyond them is the viewer's own.
        keepAlive: const GalleryKeepAlive.around(1),
        // The media references never mirror the gallery.
        textDirection: TextDirection.ltr,
        dismiss: policy.dismissClaim,
        onDismissStart: _dragEvents.onStart,
        onDismissUpdate: _dragEvents.onUpdate,
        onDismissEnd: _dragEvents.onEnd,
        onPageChanged: (index) {
          setState(() => _index = index);
          _cover(index);
          _dropOriginFrames(around: index);
          _notifyController();
          _syncVideo();
          _syncNeighbours();
          widget.source.loadAround(index);
          widget.onIndexChanged?.call(index);
        },
        pageBuilder: (context, index) => _page(index),
      ),
    );
  }

  Widget _page(int index) {
    final item = widget.source.itemAt(index);
    final fitted = _fittedRect(index, null).size;
    // An item not loaded yet is the black page with nothing on it: no box
    // stands in for media.
    if (item == null) return const SizedBox.expand();
    final policy = _policy;
    final session = _sessionIndex == index ? _session : null;
    final video = session != null;
    final still = _picture(
      index,
      item,
      fitted,
      BoxFit.contain,
      session: session,
    );
    final page = ViewerPhotoPage(
      key: _pageKeys.putIfAbsent(index, GlobalKey<ViewerPhotoPageState>.new),
      contentSize: fitted,
      policy: policy,
      drag: _dragEvents,
      maxZoom: policy.maxZoomFor(fitted, _size, pixels: item.size),
      doubleTapZoom: video && !_video.doubleTapZooms
          ? null
          : policy.doubleTapZoomFor(fitted, _size, pixels: item.size),
      onTap: switch ((session, policy.pictureClickCloses)) {
        (final playing?, _) when _video.clickPlays => playing.togglePlay,
        (null, _) when widget.onPictureTap != null =>
          () => widget.onPictureTap!(index, item),
        (null, true) => () => unawaited(close()),
        _ => () => _controls.value = !_controls.value,
      },
      onBackgroundTap: policy.backgroundClickCloses
          ? () => unawaited(close())
          : null,
      onDoubleTap: video
          ? (local, page) =>
                session.doubleTap(local, page, onFullscreen: toggleFullscreen)
          : null,
      holdDelay: video ? _video.hold?.delay : null,
      onHoldStart: (local, page) =>
          session?.holdStart(
            atFraction: page.width <= 0 ? 0 : local.dx / page.width,
          ) ??
          false,
      onHoldEnd: () => session?.holdEnd(),
      child: RepaintBoundary(
        key: _frameKeys.putIfAbsent(index, GlobalKey.new),
        child: still,
      ),
    );
    final loading = policy.loading;
    final shows = index == _index || !loading.hideStatusUntilCentral;
    if (!shows) return page;
    Widget status() => ViewerPageStatus(
      content: item.key,
      spec: _presetOf(item, _boxOf(fitted)).spec,
      kind: item.kind,
      rules: loading,
      scope: widget.scope,
      downloadContext: item.downloadContext,
      shows: video ? _pageStatusShows : null,
    );
    // A video a player plays has one centre control: the page's download
    // radial until the player's first frame (the spinner holds back while
    // it shows), then the controls' play / pause.
    if (item.kind == GalleryMediaKind.video && widget.players != null) {
      if (session == null) return page;
      return Stack(
        fit: StackFit.expand,
        children: [
          page,
          ValueListenableBuilder<PlayerState>(
            valueListenable: session.lease.state,
            builder: (context, state, _) {
              if (!state.firstFrameRendered) return status();
              if (_pageStatusShows.value) {
                SchedulerBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _pageStatusShows.value = false;
                });
              }
              return const SizedBox.shrink();
            },
          ),
        ],
      );
    }
    return Stack(fit: StackFit.expand, children: [page, status()]);
  }

  Widget _morph() {
    final from = _from;
    final to = _to;
    final item = widget.source.itemAt(_index);
    if (from == null || to == null || item == null) {
      return const SizedBox.shrink();
    }
    final t = _transitionT;
    final rect = Rect.lerp(from.rect, to.rect, t)!;
    final radius = BorderRadius.lerp(from.radius, to.radius, t)!;
    final opacity = from.opacity + (to.opacity - from.opacity) * t;
    final screen = Offset.zero & _size;
    final clip = Rect.lerp(from.clip ?? screen, to.clip ?? screen, t)!;
    final fitted = _fittedRect(_index, null).size;
    // Morphing to an origin crops the picture as the surface does; a picture
    // that fades or slides keeps its whole frame.
    final fit = _phase == _Phase.closing && _fadeOut
        ? BoxFit.contain
        : BoxFit.cover;
    return Stack(
      children: [
        Positioned.fromRect(
          key: const ValueKey('mpx-viewer-morph'),
          rect: rect,
          child: ClipRect(
            clipper: _GlobalClip(clip, rect.topLeft),
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: ClipRRect(
                borderRadius: radius,
                child: _policy.openStyle == ViewerOpenStyle.reveal
                    ? _revealed(from, to, t, rect, fitted, item)
                    : _morphPicture(item, fitted, fit),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // The reveal: the picture moves from covering the origin to its fitted
  // place on its own, and the window ([window]) it shows through grows from
  // the origin's crop to the whole picture, so the crop opens up rather
  // than the cropped picture scaling.
  Widget _revealed(
    _Frame from,
    _Frame to,
    double t,
    Rect window,
    Size fitted,
    GalleryItem item,
  ) {
    Rect covering(Rect rect) {
      if (fitted.isEmpty || rect.isEmpty) return rect;
      final scale = math.max(
        rect.width / fitted.width,
        rect.height / fitted.height,
      );
      return Rect.fromCenter(
        center: rect.center,
        width: fitted.width * scale,
        height: fitted.height * scale,
      );
    }

    final picture = Rect.lerp(covering(from.rect), covering(to.rect), t)!;
    return OverflowBox(
      alignment: Alignment.topLeft,
      minWidth: 0,
      minHeight: 0,
      maxWidth: double.infinity,
      maxHeight: double.infinity,
      child: Transform.translate(
        offset: picture.topLeft - window.topLeft,
        child: SizedBox.fromSize(
          size: picture.size,
          child: _morphPicture(item, fitted, BoxFit.contain),
        ),
      ),
    );
  }

  // The cache the pictures attach to.
  // Read without depending on the provider: the video session starts from
  // initState, and a changed provider reaches the pages through their own
  // views.
  AssetCacheScope? get _cache =>
      widget.scope ??
      context.getInheritedWidgetOfExactType<AssetCacheProvider>()?.scope;

  // The spec of content that plays, whatever the box: a surface that shows
  // the same content as an animation binds the same entry, so the viewer
  // draws the surface's own playback and hands a video's position back to it.
  static final AssetSpec _loopSpec = AssetPresets.animation(
    size: Size.zero,
    profile: const AssetProfile(),
  ).spec;

  // The picture the morph moves: a video's player over its picture, so the
  // close shows where the player stands.
  Widget _morphPicture(GalleryItem item, Size size, BoxFit fit) {
    // Closed, the viewer stops showing the player, which lets it pause.
    final session = _sessionIndex == _index && _phase != _Phase.closed
        ? _session
        : null;
    return _picture(_index, item, size, fit, session: session);
  }

  // What a video that cannot be played shows, by the policy: nothing (its
  // page keeps its picture and play tries again), the alert offering
  // another app, or the card with Retry.
  Widget _failure(ViewerVideoSession session) {
    final open = widget.onOpenElsewhere;
    final item = widget.source.itemAt(_index);
    return switch (_video.failure) {
      ViewerVideoFailure.silent => const SizedBox.shrink(),
      ViewerVideoFailure.alert when open != null && item != null => Center(
        child: ViewerVideoFailureAlert(
          strings: widget.videoStrings,
          tokens: widget.tokens,
          onOpen: () => unawaited(open(_index, item)),
          onCancel: () => _dismissedFailure.value = session,
          dismissed: _dismissedFailure,
          session: session,
        ),
      ),
      _ => Center(
        child: ViewerVideoFailureCard(
          strings: widget.videoStrings,
          tokens: widget.tokens,
          onRetry: session.retry,
        ),
      ),
    };
  }

  // The session whose failure alert was dismissed: it shows no more.
  final ValueNotifier<ViewerVideoSession?> _dismissedFailure = ValueNotifier(
    null,
  );

  // The picture of [item]: the item's own content, with the origin's frame
  // standing in until the content shows. [size] is the box, kept the same
  // through the morph so the morph never attaches again. Content that plays
  // (an animation, the loop of a video) binds the spec every surface binds
  // it at, so the page draws the surface's own playback, not a second one.
  //
  // With [session], the video's player goes over the picture in the same box
  // and with the same fit, so the two never part by a pixel at the edge.
  Widget _picture(
    int index,
    GalleryItem item,
    Size size,
    BoxFit fit, {
    ViewerVideoSession? session,
  }) {
    final box = _boxOf(size);
    _know(item);
    final frame = _originFrame(index);
    Widget picture = _OriginContent(
      frame: frame,
      originFit: widget.bridge?.originOf(index)?.fit ?? BoxFit.cover,
      content: item.key,
      scope: widget.scope,
      preset: _presetOf(item, box),
      downloadContext: item.downloadContext,
      requestsDownload: _requestsDownload(index, item),
    );
    // With no frame of its own to stand in (the page left long ago, its
    // origin not on screen), the item's sharp still lies under the picture,
    // so a new player's start is never black.
    if (item.standIn case final still? when frame == null) {
      picture = Stack(
        fit: StackFit.expand,
        children: [
          AssetView(
            content: still.key,
            scope: widget.scope,
            preset: AssetPresets.square(
              extent: math.max(box.width, box.height),
              devicePixelRatio:
                  MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
              profile: const AssetProfile(fit: AssetFit.cover),
            ),
          ),
          picture,
        ],
      );
    }
    return FittedBox(
      fit: fit,
      clipBehavior: Clip.hardEdge,
      child: SizedBox.fromSize(
        size: box,
        child: session == null
            ? picture
            // The player fills the box the picture fills: the box has the
            // content's proportion, so covering it crops nothing visible.
            : _PlayerOverPicture(
                lease: session.lease,
                picture: picture,
                fit: BoxFit.cover,
                shown: identical(_movingSession, session),
                onMoving: () => _movingSession = session,
                rules: _policy.loading,
                showsPaused: !_video.autoplay,
              ),
      ),
    );
  }

  static Size _boxOf(Size size) => size.isEmpty ? const Size(1, 1) : size;

  final KnownDescriptors _known = KnownDescriptors();

  // Tells the cache what the host knows about [item] before a page of it
  // attaches: its preview and thumbnail show though the cache never saw it.
  void _know(GalleryItem item) {
    _known.tell(_cache, item.descriptor);
    _known.tell(_cache, item.standIn);
  }

  // Whether the page of [item] at [index] asks for its content whatever the
  // auto-download policy says: the page shown, which the user opened or
  // paged to. A video is asked for only when the viewer opened on it; one
  // paged to follows the policy (a player streams it, else its page offers
  // the download). The neighbours follow the policy.
  bool _requestsDownload(int index, GalleryItem item) =>
      index == _index &&
      (item.kind != GalleryMediaKind.video || item.key == _opened);

  // The size, decode and use of [item]'s content in a box of [box].
  AssetPreset _presetOf(GalleryItem item, Size box) {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    const loops = AssetProfile(animate: true, loop: true);
    return switch (item.kind) {
      // A GIF loops muted on the software path: the origin's own
      // playback, or one of the page's own at the page's size.
      GalleryMediaKind.animation => switch (_video.loopOpen) {
        ViewerLoopOpen.continues || ViewerLoopOpen.restart =>
          AssetPresets.animation(size: box, profile: loops),
        ViewerLoopOpen.own => AssetPresets.media(
          size: box,
          devicePixelRatio: dpr,
          profile: loops,
        ),
      },
      // A video's loop shows the frame it stands on until the player
      // has one: the player is the one playback of it meanwhile.
      GalleryMediaKind.video => AssetPresets.animation(
        size: box,
        profile: const AssetProfile(),
      ),
      GalleryMediaKind.photo => AssetPresets.media(
        size: box,
        devicePixelRatio: dpr,
        profile: const AssetProfile(animate: true),
      ),
    };
  }
}

/// The content of a page, with the origin's [frame] as its placeholder: the
/// view draws it over the content's preview and thumbnail until the content
/// has its first frame, and the content fades in over it, the frame staying
/// opaque (it fades out only under content that may be transparent).
/// Without a frame the content's stand-ins show in turn (preview,
/// thumbnail), on nothing.
///
/// The placeholder holds a clone of [frame], so the viewer freeing its copy
/// as it leaves the page never frees one a view still draws.
class _OriginContent extends StatefulWidget {
  const _OriginContent({
    required this.frame,
    required this.originFit,
    required this.content,
    required this.scope,
    required this.preset,
    required this.downloadContext,
    required this.requestsDownload,
  });

  final ui.Image? frame;

  /// How the origin fitted the picture into its box, which [frame] shows.
  final BoxFit originFit;
  final MediaKey content;
  final AssetCacheScope? scope;
  final AssetPreset preset;
  final AutoDownloadContext? downloadContext;
  final bool requestsDownload;

  @override
  State<_OriginContent> createState() => _OriginContentState();
}

class _OriginContentState extends State<_OriginContent> {
  _OriginFrame? _standIn;

  @override
  void initState() {
    super.initState();
    _standIn = _standInFor(widget.frame, widget.originFit);
  }

  @override
  void didUpdateWidget(_OriginContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.frame, oldWidget.frame) &&
        widget.originFit == oldWidget.originFit) {
      return;
    }
    _standIn?.dispose();
    _standIn = _standInFor(widget.frame, widget.originFit);
  }

  @override
  void dispose() {
    _standIn?.dispose();
    super.dispose();
  }

  static _OriginFrame? _standInFor(ui.Image? frame, BoxFit fit) =>
      frame == null ? null : _OriginFrame(frame.clone(), fit);

  @override
  Widget build(BuildContext context) => AssetView(
    content: widget.content,
    scope: widget.scope,
    preset: widget.preset,
    placeholder: _standIn ?? const ClearPlaceholder(),
    // The origin's frame is sharper than the content's preview and
    // thumbnail: it stays over them until the first frame.
    placeholderUntil: _standIn == null
        ? AssetStage.none
        : AssetStage.firstFrame,
    downloadContext: widget.downloadContext,
    // Opening the viewer on an item is the user's request for its content:
    // it downloads whatever the auto-download policy said in the list.
    requestsDownload: widget.requestsDownload,
  );
}

/// The origin's frame as a placeholder: the part of it that shows the
/// picture, placed where that part of the picture lies in the box, in its own
/// colours.
///
/// The frame is the origin's box: a picture it fitted whole (letterboxed) or
/// cropped. Drawn whole over the box it would place the picture at another
/// scale than the content drawn over it, and the two would part at the edge.
final class _OriginFrame extends AssetPaintable {
  /// Draws [image], which it owns from now on, an origin's box that fitted
  /// the picture as [fit] says.
  _OriginFrame(this._image, this._fit);

  final ui.Image _image;
  final BoxFit _fit;

  @override
  AtlasSprite? get sprite => null;

  @override
  bool get isAnimated => false;

  @override
  bool get isHolding => false;

  @override
  bool restart() => false;

  // [rect] has the picture's proportion: fitting it into the frame as the
  // origin did gives the part of the frame that is the picture
  // (destination) and the part of the picture it shows (source).
  @override
  void paint(Canvas canvas, Rect rect, AssetPaintContext context) {
    if (rect.isEmpty) return;
    final frame = Size(_image.width.toDouble(), _image.height.toDouble());
    final fitted = applyBoxFit(_fit, rect.size, frame);
    canvas.drawImageRect(
      _image,
      Alignment.center.inscribe(fitted.destination, Offset.zero & frame),
      Alignment.center.inscribe(fitted.source, rect),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, context.opacity),
    );
  }

  @override
  void dispose() => _image.dispose();
}

/// One end of a morph.
@immutable
final class _Frame {
  const _Frame(
    this.rect, {
    this.radius = BorderRadius.zero,
    this.clip,
    this.opacity = 1,
  });

  final Rect rect;
  final BorderRadius radius;
  final Rect? clip;
  final double opacity;
}

// Clips to [clip], given in the viewer's coordinates, for a child placed at
// [origin].
final class _GlobalClip extends CustomClipper<Rect> {
  const _GlobalClip(this.clip, this.origin);

  final Rect clip;
  final Offset origin;

  @override
  Rect getClip(Size size) => clip.shift(-origin);

  @override
  bool shouldReclip(_GlobalClip oldClipper) =>
      oldClipper.clip != clip || oldClipper.origin != origin;
}

/// A video's player over its picture: the picture alone until the player
/// moves (playing, its first frame drawn and its position past where it
/// first stood), then the player, faded in over it.
///
/// A cold player draws its first frame, at its start, a moment before it
/// plays: shown at once that frame stood in for the origin's and stood
/// still, a jump and a freeze before playback. A warm one moves at once and
/// shows at once.
///
/// A player the policy leaves paused ([showsPaused]) shows once its first
/// frame is drawn: it will not move by itself, and that frame is the sharp
/// picture the blurred stand-in waited for.
class _PlayerOverPicture extends StatefulWidget {
  const _PlayerOverPicture({
    required this.lease,
    required this.picture,
    required this.fit,
    required this.shown,
    required this.onMoving,
    required this.rules,
    this.showsPaused = false,
  });

  final PlayerLease lease;
  final Widget picture;
  final BoxFit fit;

  /// Whether a paused player shows once its first frame is drawn, sharp
  /// over the blurred picture: a policy that does not autoplay leaves the
  /// player paused at its start, and its picture is that frame, so nothing
  /// jumps.
  final bool showsPaused;

  /// How long the player fades in.
  final ViewerLoadingRules rules;

  /// Whether the player has moved already, under another picture of the
  /// item: it shows from the start.
  final bool shown;

  /// Called once the player moves.
  final VoidCallback onMoving;

  @override
  State<_PlayerOverPicture> createState() => _PlayerOverPictureState();
}

class _PlayerOverPictureState extends State<_PlayerOverPicture>
    with SingleTickerProviderStateMixin {
  late final Ticker _watch;
  // Whether the player had its first frame when the page took it: handed
  // over from another surface, or kept warm.
  late bool _handedOver = widget.lease.state.value.firstFrameRendered;
  // Where the player stood when its first frame was seen; null before.
  Duration? _firstAt;
  bool _moving = false;
  // Whether the player shows fully, over a picture no longer painted.
  bool _covered = false;

  @override
  void initState() {
    super.initState();
    _watch = createTicker(_check);
    _moving = widget.shown;
    _covered = widget.shown;
    if (!_moving) _watch.start();
  }

  @override
  void didUpdateWidget(_PlayerOverPicture oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.lease, oldWidget.lease)) return;
    _handedOver = widget.lease.state.value.firstFrameRendered;
    _firstAt = null;
    _moving = widget.shown;
    _covered = widget.shown;
    if (!_moving && !_watch.isActive) _watch.start();
  }

  void _check(Duration _) {
    final state = widget.lease.state.value;
    if (!state.firstFrameRendered) return;
    if (!state.playing) {
      if (!widget.showsPaused) return;
      _watch.stop();
      setState(() => _moving = true);
      widget.onMoving();
      return;
    }
    final position = widget.lease.position;
    final first = _firstAt ??= position;
    if (position == first) return;
    _watch.stop();
    setState(() => _moving = true);
    widget.onMoving();
  }

  @override
  void dispose() {
    _watch.dispose();
    super.dispose();
  }

  // The player's view is there from the start, transparent: it counts as a
  // view of the player for the pool, and its texture is ready to show. Once
  // it is opaque the picture under it is not painted: two layers inside one
  // rounded clip each blend their edge, and the lower one shows as a rim.
  // A player that failed shows nothing: its picture comes back under the
  // failure, rather than black.
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlayerState>(
    valueListenable: widget.lease.state,
    builder: (context, state, _) =>
        _layers(covered: _covered && state.phase != PlayerPhase.failed),
  );

  Widget _layers({required bool covered}) => Stack(
    fit: StackFit.expand,
    children: [
      Opacity(opacity: covered ? 0 : 1, child: widget.picture),
      TweenAnimationBuilder<double>(
        key: const ValueKey('mpx-viewer-player'),
        tween: Tween(begin: widget.shown ? 1 : 0, end: _moving ? 1 : 0),
        duration: widget.shown
            ? Duration.zero
            : widget.rules.playerFadeInFor(handedOver: _handedOver),
        // A fade that ends inside a build (a zero one) cannot rebuild
        // there: the picture goes on the next frame.
        onEnd: () => SchedulerBinding.instance.addPostFrameCallback((_) {
          if (_moving && !_covered && mounted) setState(() => _covered = true);
        }),
        builder: (context, opacity, child) =>
            Opacity(opacity: opacity, child: child),
        child: PlayerView(lease: widget.lease, fit: widget.fit),
      ),
    ],
  );
}
