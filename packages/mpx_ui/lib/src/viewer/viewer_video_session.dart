import 'dart:async';
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/src/viewer/gallery_source.dart';
import 'package:mpx_ui/src/viewer/viewer_policy.dart';
import 'package:mpx_ui/src/viewer/viewer_video.dart';

/// The playback of one video item as a viewer runs it, by the policy's
/// [ViewerVideoRules]: one lease on [players], the loop rule, the end of a
/// pass that does not loop, the auto-hide of the controls, seeking, speed,
/// quality, the double-tap seek and the held press.
///
/// The logic a `MediaViewer` and a `ViewerVideoPage` share; each draws the
/// picture and the controls its own way. [controls] is the visibility it
/// hides after the policy's wait while the video plays (only while
/// [autoHide] is on) and shows again on any interaction.
///
/// Listeners hear when the lease changes (a new quality). [dispose] releases
/// the lease; the pool keeps the player warm until its budget needs it.
final class ViewerVideoSession extends ChangeNotifier {
  /// Leases [item] on [players] (or [quality]'s media), at the speed
  /// [speeds] keeps for it, from [startAt], playing when [play] says.
  ViewerVideoSession({
    required this.players,
    required this.item,
    required this.rules,
    required this.controls,
    ViewerSpeeds? speeds,
    ViewerQuality? quality,
    Duration? startAt,
    bool play = true,
    bool autoHide = false,
  }) : speeds = speeds ?? ViewerSpeeds(),
       _quality = quality,
       _autoHide = autoHide {
    controls.addListener(_scheduleAutoHide);
    _lease = _leaseAt(startAt, play: play);
    _scheduleAutoHide();
  }

  /// The players.
  final PlayerPool players;

  /// The item played.
  final GalleryItem item;

  /// The rules.
  final ViewerVideoRules rules;

  /// Whether the controls show.
  final ValueNotifier<bool> controls;

  /// Where chosen speeds are kept.
  final ViewerSpeeds speeds;

  late PlayerLease _lease;
  ViewerQuality? _quality;
  bool _autoHide;
  bool _wasPlaying = false;
  double? _heldFrom;
  Timer? _hideTimer;
  bool _disposed = false;

  /// Whether something the controls opened (a menu, the settings) keeps them
  /// shown: they do not hide by themselves while it is open.
  bool get hold => _hold;
  set hold(bool value) {
    if (value == _hold) return;
    _hold = value;
    _scheduleAutoHide();
  }

  bool _hold = false;
  int _touches = 0;

  /// A finger went down on the viewer: the controls do not hide while any is
  /// down; every touch cancels the hide.
  void touchDown() {
    _touches++;
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  /// A finger left: the wait starts again once none is down.
  void touchUp() {
    if (_touches > 0) _touches--;
    _scheduleAutoHide();
  }

  /// The lease the item plays on.
  PlayerLease get lease => _lease;

  /// The quality chosen, or null for the item's own media.
  ViewerQuality? get quality => _quality;

  /// Whether the controls hide by themselves while the video plays: on
  /// once the viewer is open.
  bool get autoHide => _autoHide;
  set autoHide(bool value) {
    if (value == _autoHide) return;
    _autoHide = value;
    _scheduleAutoHide();
  }

  PlayerLease _leaseAt(Duration? startAt, {required bool play}) {
    final memory = rules.speed.memory;
    final lease = players.lease(_quality?.key ?? item.key)
      ..setSpeed(speeds.speedFor(item.key, memory));
    // A warm player knows its duration already; a new one gets its loop rule
    // when the duration arrives (_onState).
    lease.setLooping(
      looping: rules.loops(lease.state.value.duration, hasAudio: item.hasAudio),
    );
    if (startAt != null) lease.seekTo(startAt);
    if (play) {
      lease.play();
    } else {
      lease.prepare();
    }
    _wasPlaying = lease.state.value.playing;
    lease.state.addListener(_onState);
    return lease;
  }

  void _onState() {
    if (_disposed) return;
    final state = _lease.state.value;
    final loops = rules.loops(state.duration, hasAudio: item.hasAudio);
    if (state.duration != null && loops != state.looping) {
      _lease.setLooping(looping: loops);
    }
    if (state.phase == PlayerPhase.ended && !state.looping) {
      // The end of a pass that does not loop: back to the start, paused,
      // with the controls shown.
      _lease
        ..pause()
        ..seekTo(Duration.zero);
      controls.value = true;
    }
    if (state.playing != _wasPlaying) {
      _wasPlaying = state.playing;
      _scheduleAutoHide();
    }
  }

  // Hides the controls after the policy's wait while the video plays with
  // them shown; any interaction starts the wait again.
  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
    if (_disposed ||
        !_autoHide ||
        _hold ||
        _touches > 0 ||
        !rules.autoHides ||
        !controls.value ||
        !_lease.state.value.playing) {
      return;
    }
    _hideTimer = Timer(rules.autoHide, () {
      if (!_disposed) controls.value = false;
    });
  }

  /// Shows the controls and starts the auto-hide wait again.
  void interacted() {
    if (!controls.value) controls.value = true;
    _scheduleAutoHide();
  }

  /// Seeks by [delta], clamped to the video.
  void seekBy(Duration delta) {
    final duration = _lease.state.value.duration;
    var target = _lease.position + delta;
    if (target.isNegative) target = Duration.zero;
    if (duration != null && target > duration) target = duration;
    _lease.seekTo(target);
    interacted();
  }

  /// Seeks to [fraction] (0 to 1) of the video; nothing while its duration
  /// is unknown.
  void seekToFraction(double fraction) {
    final duration = _lease.state.value.duration;
    if (duration == null) return;
    _lease.seekTo(duration * fraction.clamp(0.0, 1.0));
    interacted();
  }

  /// Plays a paused video, pauses a playing one.
  void togglePlay() {
    if (_lease.state.value.playing) {
      _lease.pause();
    } else {
      _lease.play();
    }
    interacted();
  }

  /// Plays a video that failed again: the pool makes it a new engine.
  void retry() {
    _lease.play();
    interacted();
  }

  /// Plays at [speed], kept as the policy's speed memory says.
  void setSpeed(double speed) {
    _lease.setSpeed(speed);
    _heldFrom = null;
    speeds.remember(item.key, speed, rules.speed.memory);
    interacted();
  }

  /// Moves to [quality] at the same position and play state.
  void setQuality(ViewerQuality quality) {
    if (quality.key == _lease.key) return;
    final position = _lease.position;
    final playing = _lease.state.value.playing;
    _release();
    _quality = quality;
    _lease = _leaseAt(position, play: playing);
    notifyListeners();
  }

  /// Takes a double tap at [local] on a page of [page] size: seeks when the
  /// policy's double-tap seek covers the point, else asks [onFullscreen]
  /// when the policy toggles fullscreen. False when it took nothing, and the
  /// page zooms.
  bool doubleTap(Offset local, Size page, {VoidCallback? onFullscreen}) {
    final seek = rules.doubleTapSeek?.seekAt(
      local.dx,
      page.width,
      duration: _lease.state.value.duration,
      position: _lease.position,
    );
    if (seek != null) {
      seekBy(seek);
      return true;
    }
    if (rules.doubleTapFullscreen && onFullscreen != null) {
      onFullscreen();
      return true;
    }
    return false;
  }

  /// A press held on the page plays faster, as the policy's hold rule says,
  /// when it lands at [atFraction] of the width inside the rule's zone (any
  /// point when null).
  ///
  /// True when the press plays faster; false when the rule leaves it (no
  /// rule, paused, too short, outside the zone).
  bool holdStart({double? atFraction}) {
    final hold = rules.hold;
    final state = _lease.state.value;
    if (hold == null || !state.playing) return false;
    if (atFraction != null && atFraction < hold.zoneFrom) return false;
    if (hold.minDuration > Duration.zero &&
        (state.duration == null || state.duration! < hold.minDuration)) {
      return false;
    }
    final current = state.speed;
    _heldFrom = current;
    _lease.setSpeed(hold.heldRate(current));
    return true;
  }

  /// The held press ended: back to the speed before it.
  void holdEnd() {
    final from = _heldFrom;
    _heldFrom = null;
    if (from != null) _lease.setSpeed(from);
  }

  void _release() {
    _lease.state.removeListener(_onState);
    _lease.release();
    _heldFrom = null;
  }

  /// Releases the lease. Idempotent.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _hideTimer?.cancel();
    controls.removeListener(_scheduleAutoHide);
    _release();
    super.dispose();
  }
}
