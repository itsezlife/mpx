import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';

/// The spinner over a player that waits for its media: buffering, or not
/// at its first frame yet. It shows only once the wait has lasted
/// [ViewerLoadingRules.bufferingDelay], so a short spell shows nothing,
/// fades in over [ViewerLoadingRules.bufferingFade], and goes at once when
/// playback goes on.
///
/// It takes no taps; the picture under it keeps its gestures.
class ViewerBufferingSpinner extends StatefulWidget {
  /// Creates the spinner of [lease] by [rules].
  const ViewerBufferingSpinner({
    required this.lease,
    required this.rules,
    this.presence,
    this.suppressed,
    super.key,
  });

  /// While true, another control holds the centre (the page's download
  /// radial, [ViewerPageStatus.shows]) and the spinner does not show over it.
  final ValueListenable<bool>? suppressed;

  /// Told how much the spinner shows, 0 to 1, as it fades in and goes: the
  /// share of the centre it takes from the play button
  /// ([ViewerVideoControls.centreTaken]).
  final ValueNotifier<double>? presence;

  /// The player watched.
  final PlayerLease lease;

  /// The delay, the fade and the control's style.
  final ViewerLoadingRules rules;

  /// Whether a player in [state] waits for its media: it buffers, or it has
  /// no first frame while it prepares or stands ready.
  static bool waits(PlayerState state) => switch (state.phase) {
    PlayerPhase.buffering => true,
    PlayerPhase.preparing || PlayerPhase.ready => !state.firstFrameRendered,
    PlayerPhase.idle || PlayerPhase.ended || PlayerPhase.failed => false,
  };

  @override
  State<ViewerBufferingSpinner> createState() => _ViewerBufferingSpinnerState();
}

class _ViewerBufferingSpinnerState extends State<ViewerBufferingSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  Timer? _delay;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: widget.rules.bufferingFade,
    )..addListener(_tellPresence);
    widget.lease.state.addListener(_onState);
    _onState();
  }

  @override
  void didUpdateWidget(ViewerBufferingSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    _fade.duration = widget.rules.bufferingFade;
    if (identical(widget.lease, oldWidget.lease)) return;
    oldWidget.lease.state.removeListener(_onState);
    widget.lease.state.addListener(_onState);
    // The build that follows shows the new state: no setState in an update.
    _hide(rebuild: false);
    _onState();
  }

  @override
  void dispose() {
    widget.lease.state.removeListener(_onState);
    _delay?.cancel();
    _fade.dispose();
    super.dispose();
  }

  void _onState() {
    if (!ViewerBufferingSpinner.waits(widget.lease.state.value)) {
      _hide();
      return;
    }
    if (_shown || _delay != null) return;
    _delay = Timer(widget.rules.bufferingDelay, _show);
  }

  void _show() {
    _delay = null;
    if (!mounted) return;
    setState(() => _shown = true);
    unawaited(_fade.forward(from: 0));
  }

  // The presence is heard by the play button, outside this subtree: a change
  // made while the tree builds (a new lease handed over in didUpdateWidget)
  // is told after that frame.
  void _tellPresence() {
    final presence = widget.presence;
    if (presence == null) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) presence.value = _fade.value;
      });
      return;
    }
    presence.value = _fade.value;
  }

  void _hide({bool rebuild = true}) {
    _delay?.cancel();
    _delay = null;
    if (!_shown) return;
    _fade.value = 0;
    if (!rebuild) {
      _shown = false;
    } else if (mounted) {
      setState(() => _shown = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown) return const SizedBox.shrink();
    final suppressed = widget.suppressed;
    if (suppressed == null) return _spinner();
    return ValueListenableBuilder<bool>(
      valueListenable: suppressed,
      builder: (context, held, _) =>
          held ? const SizedBox.shrink() : _spinner(),
    );
  }

  Widget _spinner() => IgnorePointer(
    child: Center(
      child: FadeTransition(
        opacity: _fade,
        child: MediaStatusControl(
          status: const MediaStatus.spinner(),
          style: widget.rules.status,
        ),
      ),
    ),
  );
}

/// The status control of a viewer page's content: what a page whose
/// picture is not there yet shows over it, centred and at the rules' size
/// whatever the page's zoom.
///
/// A photo that downloads shows
/// [ViewerLoadingRules.photoProgress] (a spinner, or an arc of the bytes)
/// once it has loaded for [ViewerLoadingRules.photoProgressDelay]; a video
/// or an animation (a GIF)
/// shows cancel and an arc. Content that waits for the user, or whose
/// download failed, shows download, which downloads (the retry). Content
/// that shows its first frame, or is in the cache, shows nothing.
///
/// It attaches the page's entry ([content] as [spec]) to read its transfer,
/// as the page's own view does: one entry, one download.
class ViewerPageStatus extends StatefulWidget {
  /// Creates the status of [content] decoded as [spec], an item of [kind].
  const ViewerPageStatus({
    required this.content,
    required this.spec,
    required this.kind,
    required this.rules,
    this.scope,
    this.downloadContext,
    this.strings = const MediaStatusStrings(),
    this.shows,
    super.key,
  });

  /// Told whether the control shows anything, after the frame it changed
  /// in: a buffering spinner of the same page holds back while it does
  /// ([ViewerBufferingSpinner.suppressed]), so the centre has one control.
  final ValueNotifier<bool>? shows;

  /// Which content.
  final MediaKey content;

  /// The spec the page's view decodes it at.
  final AssetSpec spec;

  /// What kind of item the page shows.
  final GalleryMediaKind kind;

  /// The control's style and the photo progress.
  final ViewerLoadingRules rules;

  /// The cache, instead of the closest `AssetCacheProvider`'s.
  final AssetCacheScope? scope;

  /// The surface's tag for the auto-download policy.
  final AutoDownloadContext? downloadContext;

  /// What a screen reader says.
  final MediaStatusStrings strings;

  @override
  State<ViewerPageStatus> createState() => _ViewerPageStatusState();
}

class _ViewerPageStatusState extends State<ViewerPageStatus> {
  AssetBinding? _binding;
  AssetCacheScope? _scope;
  MediaStatus _status = MediaStatus.none;
  Timer? _delay;
  // Whether the photo progress waited its delay for the download under way.
  bool _delayed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attach();
  }

  @override
  void didUpdateWidget(ViewerPageStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.content != oldWidget.content ||
        widget.spec != oldWidget.spec ||
        widget.downloadContext != oldWidget.downloadContext) {
      _detach();
    }
    _attach();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  void _attach() {
    final scope = widget.scope ?? AssetCacheProvider.maybeOf(context);
    if (identical(scope, _scope) && _binding != null) return;
    _detach();
    _scope = scope;
    if (scope == null) return;
    _binding = scope.attach(
      widget.content,
      widget.spec,
      const AssetProfile(),
      downloadContext: widget.downloadContext,
    )..addListener(_onBinding);
    _sync();
  }

  void _detach() {
    _delay?.cancel();
    _delay = null;
    _delayed = false;
    _binding
      ?..removeListener(_onBinding)
      ..detach();
    _binding = null;
    _scope = null;
    _setStatus(MediaStatus.none);
  }

  // The binding changes in builds too (a tile of the content mounting, a
  // picture in memory): the page rebuilds after that frame, never inside
  // another widget's build.
  void _onBinding() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_syncScheduled) return;
      _syncScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _syncScheduled = false;
        if (mounted) setState(_sync);
      });
      return;
    }
    setState(_sync);
  }

  bool _syncScheduled = false;

  // Reads the status and keeps the photo progress's delay in step with it:
  // the timer runs while a photo downloads below its first frame and has
  // not waited its delay yet.
  void _sync() {
    final binding = _binding;
    final downloading =
        binding != null &&
        widget.kind == GalleryMediaKind.photo &&
        binding.transfer.isActive &&
        binding.readiness.stage.index < AssetStage.firstFrame.index;
    if (!downloading) {
      _delay?.cancel();
      _delay = null;
      _delayed = false;
    } else if (!_delayed && _delay == null) {
      final wait = widget.rules.photoProgressDelay;
      if (wait > Duration.zero) {
        _delay = Timer(wait, () {
          _delay = null;
          _delayed = true;
          _onBinding();
        });
      } else {
        _delayed = true;
      }
    }
    _setStatus(_read());
  }

  void _setStatus(MediaStatus status) {
    if (status == _status) return;
    _status = status;
    _tellShows();
  }

  // Tells [ViewerPageStatus.shows] after the frame the status changed in:
  // it changes in builds and while the tree is locked.
  void _tellShows() {
    final shows = widget.shows;
    if (shows == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) shows.value = _status.isVisible;
    });
  }

  // What the control shows now; reads only.
  MediaStatus _read() {
    final binding = _binding;
    if (binding == null) return MediaStatus.none;
    final transfer = binding.transfer;
    final stage = binding.readiness.stage;
    // A video and an animation (a GIF) show cancel and the arc of their
    // bytes alike, one radial for both; a photo shows the policy's photo
    // progress.
    if (widget.kind != GalleryMediaKind.photo ||
        !transfer.isActive ||
        stage.index >= AssetStage.firstFrame.index) {
      return MediaStatus.forTransfer(transfer, stage);
    }
    if (!_delayed) return MediaStatus.none;
    return switch (widget.rules.photoProgress) {
      ViewerPhotoProgress.spinner => const MediaStatus.spinner(),
      ViewerPhotoProgress.arc => MediaStatus.progress(
        transfer.fraction,
        icon: MediaStatusIcon.none,
      ),
    };
  }

  void _onTap() {
    final binding = _binding;
    if (binding == null) return;
    switch (_status.icon) {
      case MediaStatusIcon.download:
        binding.download();
      case MediaStatusIcon.cancel:
        binding.cancelDownload();
      case MediaStatusIcon.none ||
          MediaStatusIcon.play ||
          MediaStatusIcon.pause:
        break;
    }
  }

  // Only an icon takes taps: the page under a spinner, an arc or nothing
  // keeps its gestures (paging, zoom, dismiss).
  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: _status.icon == MediaStatusIcon.none,
    child: Center(
      child: MediaStatusControl(
        status: _status,
        onTap: _onTap,
        style: widget.rules.status,
        strings: widget.strings,
      ),
    ),
  );
}

/// A player over its stand-in: the stand-in until the player has its first
/// frame, then the player faded in over it for [fadeIn], after which the
/// stand-in is no longer painted. A player that had its first frame when
/// the view was built shows after [handedOverFadeIn]; a player that fails
/// shows the stand-in again.
class PlayerOverStandIn extends StatefulWidget {
  /// Creates the view of [lease] over [standIn].
  const PlayerOverStandIn({
    required this.lease,
    required this.standIn,
    required this.fadeIn,
    required this.handedOverFadeIn,
    this.fit = BoxFit.contain,
    super.key,
  });

  /// The player.
  final PlayerLease lease;

  /// What shows until the player's first frame.
  final Widget standIn;

  /// How long a player fades in over the stand-in.
  final Duration fadeIn;

  /// How long a player that already had its first frame fades in.
  final Duration handedOverFadeIn;

  /// How the player's picture fills the view.
  final BoxFit fit;

  @override
  State<PlayerOverStandIn> createState() => _PlayerOverStandInState();
}

class _PlayerOverStandInState extends State<PlayerOverStandIn> {
  late bool _handedOver = widget.lease.state.value.firstFrameRendered;
  // Whether the player shows fully, over a stand-in no longer painted.
  bool _covered = false;

  @override
  void didUpdateWidget(PlayerOverStandIn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.lease, oldWidget.lease)) return;
    _handedOver = widget.lease.state.value.firstFrameRendered;
    _covered = false;
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<PlayerState>(
    valueListenable: widget.lease.state,
    builder: (context, state, _) {
      final shows =
          state.firstFrameRendered && state.phase != PlayerPhase.failed;
      final covered = _covered && shows;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (!covered) widget.standIn,
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: shows ? 1 : 0),
            duration: _handedOver ? widget.handedOverFadeIn : widget.fadeIn,
            // A fade that ends inside a build (a zero one) cannot rebuild
            // there: the stand-in goes on the next frame.
            onEnd: () => SchedulerBinding.instance.addPostFrameCallback((_) {
              final now = widget.lease.state.value;
              if (!mounted || _covered || !now.firstFrameRendered) return;
              setState(() => _covered = true);
            }),
            builder: (context, opacity, child) =>
                Opacity(opacity: opacity, child: child),
            child: PlayerView(lease: widget.lease, fit: widget.fit),
          ),
        ],
      );
    },
  );
}
