import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:mpx_core/src/widget/media_status.dart';
import 'package:mpx_core/src/widget/media_status_painting.dart';
import 'package:mpx_core/src/widget/media_status_style.dart';

/// One icon as a status control draws it in a frame: scaled, faded and
/// turned around the disc's centre.
typedef MediaStatusIconLayer = ({
  MediaStatusIcon icon,
  double scale,
  double opacity,
  double turnDegrees,
});

/// The motion of one status control: how far it has come in, which icons
/// show and how far one has turned into the next, where its arc stands.
///
/// Plain state stepped by [advance] with the time of each frame, so the
/// control's ticker drives it and a test steps it by hand. [retarget] sets
/// a new status; a morph under way that is sent back where it came from
/// runs back from where it is.
///
/// Internal to the package: `MediaStatusControl` owns one.
@internal
final class MediaStatusMotion {
  /// The motion of a control that shows [initial] at once.
  MediaStatusMotion(MediaStatus initial, this.style)
    : _target = initial,
      _visibility = initial.isVisible ? 1 : 0,
      _from = initial.icon,
      _to = initial.icon,
      _shownIcon = initial.icon,
      _arcShown = initial.arc,
      _shown = initial.progress ?? 0,
      _startDegrees = style.spinStartDegrees;

  /// The style the motion follows.
  MediaStatusStyle style;

  MediaStatus _target;
  double _visibility;
  MediaStatusIcon _from;
  MediaStatusIcon _to;
  // The icon last shown while visible, drawn as the control goes.
  MediaStatusIcon _shownIcon;
  double _morph = 1;
  bool _arcShown;
  // The determinate arc: shown progress, the ease under way.
  double _shown;
  double _easeFrom = 0;
  double _easeTo = 0;
  Duration _eased = Duration.zero;
  Duration _easeLength = Duration.zero;
  double _startDegrees;
  // The time the arc has turned without progress.
  Duration _spinning = Duration.zero;

  /// The status the motion moves to.
  MediaStatus get target => _target;

  /// How far the control has come in, 0 (gone) to 1.
  double get visibility => _visibility;

  /// How far the icon has turned from the last one into [target]'s, 0 to 1.
  double get morph => _morph;

  /// The progress the arc shows now.
  double get shownProgress => _shown;

  /// Whether a frame would change anything: the control comes or goes, an
  /// icon turns, or an arc shows (it always turns).
  bool get isAnimating =>
      _visibility != (_target.isVisible ? 1 : 0) ||
      _morph < 1 ||
      (_arcShown && _visibility > 0);

  /// Moves to [status].
  void retarget(MediaStatus status) {
    if (status == _target) return;
    final previous = _target;
    _target = status;
    if (status.isVisible) {
      if (status.icon != _to) {
        if (status.icon == _from && _morph < 1) {
          // Sent back: run back from where the morph is.
          _from = _to;
          _morph = 1 - _morph;
        } else {
          _from = _visibility > 0 ? _to : status.icon;
          _morph = _visibility > 0 ? 0 : 1;
        }
        _to = status.icon;
      }
      _shownIcon = status.icon;
      if (status.arc && !_arcShown) {
        _arcShown = true;
        _shown = status.progress ?? 0;
        _easeTo = _shown;
        _eased = _easeLength = Duration.zero;
      }
      if (!status.arc) _arcShown = false;
    }
    final progress = status.progress;
    if (status.arc && progress != null) {
      _setProgress(progress, wasDeterminate: previous.progress != null);
    }
  }

  void _setProgress(double value, {required bool wasDeterminate}) {
    final next = value.clamp(0.0, 1.0);
    final smoothing = style.smoothing;
    if (!wasDeterminate ||
        (smoothing.forwardOnly && next < _shown) ||
        smoothing.constant == null && smoothing.duration == Duration.zero) {
      _shown = _easeTo = next;
      _eased = _easeLength = Duration.zero;
      return;
    }
    _easeFrom = _shown;
    _easeTo = next;
    _eased = Duration.zero;
    _easeLength = smoothing.durationFor((next - _shown).abs());
  }

  /// Steps the motion by [dt], the time since the last frame.
  void advance(Duration dt) {
    if (dt <= Duration.zero) return;
    _advanceVisibility(dt);
    _advanceMorph(dt);
    if (_arcShown) _advanceArc(dt);
  }

  void _advanceVisibility(Duration dt) {
    final goal = _target.isVisible ? 1.0 : 0.0;
    if (_visibility == goal) return;
    final length = goal > _visibility
        ? style.appearDuration
        : style.disappearDuration;
    final step = length <= Duration.zero ? 1.0 : _ratio(dt, length);
    _visibility = goal > _visibility
        ? math.min(goal, _visibility + step)
        : math.max(goal, _visibility - step);
    if (_visibility == 0) {
      // Gone: the next status comes in with its own icon, no morph.
      _from = _to = _shownIcon = _target.icon;
      _morph = 1;
      _arcShown = _target.arc;
    }
  }

  void _advanceMorph(Duration dt) {
    if (_morph >= 1) return;
    final length = morphDurationOf(_from, _to);
    _morph = length <= Duration.zero
        ? 1
        : math.min(1, _morph + _ratio(dt, length));
  }

  void _advanceArc(Duration dt) {
    final turn = _target.progress == null && _target.arc
        ? style.spinner.turn
        : style.spinPeriod;
    if (_target.progress == null && _target.arc) _spinning += dt;
    _startDegrees = (_startDegrees + 360 * _ratio(dt, turn)) % 360;
    final smoothing = style.smoothing;
    if (smoothing.constant case final constant?) {
      final share =
          1 - constant.inMicroseconds / (constant + dt).inMicroseconds;
      _shown += (_easeTo - _shown) * share;
      if ((_easeTo - _shown).abs() < 0.001) _shown = _easeTo;
    } else if (_shown != _easeTo) {
      _eased += dt;
      if (_eased >= _easeLength) {
        _shown = _easeTo;
      } else {
        final t = smoothing.curve.transform(_ratio(_eased, _easeLength));
        _shown = _easeFrom + (_easeTo - _easeFrom) * t;
      }
    }
  }

  /// How long [from] takes to turn into [to] under [style].
  Duration morphDurationOf(MediaStatusIcon from, MediaStatusIcon to) {
    bool pair(MediaStatusIcon a, MediaStatusIcon b) =>
        (from == a && to == b) || (from == b && to == a);
    if (pair(MediaStatusIcon.download, MediaStatusIcon.cancel)) {
      return style.downloadCancelDuration;
    }
    if (pair(MediaStatusIcon.play, MediaStatusIcon.pause)) {
      return style.playPauseDuration;
    }
    return style.morphDuration;
  }

  /// The icons to draw now, back to front.
  List<MediaStatusIconLayer> get icons {
    if (_morph >= 1 || _from == _to) {
      final icon = _target.isVisible ? _to : _shownIcon;
      return [
        if (icon != MediaStatusIcon.none)
          (icon: icon, scale: 1, opacity: 1, turnDegrees: 0),
      ];
    }
    final phased =
        style.iconMorph == MediaIconMorph.phased &&
        {
          _from,
          _to,
        }.containsAll(const {MediaStatusIcon.download, MediaStatusIcon.cancel});
    if (phased) {
      final (out, pause, into) = style.downloadCancelPhases;
      final t = _morph;
      if (t < out) {
        return [(icon: _from, scale: 1 - t / out, opacity: 1, turnDegrees: 0)];
      }
      if (t < out + pause) return const [];
      final u = ((t - out - pause) / into).clamp(0.0, 1.0);
      return [(icon: _to, scale: u, opacity: 1, turnDegrees: -90 * (1 - u))];
    }
    final t = _morph;
    return [
      if (_from != MediaStatusIcon.none)
        (icon: _from, scale: 1 - t, opacity: 1 - t, turnDegrees: 0),
      if (_to != MediaStatusIcon.none)
        (icon: _to, scale: t, opacity: t, turnDegrees: 0),
    ];
  }

  /// The arc to draw now, or null for none.
  MediaStatusArc? get arc {
    if (!_arcShown) return null;
    if (_target.arc && _target.progress == null) {
      return (
        startDegrees: _startDegrees,
        sweepDegrees: MediaStatusPainting.spinnerSweepDegrees(
          style.spinner,
          _spinning,
        ),
      );
    }
    return (
      startDegrees: _startDegrees,
      sweepDegrees: math.max(style.minSweepDegrees, 360 * _shown),
    );
  }

  static double _ratio(Duration part, Duration whole) =>
      part.inMicroseconds / whole.inMicroseconds;
}
