import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';

/// The timings of a gallery's taps: how long a single tap waits for a
/// second one, how far a press moves before it is no tap, and how close the
/// second press of a double tap lands.
@immutable
final class GalleryTapRules {
  /// Creates the rules.
  const GalleryTapRules({
    required this.doubleTapDelay,
    required this.tapSlop,
    required this.doubleTapSlop,
    this.minDoubleTapGap = Duration.zero,
  });

  /// The Android rules: a single tap waits 300 ms after the lift for a
  /// second press, which counts 40 ms to 300 ms after the lift and within
  /// 100 px of the first; a press that moves 8 px is no tap.
  static const GalleryTapRules $Android = GalleryTapRules(
    doubleTapDelay: Duration(milliseconds: 300),
    minDoubleTapGap: Duration(milliseconds: 40),
    tapSlop: 8,
    doubleTapSlop: 100,
  );

  /// The iOS rules: a single tap waits 160 ms after the lift when a
  /// double tap is possible; a press that moves into a pan is no tap.
  static const GalleryTapRules $IOS = GalleryTapRules(
    doubleTapDelay: Duration(milliseconds: 160),
    tapSlop: 10,
    doubleTapSlop: 100,
  );

  /// The desktop rules: a click waits for a double click only where one
  /// does something; a press dragged 10 px is no click.
  static const GalleryTapRules $Desktop = GalleryTapRules(
    doubleTapDelay: Duration(milliseconds: 300),
    tapSlop: 10,
    doubleTapSlop: 10,
  );

  /// How long a single tap waits after its lift for the second press of a
  /// double tap, where a double tap does something; a tap where it does not
  /// fires at once.
  final Duration doubleTapDelay;

  /// The shortest time from the first lift to the second press of a double
  /// tap.
  final Duration minDoubleTapGap;

  /// How far a press moves before it is no tap and no hold.
  final double tapSlop;

  /// How far from the first press the second press of a double tap lands.
  final double doubleTapSlop;

  /// These rules with the given fields changed.
  GalleryTapRules copyWith({
    Duration? doubleTapDelay,
    Duration? minDoubleTapGap,
    double? tapSlop,
    double? doubleTapSlop,
  }) => GalleryTapRules(
    doubleTapDelay: doubleTapDelay ?? this.doubleTapDelay,
    minDoubleTapGap: minDoubleTapGap ?? this.minDoubleTapGap,
    tapSlop: tapSlop ?? this.tapSlop,
    doubleTapSlop: doubleTapSlop ?? this.doubleTapSlop,
  );

  @override
  bool operator ==(Object other) =>
      other is GalleryTapRules &&
      other.doubleTapDelay == doubleTapDelay &&
      other.minDoubleTapGap == minDoubleTapGap &&
      other.tapSlop == tapSlop &&
      other.doubleTapSlop == doubleTapSlop;

  @override
  int get hashCode =>
      Object.hash(doubleTapDelay, minDoubleTapGap, tapSlop, doubleTapSlop);
}

/// Where a [GalleryTapRecognizer] sends what it recognises. Positions are
/// local to the recognizer's widget.
abstract interface class GalleryTapTarget {
  /// Whether presses are ignored now (a settle runs that touches do not
  /// catch).
  bool get ignoresTouch;

  /// How long a press is held before [holdStart]; null for no hold.
  Duration? get holdDelay;

  /// Whether a double tap at [local] does something.
  bool acceptsDoubleTap(Offset local);

  /// A tap ([press] false) or a press ([press] true) at [local] on a side
  /// strip; true when it paged.
  bool sideTap(Offset local, {required bool press});

  /// A single tap.
  void tap(Offset local);

  /// A double tap, at its second press.
  void doubleTap(Offset local);

  /// A press held; true when taken.
  bool holdStart(Offset local);

  /// The held press moved.
  void holdMove(Offset local);

  /// The held press ended.
  void holdEnd();
}

/// The gallery's one tap recognizer: single tap, double tap (fired at the
/// second press), side-strip taps and a held press, with
/// [GalleryTapRules]' timings.
///
/// It sits in the arena beside the gallery's gesture owner. It never claims
/// a press that moves past [GalleryTapRules.tapSlop]; it takes the arena at
/// once for a double tap's second press, a side press and a hold the
/// target took, so the owner never pages, pans or dismisses on those. A
/// lifted press fires only once the arena gives it the press: a control
/// deeper in the tree that wins its tap keeps it.
///
/// A stock double-tap recognizer waits a fixed 300 ms and fires on the
/// second lift; the platforms wait their own delays, skip the wait where a
/// double tap does nothing, and fire on the second press.
class GalleryTapRecognizer extends OneSequenceGestureRecognizer {
  /// Creates the recognizer.
  GalleryTapRecognizer({super.debugOwner, super.supportedDevices});

  /// The timings.
  GalleryTapRules rules = GalleryTapRules.$Android;

  /// Where taps go; nothing is recognised while null.
  GalleryTapTarget? target;

  int? _pointer;
  Offset _downLocal = Offset.zero;
  Offset _downGlobal = Offset.zero;
  Timer? _holdTimer;
  bool _holding = false;
  bool _accepted = false;
  bool _upPending = false;
  // The press went to a double tap or a side press: its lift is nothing.
  bool _consumed = false;

  // The first tap of a possible double tap, waiting.
  Timer? _single;
  Offset _firstGlobal = Offset.zero;
  // Runs from the first lift for the shortest double-tap gap. Timers rather
  // than event time stamps: both follow the same clock in tests.
  Timer? _tooSoon;

  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      (event.kind != PointerDeviceKind.mouse ||
          event.buttons == kPrimaryButton) &&
      super.isPointerAllowed(event);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final target = this.target;
    if (_pointer != null) {
      // A second finger: a pinch, not a tap.
      _cancelPress();
      _single?.cancel();
      resolve(GestureDisposition.rejected);
      return;
    }
    if (target == null || target.ignoresTouch) return;
    _pointer = event.pointer;
    _downLocal = event.localPosition;
    _downGlobal = event.position;
    _accepted = false;
    _upPending = false;
    _consumed = false;
    _holding = false;
    startTrackingPointer(event.pointer, event.transform);
    final waiting = _single;
    if (waiting != null && waiting.isActive) {
      waiting.cancel();
      final soon = _tooSoon?.isActive ?? false;
      if (!soon &&
          (event.position - _firstGlobal).distance <= rules.doubleTapSlop) {
        _consumed = true;
        resolve(GestureDisposition.accepted);
        target.doubleTap(event.localPosition);
        return;
      }
      // Too far or too soon: the first tap is dropped.
    }
    if (target.sideTap(event.localPosition, press: true)) {
      _consumed = true;
      resolve(GestureDisposition.accepted);
      return;
    }
    if (target.holdDelay case final delay?) {
      _holdTimer = Timer(delay, _held);
    }
  }

  void _held() {
    final target = this.target;
    if (_pointer == null || _consumed || target == null) return;
    if (!target.holdStart(_downLocal)) return;
    _holding = true;
    resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event.pointer != _pointer) return;
    switch (event) {
      case PointerMoveEvent():
        if (_holding) {
          target?.holdMove(event.localPosition);
        } else if (!_consumed &&
            (event.position - _downGlobal).distance > rules.tapSlop) {
          _cancelPress();
          resolve(GestureDisposition.rejected);
        }
      case PointerUpEvent():
        if (_holding) {
          _holding = false;
          target?.holdEnd();
        } else if (!_consumed) {
          _upPending = true;
          _firstGlobal = _downGlobal;
          _tooSoon?.cancel();
          _tooSoon = rules.minDoubleTapGap > Duration.zero
              ? Timer(rules.minDoubleTapGap, () {})
              : null;
          if (_accepted) _lifted();
        }
        _holdTimer?.cancel();
        stopTrackingPointer(event.pointer);
      case PointerCancelEvent():
        if (_holding) {
          _holding = false;
          target?.holdEnd();
        }
        _cancelPress();
        resolve(GestureDisposition.rejected);
      default:
    }
  }

  void _lifted() {
    _upPending = false;
    final target = this.target;
    if (target == null) return;
    final local = _downLocal;
    if (target.sideTap(local, press: false)) return;
    if (target.acceptsDoubleTap(local)) {
      _single?.cancel();
      _single = Timer(rules.doubleTapDelay, () => this.target?.tap(local));
    } else {
      target.tap(local);
    }
  }

  void _cancelPress() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _upPending = false;
    if (_pointer case final pointer?) stopTrackingPointer(pointer);
  }

  @override
  void acceptGesture(int pointer) {
    _accepted = true;
    if (_upPending) _lifted();
  }

  @override
  void rejectGesture(int pointer) {
    if (_holding) {
      _holding = false;
      target?.holdEnd();
    }
    _cancelPress();
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _holdTimer?.cancel();
    _holdTimer = null;
    _pointer = null;
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _single?.cancel();
    _tooSoon?.cancel();
    super.dispose();
  }

  @override
  String get debugDescription => 'gallery tap';
}
