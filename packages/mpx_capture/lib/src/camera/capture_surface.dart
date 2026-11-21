import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_capture/src/cache/capture_cache.dart';
import 'package:mpx_capture/src/camera/camera_preview.dart';
import 'package:mpx_capture/src/camera/camera_session.dart';
import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_core/mpx_core.dart';

/// What the capture surface offers to take.
enum CaptureKinds {
  /// Photos only: the shutter takes a photo.
  photo,

  /// Videos only: a tap starts and stops a recording, a hold records while
  /// held.
  video,

  /// Both: a tap takes a photo, a hold records a video.
  photoAndVideo;

  /// Whether photos are offered.
  bool get photos => this != video;

  /// Whether videos are offered.
  bool get videos => this != photo;
}

/// Why the shutter did not record a video.
enum CaptureVideoRefusal {
  /// The surface takes photos only ([CaptureKinds.photo]).
  notAllowed,

  /// The microphone is refused (the platform's prompt was declined, or will
  /// not show again).
  microphone,
}

/// The host's words for the capture surface's controls, read by screen
/// readers.
@immutable
final class CaptureSurfaceLabels {
  /// Creates the labels.
  const CaptureSurfaceLabels({
    required this.close,
    required this.shutter,
    required this.switchCamera,
    required this.flash,
  });

  /// The close button.
  final String close;

  /// The shutter.
  final String shutter;

  /// The camera switch.
  final String switchCamera;

  /// The flash button.
  final String flash;
}

/// What the capture surface took.
@immutable
final class CameraShot {
  /// Describes a shot.
  const CameraShot({required this.isVideo, required this.output, this.key});

  /// Whether it is a video (else a photo).
  final bool isVideo;

  /// The file's facts. When [key] is set the file has moved into the bytes
  /// store and [CaptureOutput.path] no longer exists.
  final CaptureOutput output;

  /// The local media key the bytes resolve under, when the surface was given
  /// a [CaptureCache].
  final MediaKey$Local? key;

  @override
  String toString() =>
      'CameraShot(${isVideo ? 'video' : 'photo'}, ${key ?? output.path})';
}

/// The minimal full-screen camera over a running [CameraSession]: the
/// preview, a shutter (tap for a photo, hold for a video, as [kinds]
/// allows), a camera switch, a flash button and a close button. No modes
/// strip, zoom or second camera.
///
/// It takes the session over from wherever it showed (a small preview) and
/// gives it back without a restart: on show it lifts the session's
/// frame-rate cap, and on close it restores the cap it found. It never
/// disposes the session.
///
/// A capture is written into [outputDirectory]; with a [cache] it then
/// moves into the bytes store under a fresh `MediaKey.local`. Either way
/// [onCaptured] gets it; the surface stays open for more until the host
/// closes it.
class CameraCaptureSurface extends StatefulWidget {
  /// Creates the surface.
  const CameraCaptureSurface({
    required this.session,
    required this.labels,
    required this.outputDirectory,
    required this.onCaptured,
    required this.onClose,
    this.kinds = CaptureKinds.photoAndVideo,
    this.cache,
    this.expandFrom,
    this.expansion,
    this.controlsReveal,
    this.mirrorFrontPhotos = true,
    this.onVideoRefused,
    this.videoNeedsMicrophone = true,
    super.key,
  });

  /// Shows the surface over the app as a route; completes when it closes.
  /// [onCaptured] runs for each shot; the route pops on close. With [from]
  /// (the camera slot's rectangle, global) it expands from there over
  /// [transition] (350 ms), else it fades in.
  static Future<void> show(
    BuildContext context, {
    required CameraSession session,
    required CaptureSurfaceLabels labels,
    required String outputDirectory,
    required ValueChanged<CameraShot> onCaptured,
    CaptureKinds kinds = CaptureKinds.photoAndVideo,
    CaptureCache? cache,
    Rect? from,
    bool mirrorFrontPhotos = true,
    ValueChanged<CaptureVideoRefusal>? onVideoRefused,
    bool videoNeedsMicrophone = true,
    Duration transition = const Duration(milliseconds: 350),
    Duration closeTransition = const Duration(milliseconds: 220),
  }) =>
      // The preview grows from the slot to the screen over [transition] on
      // an ease curve (back over [closeTransition], the same curve in
      // time), and the controls, laid out at the whole screen, fade with it.
      Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: transition,
          reverseTransitionDuration: closeTransition,
          pageBuilder: (context, animation, _) {
            final progress = _EasedInTime(animation);
            return CameraCaptureSurface(
              session: session,
              labels: labels,
              outputDirectory: outputDirectory,
              onCaptured: onCaptured,
              onClose: () => Navigator.of(context).pop(),
              kinds: kinds,
              cache: cache,
              expandFrom: from,
              expansion: from == null ? null : progress,
              controlsReveal: from == null ? null : progress,
              mirrorFrontPhotos: mirrorFrontPhotos,
              onVideoRefused: onVideoRefused,
              videoNeedsMicrophone: videoNeedsMicrophone,
            );
          },
          transitionsBuilder: (context, animation, _, child) {
            if (from != null) return child;
            return FadeTransition(
              opacity: CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              ),
              child: child,
            );
          },
        ),
      );

  /// How long the shutter is held before a video starts recording.
  static const Duration holdToRecord = Duration(milliseconds: 800);

  /// The running session.
  final CameraSession session;

  /// Words for screen readers.
  final CaptureSurfaceLabels labels;

  /// Where captures are written.
  final String outputDirectory;

  /// Called with every shot.
  final ValueChanged<CameraShot> onCaptured;

  /// Called by the close button.
  final VoidCallback onClose;

  /// What the shutter takes.
  final CaptureKinds kinds;

  /// Where captures move to, under a local key; null to leave them as files.
  final CaptureCache? cache;

  /// The rectangle (global) the preview expands from as [expansion] runs;
  /// null for a surface that is simply there.
  final Rect? expandFrom;

  /// The preview's expansion, 0 at [expandFrom] and 1 at the whole screen.
  /// Only the preview moves: the controls are laid out at the whole screen
  /// throughout. Null without [expandFrom].
  final Animation<double>? expansion;

  /// The controls' opacity, which [show] runs with the [expansion] (and,
  /// backwards, before it); they take no touches until it is 1. Null for
  /// controls that are simply there.
  final Animation<double>? controlsReveal;

  /// Whether a front camera's photos are saved mirrored, as the preview
  /// shows them (a chat's camera does); videos never are.
  final bool mirrorFrontPhotos;

  /// Called when the shutter would record a video but may not: a hold on a
  /// surface for photos only, or a microphone refused. The host shows its
  /// notice; nothing is recorded.
  final ValueChanged<CaptureVideoRefusal>? onVideoRefused;

  /// Whether a video needs the microphone. Without access, a hold asks for
  /// it (the platform's prompt) and records nothing: the next hold records
  /// once it is granted, and a refusal goes to [onVideoRefused].
  final bool videoNeedsMicrophone;

  @override
  State<CameraCaptureSurface> createState() => _CameraCaptureSurfaceState();
}

class _CameraCaptureSurfaceState extends State<CameraCaptureSurface>
    with SingleTickerProviderStateMixin {
  int? _foundCap;

  // --- Focus, zoom and the recording timer ---

  // The ring at the last tap: it closes in over 200 ms (outer radius from
  // twice its 30 px to 30, the inner disc from 0 to 30), then the disc and
  // the ring fade over 150 ms each, decelerating.
  static const double _ringRadius = 30;
  late final AnimationController _ring;
  Offset? _ringAt;

  // Two fingers: once their distance has moved by [_pinchSlop], the zoom
  // follows each further change, by its length over 100 px.
  static const double _pinchSlop = 25;
  final Map<int, Offset> _pointers = {};
  double? _pinchFrom;
  bool _pinching = false;

  // The recording's seconds.
  Timer? _tick;
  int _seconds = 0;
  bool _wasRecording = false;

  void _focus(TapUpDetails details, Size size) {
    if (size.isEmpty) return;
    final at = details.localPosition;
    final point = Offset(
      (at.dx / size.width).clamp(0.0, 1.0),
      (at.dy / size.height).clamp(0.0, 1.0),
    );
    unawaited(_quietly(() => _session.focusAt(point)));
    setState(() => _ringAt = at);
    _ring.forward(from: 0).ignore();
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers[event.pointer] = event.localPosition;
    _pinching = false;
    _pinchFrom = _pointers.length == 2
        ? (_pointers.values.first - _pointers.values.last).distance
        : null;
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!_pointers.containsKey(event.pointer)) return;
    _pointers[event.pointer] = event.localPosition;
    if (_pointers.length != 2) return;
    final [a, b] = _pointers.values.toList();
    final distance = (a - b).distance;
    final from = _pinchFrom;
    if (from == null) {
      _pinchFrom = distance;
      return;
    }
    if (!_pinching) {
      if ((distance - from).abs() < _pinchSlop) return;
      _pinching = true;
      _pinchFrom = distance;
      return;
    }
    final zoom = (_value.zoom + (distance - from) / 100).clamp(0.0, 1.0);
    _pinchFrom = distance;
    unawaited(_quietly(() => _session.setZoom(zoom)));
  }

  void _pointerUp(PointerEvent event) {
    _pointers.remove(event.pointer);
    if (_pointers.length < 2) {
      _pinchFrom = null;
      _pinching = false;
    }
  }

  void _onValue() {
    final recording = _value.isRecording;
    if (recording == _wasRecording) return;
    _wasRecording = recording;
    _tick?.cancel();
    if (recording) {
      _seconds = 0;
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _seconds++);
      });
    }
    if (mounted) setState(() {});
  }

  static String _clock(Duration time) {
    final seconds = time.inSeconds;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  Widget _hands(BuildContext context, Widget controls) => LayoutBuilder(
    builder: (context, constraints) {
      final size = constraints.biggest;
      final ringAt = _ringAt;
      return Stack(
        fit: StackFit.expand,
        children: [
          Listener(
            onPointerDown: _pointerDown,
            onPointerMove: _pointerMove,
            onPointerUp: _pointerUp,
            onPointerCancel: _pointerUp,
            behavior: HitTestBehavior.translucent,
            child: GestureDetector(
              key: const ValueKey('mpx-capture-picture'),
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _focus(details, size),
            ),
          ),
          if (ringAt != null)
            Positioned(
              left: ringAt.dx - 2 * _ringRadius,
              top: ringAt.dy - 2 * _ringRadius,
              width: 4 * _ringRadius,
              height: 4 * _ringRadius,
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _ring,
                  builder: (context, _) => CustomPaint(
                    key: const ValueKey('mpx-capture-focus'),
                    painter: _FocusRing(_ring.value),
                  ),
                ),
              ),
            ),
          controls,
          if (_value.isRecording)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 16,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    key: const ValueKey('mpx-capture-timer'),
                    padding: const EdgeInsets.fromLTRB(24, 5, 10, 5),
                    decoration: BoxDecoration(
                      color: const Color(0x66000000),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.centerLeft,
                      children: [
                        // The red dot of a recording, in the pill's
                        // leading padding.
                        const Positioned(
                          left: -15,
                          child: SizedBox.square(
                            dimension: 8,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Color(0xFFFF3B30),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                        Text(
                          _clock(Duration(seconds: _seconds)),
                          style: const TextStyle(
                            color: Color(0xFFFFFFFF),
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
  bool _busy = false;
  int _shots = 0;

  CameraSession get _session => widget.session;
  CameraSessionValue get _value => _session.value.value;

  @override
  void initState() {
    super.initState();
    _ring =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 500),
        )..addStatusListener((status) {
          if (status.isCompleted && mounted) setState(() => _ringAt = null);
        });
    _session.value.addListener(_onValue);
    _wasRecording = _value.isRecording;
    _foundCap = _value.frameRateCap;
    // After the build that mounts the surface: the slot's preview listens to
    // the same session and must not be marked dirty mid-build.
    if (_value.state != CameraSessionState.closed && _foundCap != null) {
      scheduleMicrotask(
        () => unawaited(_quietly(() => _session.setFrameRateCap(null))),
      );
    }
  }

  @override
  void dispose() {
    _session.value.removeListener(_onValue);
    _tick?.cancel();
    _ring.dispose();
    final session = _session;
    final found = _foundCap;
    // Out of the locked tree: other widgets listen to the same session.
    scheduleMicrotask(() {
      final value = session.value.value;
      if (value.state == CameraSessionState.closed) return;
      if (value.isRecording) unawaited(_quietly(session.stopRecording));
      if (value.frameRateCap != found) {
        unawaited(_quietly(() => session.setFrameRateCap(found)));
      }
    });
    super.dispose();
  }

  // A control on a session that closed meanwhile is nothing to report.
  static Future<void> _quietly(Future<Object?> Function() call) async {
    try {
      await call();
    } on CaptureException {
      // The session closed or is not available; the surface shows its state.
    }
  }

  String _output(String extension) =>
      '${widget.outputDirectory}/camera-'
      '${DateTime.now().microsecondsSinceEpoch}-${_shots++}.$extension';

  Future<void> _deliver(CaptureOutput output, {required bool isVideo}) async {
    // Each shot starts the next from the widest view.
    if (_value.zoom != 0) unawaited(_quietly(() => _session.setZoom(0)));
    final cache = widget.cache;
    if (cache == null) {
      widget.onCaptured(CameraShot(isVideo: isVideo, output: output));
      return;
    }
    final key = cache.mintKey();
    await cache.put(key, output);
    widget.onCaptured(CameraShot(isVideo: isVideo, output: output, key: key));
  }

  Future<void> _photo() async {
    if (_busy || !_value.isAvailable) return;
    _busy = true;
    try {
      final output = await _session.capturePhoto(
        outputPath: _output('jpg'),
        mirrorFront: widget.mirrorFrontPhotos,
      );
      await _deliver(output, isVideo: false);
    } on CaptureException {
      // The session's state tells; nothing was taken.
    } finally {
      _busy = false;
    }
  }

  // Whether a recording may start now: with the microphone, when videos
  // need it, asked for first (that press records nothing).
  Future<bool> _mayRecord() async {
    if (!widget.videoNeedsMicrophone) return true;
    if (_value.microphone == MicrophoneAccess.granted) return true;
    try {
      final access = await _session.requestMicrophone();
      if (access != MicrophoneAccess.granted && mounted) {
        widget.onVideoRefused?.call(CaptureVideoRefusal.microphone);
      }
    } on CaptureException {
      // The session closed meanwhile.
    }
    return false;
  }

  Future<void> _startVideo() async {
    if (_busy || !_value.isAvailable || _value.isRecording) return;
    if (!await _mayRecord()) return;
    if (!mounted || _busy || !_value.isAvailable || _value.isRecording) return;
    await _quietly(() => _session.startRecording(outputPath: _output('mp4')));
  }

  Future<void> _stopVideo() async {
    if (!_value.isRecording) return;
    _busy = true;
    try {
      final output = await _session.stopRecording();
      await _deliver(output, isVideo: true);
    } on CaptureException {
      // The recording broke; its state tells.
    } finally {
      _busy = false;
    }
  }

  void _tap() {
    final kinds = widget.kinds;
    if (_value.isRecording) {
      unawaited(_stopVideo());
    } else if (kinds.photos) {
      unawaited(_photo());
    } else {
      unawaited(_startVideo());
    }
  }

  void _holdStart() {
    if (widget.kinds.videos) return unawaited(_startVideo());
    widget.onVideoRefused?.call(CaptureVideoRefusal.notAllowed);
  }

  void _holdEnd() {
    if (widget.kinds.videos) unawaited(_stopVideo());
  }

  void _cycleFlash() {
    final next = switch (_value.flash) {
      CameraFlash.off => CameraFlash.auto,
      CameraFlash.auto => CameraFlash.on,
      CameraFlash.on => CameraFlash.off,
    };
    unawaited(_quietly(() => _session.setFlash(next)));
  }

  @override
  Widget build(BuildContext context) {
    final preview = ColoredBox(
      color: const Color(0xFF000000),
      child: CameraPreview(session: _session),
    );
    final controls = _hands(
      context,
      ValueListenableBuilder<CameraSessionValue>(
        valueListenable: _session.value,
        builder: (context, value, _) => _controls(value),
      ),
    );
    final from = widget.expandFrom;
    final expand = widget.expansion;
    final fade = widget.controlsReveal;
    final shown = switch (fade) {
      // Laid out at the whole screen at every step; shown, and touchable,
      // only once the preview fills it.
      final fade? => AnimatedBuilder(
        animation: fade,
        child: controls,
        builder: (context, controls) => IgnorePointer(
          ignoring: fade.value < 1 && fade.status != AnimationStatus.completed,
          child: Opacity(
            key: const ValueKey('mpx-capture-controls-fade'),
            opacity: fade.value.clamp(0.0, 1.0),
            child: controls,
          ),
        ),
      ),
      null => controls,
    };
    if (from == null || expand == null) {
      return Stack(fit: StackFit.expand, children: [preview, shown]);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        // The route covers the screen: [from], global, is in its space.
        final screen = Offset.zero & constraints.biggest;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedBuilder(
              animation: expand,
              child: preview,
              builder: (context, preview) => Stack(
                children: [
                  Positioned.fromRect(
                    rect: Rect.lerp(from, screen, expand.value)!,
                    child: ClipRect(child: preview),
                  ),
                ],
              ),
            ),
            shown,
          ],
        );
      },
    );
  }

  Widget _controls(CameraSessionValue value) {
    final labels = widget.labels;
    return SafeArea(
      key: const ValueKey('mpx-capture-controls'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Row(
              children: [
                _GlyphButton(
                  key: const ValueKey('mpx-capture-close'),
                  glyph: _Glyph.close,
                  label: labels.close,
                  onTap: widget.onClose,
                ),
                const Spacer(),
                if (value.hasFlash)
                  _AsideWhileRecording(
                    key: const ValueKey('mpx-capture-flash-slot'),
                    recording: value.isRecording,
                    child: _GlyphButton(
                      key: const ValueKey('mpx-capture-flash'),
                      glyph: switch (value.flash) {
                        CameraFlash.off => _Glyph.flashOff,
                        CameraFlash.auto => _Glyph.flashAuto,
                        CameraFlash.on => _Glyph.flashOn,
                      },
                      label: labels.flash,
                      value: value.flash.name,
                      onTap: _cycleFlash,
                    ),
                  ),
              ],
            ),
            const Spacer(),
            Row(
              children: [
                const SizedBox(width: 48),
                const Spacer(),
                _Shutter(
                  label: labels.shutter,
                  recording: value.isRecording,
                  enabled: value.isAvailable && !value.isPaused,
                  onTap: _tap,
                  onHoldStart: _holdStart,
                  onHoldEnd: _holdEnd,
                ),
                const Spacer(),
                if (value.canSwitchCamera)
                  _AsideWhileRecording(
                    key: const ValueKey('mpx-capture-switch-slot'),
                    recording: value.isRecording,
                    child: _GlyphButton(
                      key: const ValueKey('mpx-capture-switch'),
                      glyph: _Glyph.switchCamera,
                      label: labels.switchCamera,
                      onTap: () => unawaited(_quietly(_session.switchCamera)),
                    ),
                  )
                else
                  const SizedBox(width: 48),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// While a recording runs, a control slides 30 px out towards its edge and
// fades, over 150 ms on an ease curve, and takes no touches; it comes back
// the same way.
class _AsideWhileRecording extends StatelessWidget {
  const _AsideWhileRecording({
    required this.recording,
    required this.child,
    super.key,
  });

  final bool recording;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final outward = Directionality.of(context) == TextDirection.ltr ? 1 : -1;
    return IgnorePointer(
      ignoring: recording,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: recording ? 1 : 0),
        duration: const Duration(milliseconds: 150),
        curve: Curves.ease,
        builder: (context, t, child) => Transform.translate(
          offset: Offset(outward * 30 * t, 0),
          child: Opacity(opacity: 1 - t, child: child),
        ),
        child: child,
      ),
    );
  }
}

class _Shutter extends StatefulWidget {
  const _Shutter({
    required this.label,
    required this.recording,
    required this.enabled,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final String label;
  final bool recording;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  State<_Shutter> createState() => _ShutterState();
}

// Pressed, the shutter grows to 1.06 over 120 ms, decelerating; released,
// it settles back the same way after 40 ms.
class _ShutterState extends State<_Shutter>
    with SingleTickerProviderStateMixin {
  late final AnimationController _press;
  Timer? _release;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
  }

  @override
  void dispose() {
    _release?.cancel();
    _press.dispose();
    super.dispose();
  }

  void _down(PointerDownEvent _) {
    if (!widget.enabled) return;
    _release?.cancel();
    _press.forward().ignore();
  }

  void _up(PointerEvent _) {
    _release?.cancel();
    _release = Timer(const Duration(milliseconds: 40), () {
      if (mounted) _press.reverse().ignore();
    });
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return Semantics(
      key: const ValueKey('mpx-capture-shutter'),
      button: true,
      enabled: enabled,
      label: widget.label,
      onTap: enabled ? widget.onTap : null,
      child: Listener(
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            if (enabled)
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                    TapGestureRecognizer.new,
                    (tap) => tap.onTap = widget.onTap,
                  ),
            if (enabled)
              LongPressGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    LongPressGestureRecognizer
                  >(
                    () => LongPressGestureRecognizer(
                      duration: CameraCaptureSurface.holdToRecord,
                    ),
                    (hold) => hold
                      ..onLongPressStart = ((_) => widget.onHoldStart())
                      ..onLongPressEnd = ((_) => widget.onHoldEnd()),
                  ),
          },
          child: AnimatedBuilder(
            animation: _press,
            builder: (context, child) => Transform.scale(
              scale: 1 + 0.06 * Curves.decelerate.transform(_press.value),
              child: child,
            ),
            child: SizedBox.square(
              dimension: 76,
              child: CustomPaint(
                painter: _ShutterPainter(
                  recording: widget.recording,
                  enabled: enabled,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShutterPainter extends CustomPainter {
  const _ShutterPainter({required this.recording, required this.enabled});

  final bool recording;
  final bool enabled;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final white = Color(enabled ? 0xFFFFFFFF : 0x80FFFFFF);
    canvas.drawCircle(
      center,
      radius - 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..color = white,
    );
    canvas.drawCircle(
      center,
      recording ? radius * 0.45 : radius - 10,
      Paint()..color = recording ? const Color(0xFFFF3B30) : white,
    );
  }

  @override
  bool shouldRepaint(_ShutterPainter old) =>
      old.recording != recording || old.enabled != enabled;
}

enum _Glyph { close, flashOff, flashAuto, flashOn, switchCamera }

class _GlyphButton extends StatelessWidget {
  const _GlyphButton({
    required this.glyph,
    required this.label,
    required this.onTap,
    this.value,
    super.key,
  });

  final _Glyph glyph;
  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    value: value,
    onTap: onTap,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox.square(
        dimension: 48,
        child: CustomPaint(painter: _GlyphPainter(glyph)),
      ),
    ),
  );
}

// Glyphs drawn with strokes, so the package needs no icon font.
class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph);

  final _Glyph glyph;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final c = size.center(Offset.zero);
    const r = 10.0;
    switch (glyph) {
      case _Glyph.close:
        canvas
          ..drawLine(c + const Offset(-r, -r), c + const Offset(r, r), paint)
          ..drawLine(c + const Offset(r, -r), c + const Offset(-r, r), paint);
      case _Glyph.flashOff || _Glyph.flashAuto || _Glyph.flashOn:
        final bolt = Path()
          ..moveTo(c.dx + 2, c.dy - r - 2)
          ..lineTo(c.dx - 6, c.dy + 1)
          ..lineTo(c.dx, c.dy + 1)
          ..lineTo(c.dx - 2, c.dy + r + 2)
          ..lineTo(c.dx + 6, c.dy - 1)
          ..lineTo(c.dx, c.dy - 1)
          ..close();
        if (glyph == _Glyph.flashOn) {
          canvas.drawPath(bolt, Paint()..color = const Color(0xFFFFD60A));
        } else {
          canvas.drawPath(bolt, paint);
        }
        if (glyph == _Glyph.flashOff) {
          canvas.drawLine(
            c + const Offset(-r, -r),
            c + const Offset(r, r),
            paint,
          );
        }
        if (glyph == _Glyph.flashAuto) {
          canvas.drawCircle(
            c + const Offset(r, -r + 2),
            3,
            Paint()..color = const Color(0xFFFFFFFF),
          );
        }
      case _Glyph.switchCamera:
        final rect = Rect.fromCircle(center: c, radius: r);
        canvas
          ..drawArc(rect, -math.pi * 0.9, math.pi * 0.8, false, paint)
          ..drawArc(rect, math.pi * 0.1, math.pi * 0.8, false, paint);
        final tip =
            c +
            Offset(r * math.cos(-0.1 * math.pi), r * math.sin(-0.1 * math.pi));
        canvas
          ..drawLine(tip, tip + const Offset(-5, -2), paint)
          ..drawLine(tip, tip + const Offset(2, -5), paint);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph;
}

// The route's animation eased in time both ways: going out, `ease` of the
// time gone (1 − ease(1 − t)), so the close runs the same curve as the
// open, from its own start.
class _EasedInTime extends Animation<double>
    with AnimationWithParentMixin<double> {
  _EasedInTime(this.parent);

  @override
  final Animation<double> parent;

  @override
  double get value {
    final t = parent.value;
    return switch (parent.status) {
      AnimationStatus.reverse => 1 - Curves.ease.transform(1 - t),
      _ => Curves.ease.transform(t),
    };
  }
}

class _FocusRing extends CustomPainter {
  const _FocusRing(this.t);

  // 0 to 1 over the ring's 500 ms: 200 to close in, 150 for the disc to
  // fade, 150 for the ring.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    const curve = Curves.decelerate;
    const base = 30.0;
    final ms = t * 500;
    final closing = curve.transform((ms / 200).clamp(0.0, 1.0));
    final inner = 1 - ((ms - 200) / 150).clamp(0.0, 1.0);
    final outer = 1 - ((ms - 350) / 150).clamp(0.0, 1.0);
    final c = size.center(Offset.zero);
    canvas
      ..drawCircle(
        c,
        base + base * (1 - closing),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Color.fromRGBO(255, 255, 255, curve.transform(outer)),
      )
      ..drawCircle(
        c,
        base * closing,
        Paint()
          ..color = Color.fromRGBO(255, 255, 255, curve.transform(inner) * 0.5),
      );
  }

  @override
  bool shouldRepaint(_FocusRing oldDelegate) => oldDelegate.t != t;
}
