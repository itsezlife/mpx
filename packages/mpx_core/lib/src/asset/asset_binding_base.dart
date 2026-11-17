import 'dart:ui';

import 'package:listen/listen.dart';
import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_paintable.dart';
import 'package:mpx_core/src/asset/asset_playback.dart';
import 'package:mpx_core/src/asset/asset_profile.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';
import 'package:mpx_core/src/asset/asset_spec.dart';
import 'package:mpx_core/src/asset/asset_transfer.dart';
import 'package:mpx_core/src/asset/outline_paintable.dart';
import 'package:mpx_core/src/identity/media_descriptor.dart';
import 'package:mpx_core/src/identity/media_key.dart';
import 'package:mpx_core/src/playback/playback_clock.dart';

/// What every binding shares, whatever media form is behind it: identity,
/// listeners, the visible flag, the detached state and painting through the
/// scope's clock. A form adds what it reads ([liveReadiness], [livePaintable])
/// and what it gives back at detach ([releaseResources]).
///
/// Internal to the package: bindings are created by `AssetCacheScope`.
@internal
abstract base class AssetBindingBase
    with ChangeNotifier
    implements AssetBinding {
  /// Creates the shared part of a binding of [key] decoded as [spec].
  AssetBindingBase({
    required this.key,
    required this.spec,
    required this.profile,
    required AssetPaintable placeholder,
    required PlaybackClock clock,
    bool backgroundHeld = false,
  }) : _placeholder = placeholder,
       _clock = clock,
       _backgroundHeld = backgroundHeld {
    if (holdsFrame) _heldAt = clock.now;
  }

  @override
  final MediaKey key;

  @override
  final AssetSpec spec;

  @override
  final AssetProfile profile;

  final AssetPaintable _placeholder;
  final PlaybackClock _clock;
  double _fraction = 1;
  bool _held = false;
  bool _backgroundHeld;
  // The clock's time when the hold began: what a held binding paints at.
  Duration? _heldAt;
  bool _detached = false;

  /// Whether [detach] was called.
  bool get isDetached => _detached;

  /// The clock this binding is advanced by.
  PlaybackClock get clock => _clock;

  /// The readiness while attached.
  @protected
  AssetReadiness get liveReadiness;

  /// The paintable while attached.
  @protected
  AssetPaintable get livePaintable;

  /// Gives back what attach took (counts, listeners). Called once, at detach.
  @protected
  void releaseResources();

  /// Whether this binding advances now: the profile animates, or a replay
  /// asked it to.
  @protected
  bool get animates => profile.animate;

  @override
  AssetPlayback get playback => AssetPlayback.idle;

  @override
  MediaDescriptor? get descriptor => null;

  @override
  AssetTransfer get transfer => AssetTransfer.none;

  @override
  void download() {}

  @override
  bool requestsDownload = false;

  @override
  void cancelDownload() {}

  @override
  bool replay() => false;

  /// Called after [visible] changed while attached.
  @protected
  void onVisibleChanged() {}

  /// Called after [holdsFrame] changed while attached.
  @protected
  void onHeldChanged() {}

  /// Whether the binding holds its frame now: the surface holds it ([held]),
  /// or the scope's background hold does and the profile is not in the
  /// foreground (`AssetProfile.foreground`).
  ///
  /// Kept apart from [held], which stays the surface's own wish: a surface
  /// that holds its binding is still holding it when the background hold
  /// ends.
  bool get holdsFrame =>
      _held ||
      _entryHeld ||
      (_backgroundHeld && !profile.foreground) ||
      _belowFloor;

  // Shown, but too little of it to advance (`AssetProfile.advanceFloor`).
  bool get _belowFloor => _fraction > 0 && _fraction < profile.advanceFloor;

  bool _entryHeld = false;

  /// Set by the scope while a hold of this binding's entry is on
  /// (`AssetCacheScope.holdPlayback`).
  set entryHeld(bool value) {
    if (_entryHeld == value) return;
    final before = holdsFrame;
    _entryHeld = value;
    _holdChanged(before);
  }

  /// Set by the scope while a background hold is on
  /// (`AssetCacheScope.holdBackground`).
  set backgroundHeld(bool value) {
    if (_backgroundHeld == value) return;
    final before = holdsFrame;
    _backgroundHeld = value;
    _holdChanged(before);
  }

  /// Tells the listeners something this binding paints changed.
  @protected
  void signal() {
    if (!_detached) notifyListeners();
  }

  @override
  AssetReadiness get readiness =>
      _detached ? const AssetReadiness(AssetStage.none) : liveReadiness;

  @override
  AssetPaintable get paintable => _detached ? _placeholder : livePaintable;

  @override
  bool get visible => _fraction > 0;

  @override
  set visible(bool value) => visibleFraction = value ? 1 : 0;

  @override
  double get visibleFraction => _fraction;

  @override
  set visibleFraction(double value) {
    final next = value.clamp(0.0, 1.0);
    if (next == _fraction) return;
    final wasVisible = visible;
    final wasHolding = holdsFrame;
    _fraction = next;
    // A hidden binding that is painted anyway (laid out off screen) paints
    // at the time it hid: it does not advance until it is shown again.
    if (visible != wasVisible) _hiddenAt = visible ? null : _clock.now;
    // The hold first: a binding that hides while held keeps its frame.
    _holdChanged(wasHolding);
    if (visible != wasVisible && !_detached) onVisibleChanged();
  }

  @override
  bool get held => _held;

  @override
  set held(bool value) {
    if (_held == value) return;
    final before = holdsFrame;
    _held = value;
    _holdChanged(before);
  }

  void _holdChanged(bool before) {
    final holds = holdsFrame;
    if (holds == before) return;
    _heldAt = holds ? _clock.now : null;
    if (!_detached) onHeldChanged();
  }

  // The time a binding whose profile does not animate paints at: the clock's
  // at its first paint, kept. The clock runs for every animated binding of
  // the scope, so painting at its live time would step an animated
  // paintable whenever the surface happened to repaint (a strip's own motion,
  // say): bursts of frames, where the profile promises one.
  Duration? _stillTime;

  // The clock's time when the binding hid, while it is hidden.
  Duration? _hiddenAt;

  AssetPaintContext _context({
    Color? tint,
    double opacity = 1,
    OutlineLook? outline,
  }) => AssetPaintContext(
    tint: tint,
    opacity: opacity,
    outline: outline,
    time: animates
        ? _heldAt ?? _hiddenAt ?? _clock.now
        : _stillTime ??= _clock.now,
    animate: animates,
    loop: profile.loop,
    restFrame: profile.restFrame,
    fit: profile.fit,
    halfFrameRate: profile.halfFrameRate,
  );

  @override
  void advancePlayback() => paintable.advancePlayback(_context());

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    Color? tint,
    double opacity = 1,
    OutlineLook? outline,
  }) {
    final context = _context(tint: tint, opacity: opacity, outline: outline);
    final radius = profile.cornerRadius;
    if (radius <= 0) {
      paintable.paint(canvas, rect, context);
      return;
    }
    final area = profile.roundedArea(rect, paintable.pictureSize);
    canvas
      ..save()
      ..clipRRect(RRect.fromRectXY(area, radius, radius));
    paintable.paint(canvas, rect, context);
    canvas.restore();
  }

  @override
  bool paintStandIn(
    Canvas canvas,
    Rect rect, {
    double contentOpacity = 0,
    OutlineLook? outline,
  }) => false;

  @override
  void releaseStandIn() {}

  @override
  void detach() {
    if (_detached) return;
    _detached = true;
    releaseResources();
    dispose();
  }
}
