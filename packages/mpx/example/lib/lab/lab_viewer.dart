import 'dart:async';
import 'dart:developer' show Timeline;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_example/lab/lab.dart';
import 'package:mpx_player/mpx_player.dart';
import 'package:mpx_ui/mpx_ui.dart';

/// The viewer's side of the lab: the semantic marks of an open and a close,
/// the morph's progress on every frame, and the card's picture moving again
/// after a close. Every entry point is null or a no-op outside a lab build,
/// so a call site passes them unconditionally.
abstract final class LabViewer {
  /// The cards on each surface by index: their content and the spec their
  /// loop plays at, so a close can watch the card's playback resume.
  static final Map<String, Map<int, (MediaKey, AssetSpec)>> _cards = {};

  /// Notes that [surface]'s card [index] shows [content] at [spec].
  static void card(
    String surface,
    int index,
    MediaKey content,
    AssetSpec spec,
  ) {
    if (!kMpxLab) return;
    (_cards[surface] ??= {})[index] = (content, spec);
  }

  /// A controller that marks the viewer's phases, for one viewer opened
  /// from [surface]; null outside a lab build.
  static ViewerController? controller(String surface) {
    if (!kMpxLab) return null;
    return _Watch(surface).controller;
  }

  /// The policy the viewer resolves for [context] with a backdrop scale it
  /// reports through [onBackdropScale], so the morph's progress can be
  /// read back; null outside a lab build. The example draws no backdrop, so
  /// the scale changes nothing on screen.
  static ViewerPolicy? policy(BuildContext context) {
    if (!kMpxLab) return null;
    final policy = ViewerPolicyScope.resolve(context);
    return policy.backdropScale > 0
        ? policy
        : policy.copyWith(backdropScale: _probeScale);
  }

  static const double _probeScale = 1;

  /// Marks the morph's progress (0 closed, 1 open) as a `LABm <progress>`
  /// slice inside the frame; null outside a lab build.
  static ValueChanged<double>? get onBackdropScale =>
      kMpxLab ? _onBackdropScale : null;

  static _Watch? _current;

  static void _onBackdropScale(double scale) {
    final watch = _current;
    if (watch == null) return;
    final progress = (scale - 1) / watch.scale;
    Timeline.timeSync('LABm ${progress.toStringAsFixed(4)}', () {});
  }
}

/// One viewer's marks, from open start to close end.
final class _Watch {
  _Watch(this.surface) {
    controller.addListener(_onChange);
  }

  final String surface;
  final ViewerController controller = ViewerController();
  double scale = LabViewer._probeScale;

  bool _attached = false;
  bool _open = false;
  bool _closing = false;
  int? _index;
  PlayerLease? _lease;
  PlayerState? _state;

  void _onChange() {
    if (controller.isAttached && !_attached) {
      _attached = true;
      LabViewer._current = this;
      _index = controller.index;
      Lab.event('viewer open-start $surface i=$_index');
    }
    if (!_attached) return;
    if (controller.index case final index? when index != _index) {
      _index = index;
      Lab.event('viewer page i=$index');
    }
    if (controller.isOpen && !_open) {
      _open = true;
      Lab.event('viewer morph-end i=$_index');
    } else if (!controller.isOpen && _open && controller.isAttached) {
      _open = false;
      _closing = true;
      Lab.event('viewer close-start i=$_index');
    }
    _watchLease(controller.videoLease);
    if (!controller.isAttached) {
      _attached = false;
      if (!_closing) Lab.event('viewer close-start i=$_index');
      Lab.event('viewer close-end i=$_index');
      _watchLease(null);
      if (identical(LabViewer._current, this)) LabViewer._current = null;
      final card = LabViewer._cards[surface]?[_index];
      if (card != null) _CardWatch(surface, _index!, card.$1, card.$2).start();
      controller.removeListener(_onChange);
      // Not while it notifies.
      scheduleMicrotask(controller.dispose);
    }
  }

  void _watchLease(PlayerLease? lease) {
    if (identical(lease, _lease)) return;
    _lease?.state.removeListener(_onState);
    _lease = lease;
    _state = null;
    if (lease != null) {
      lease.state.addListener(_onState);
      _onState();
    }
  }

  void _onState() {
    final state = _lease?.state.value;
    if (state == null) return;
    final was = _state;
    _state = state;
    if (state.firstFrameRendered && !(was?.firstFrameRendered ?? false)) {
      Lab.event('viewer first-player-frame i=$_index');
    }
    if (state.phase != was?.phase) {
      Lab.event('player phase ${state.phase.name}');
    }
    if (state.playing != was?.playing) {
      Lab.event('player playing=${state.playing}');
    }
    if (was != null && state.speed != was.speed) {
      Lab.event('player speed ${state.speed}');
    }
  }
}

/// Watches a card's loop after the viewer closed on it, until its playback
/// position moves (`card moved`) or 3 s pass (`card still`).
final class _CardWatch {
  _CardWatch(this.surface, this.index, this.content, this.spec);

  final String surface;
  final int index;
  final MediaKey content;
  final AssetSpec spec;
  Duration? _from;
  Timer? _timeout;

  void start() {
    final scope = Lab.scope;
    if (scope == null) return;
    _from = scope.playbackPosition(content, spec);
    if (_from == null) {
      Lab.event('card no-playback $surface i=$index');
      return;
    }
    // Checked after every frame the app draws anyway, asking for none.
    _timeout = Timer(const Duration(seconds: 3), () {
      Lab.event('card still $surface i=$index');
    });
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  void _onFrame(Duration _) {
    final timeout = _timeout;
    if (timeout == null || !timeout.isActive) return;
    final now = Lab.scope?.playbackPosition(content, spec);
    if (now != null && now != _from) {
      timeout.cancel();
      Lab.event('card moved $surface i=$index');
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }
}
