import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show ScrollController;
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_ui/src/library/picker_selection.dart';

/// The geometry and timing of a row of picked items: the picker viewer's
/// selected strip, or a host's own row driven by a [PickerStripController].
@immutable
final class PickerStripPolicy {
  /// Creates a policy; [PickerStripPolicy.$Android] is the standard row.
  const PickerStripPolicy({
    this.item = 85,
    this.gap = 6,
    this.ends = 6,
    this.leave = const Duration(milliseconds: 120),
    this.move = const Duration(milliseconds: 250),
    this.curve = Curves.easeInOutSine,
    this.edgeReach = 32,
    this.edgeStep = 6,
    this.edgeTick = const Duration(milliseconds: 15),
  });

  /// The standard row: 85 px items 6 apart; a removed item fades over
  /// 120 ms while the rest slide over 250 ms, both easing in and out, at
  /// once; a lifted item held within 32 px of an end scrolls the row by up
  /// to 6 px every 15 ms.
  static const PickerStripPolicy $Android = PickerStripPolicy();

  /// An item's side.
  final double item;

  /// The gap between items.
  final double gap;

  /// The row's padding before its first item and after its last.
  final double ends;

  /// How long a removed item takes to fade where it stood.
  final Duration leave;

  /// How long the items take to slide to new places.
  final Duration move;

  /// The curve of both.
  final Curve curve;

  /// How near an end a held item scrolls the row.
  final double edgeReach;

  /// The most the row scrolls a tick, at the very end.
  final double edgeStep;

  /// How often a held item scrolls the row.
  final Duration edgeTick;

  /// An item's place plus the gap after it.
  double get stride => item + gap;

  /// How far the row scrolls a tick toward its start (negative) or its end
  /// (positive) with the finger at [position] along a viewport of [extent]
  /// (both from the row's start edge, in its reading direction): nothing
  /// outside the reach, [edgeStep] at the very end, linearly between.
  double edgeDelta(double position, double extent) {
    final fromStart = position;
    final fromEnd = extent - position;
    if (fromStart < edgeReach) {
      return -(1 - math.max(0, fromStart) / edgeReach) * edgeStep;
    }
    if (fromEnd < edgeReach) {
      return (1 - math.max(0, fromEnd) / edgeReach) * edgeStep;
    }
    return 0;
  }
}

/// What a [PickerStripController] scrolls while a lifted item is held near
/// an end: any row that can jump along its axis, not only a
/// `ScrollController`'s.
abstract interface class PickerStripScrollTarget {
  /// A target over a scroll controller's single position.
  factory PickerStripScrollTarget.controller(ScrollController controller) =
      _ScrollControllerTarget;

  /// Whether the row is laid out and can scroll.
  bool get ready;

  /// How far the row is scrolled from its start.
  double get offset;

  /// The furthest it scrolls.
  double get maxOffset;

  /// Scrolls the row to [offset], clamped by the caller.
  void jumpTo(double offset);
}

final class _ScrollControllerTarget implements PickerStripScrollTarget {
  _ScrollControllerTarget(this._controller);

  final ScrollController _controller;

  @override
  bool get ready => _controller.hasClients;

  @override
  double get offset => _controller.offset;

  @override
  double get maxOffset => _controller.position.maxScrollExtent;

  @override
  void jumpTo(double offset) => _controller.jumpTo(offset);
}

/// The headless behaviour of a row of picked items, in their order: which
/// items show and which are leaving, a lifted item's reorder, and the
/// row's scroll while it is held near an end.
///
/// A deselected item stays as leaving, at the place it left, for the
/// policy's [PickerStripPolicy.leave] while the skin fades it and slides
/// the rest into the gap. A [lift]ed item follows [hold] (the finger along
/// the row's viewport): it moves to the place under the finger through
/// [onReorder], and near either end the row scrolls under it by the
/// policy's [PickerStripPolicy.edgeDelta] every tick until [drop].
///
/// The picker viewer's strip is one skin over it; a host draws its own row
/// over the same controller.
class PickerStripController extends ChangeNotifier {
  /// Creates the behaviour over [selection].
  PickerStripController({
    required this.selection,
    this.policy = PickerStripPolicy.$Android,
    this.onReorder,
  }) : _keys = selection.keys {
    selection.addListener(_onSelection);
  }

  /// The selection the row shows.
  final PickerSelection selection;

  /// Sizes and timing.
  final PickerStripPolicy policy;

  /// A lifted item was moved to the place [to] (0-based) of the selection;
  /// nothing lifts when null.
  final void Function(MediaKey key, int to)? onReorder;

  List<MediaKey> _keys;
  final Map<MediaKey, int> _leaving = {};
  final Map<MediaKey, Timer> _leaveTimers = {};
  MediaKey? _lifted;
  double? _held;
  double _extent = 0;
  PickerStripScrollTarget? _target;
  Timer? _edgeScroll;
  bool _disposed = false;

  /// The selected keys, in order.
  List<MediaKey> get keys => _keys;

  /// Keys deselected while shown, each with the place it left, until they
  /// have faded.
  Map<MediaKey, int> get leaving => Map.unmodifiable(_leaving);

  /// The item lifted for a reorder, or null.
  MediaKey? get lifted => _lifted;

  /// Whether items can be lifted.
  bool get reorders => onReorder != null;

  /// The row's length along its axis: the items without the ends.
  double get length =>
      _keys.isEmpty ? 0 : _keys.length * policy.stride - policy.gap;

  /// Where an item at place [index] starts, from the row's start inside its
  /// ends.
  double startOf(int index) => index * policy.stride;

  /// The row this scrolls while an item is held; the skin attaches its own.
  set target(PickerStripScrollTarget? value) => _target = value;

  void _onSelection() {
    final now = selection.keys;
    final kept = now.toSet();
    for (final (i, key) in _keys.indexed) {
      if (kept.contains(key) || _leaving.containsKey(key)) continue;
      _leaving[key] = i;
      _leaveTimers[key] = Timer(policy.leave, () {
        _leaving.remove(key);
        _leaveTimers.remove(key);
        if (!_disposed) notifyListeners();
      });
    }
    for (final key in kept) {
      _leaving.remove(key);
      _leaveTimers.remove(key)?.cancel();
    }
    _keys = now;
    if (_lifted case final key? when !kept.contains(key)) drop();
    notifyListeners();
  }

  /// Lifts [key] for a reorder; nothing without [onReorder].
  void lift(MediaKey key) {
    if (onReorder == null || !_keys.contains(key)) return;
    _lifted = key;
    notifyListeners();
  }

  /// The finger holding the lifted item is at [position] along a viewport
  /// of [extent], both from the row's start edge in its reading direction:
  /// the item moves to the place under it, and near an end the row scrolls.
  void hold(double position, double extent) {
    if (_lifted == null) return;
    _held = position;
    _extent = extent;
    _edgeScroll ??= Timer.periodic(policy.edgeTick, (_) => _scrollAtEdge());
    _reorderUnder();
  }

  /// Puts the lifted item down; the row stops scrolling.
  void drop() {
    _edgeScroll?.cancel();
    _edgeScroll = null;
    _held = null;
    if (_lifted == null) return;
    _lifted = null;
    if (!_disposed) notifyListeners();
  }

  void _reorderUnder() {
    final key = _lifted;
    final held = _held;
    if (key == null || held == null || _keys.isEmpty) return;
    final target = _target;
    final scrolled = target != null && target.ready ? target.offset : 0.0;
    final along = held + scrolled - policy.ends;
    final to = (along / policy.stride).floor().clamp(0, _keys.length - 1);
    if (_keys.indexOf(key) != to) onReorder?.call(key, to);
  }

  void _scrollAtEdge() {
    final target = _target;
    final held = _held;
    if (_lifted == null || held == null || target == null || !target.ready) {
      return;
    }
    final delta = policy.edgeDelta(held, _extent);
    if (delta == 0) return;
    final to = (target.offset + delta).clamp(0.0, target.maxOffset);
    if (to == target.offset) return;
    target.jumpTo(to);
    _reorderUnder();
  }

  @override
  void dispose() {
    _disposed = true;
    selection.removeListener(_onSelection);
    for (final timer in _leaveTimers.values) {
      timer.cancel();
    }
    _edgeScroll?.cancel();
    super.dispose();
  }
}
