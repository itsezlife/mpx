import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';

/// Why a picker selection refused a key.
enum PickerRefusal {
  /// The selection holds as many as it may.
  cap,

  /// The host does not take this kind of media here.
  kind,

  /// Another reason of the host's.
  other,
}

/// What a toggle did.
@immutable
sealed class PickerToggle {
  const PickerToggle();
}

/// The key joined the selection, at [order] (1-based).
final class PickerToggle$Selected extends PickerToggle {
  /// Creates the result.
  const PickerToggle$Selected(this.order);

  /// The key's order number.
  final int order;
}

/// The key left the selection.
final class PickerToggle$Deselected extends PickerToggle {
  /// Creates the result.
  const PickerToggle$Deselected();
}

/// The key was refused for [reason]; nothing changed.
final class PickerToggle$Refused extends PickerToggle {
  /// Creates the result.
  const PickerToggle$Refused(this.reason);

  /// Why.
  final PickerRefusal reason;
}

/// The ordered selection the library grid and the picker-mode viewer
/// share. A host that counts picks from the library, its files and the
/// camera in one order implements it; a simple host takes
/// [OrderedPickerSelection].
///
/// ## Contract
///
/// - [orderOf] is 1-based in selection order; removing a key re-numbers the
///   later ones.
/// - [toggle] answers what it did; a refused toggle changes nothing.
/// - [toggleRange] gives every key the state the first one takes (or [to]
///   when set), skipping keys the gate refuses.
/// - [refusalOf] answers what selecting a key would be refused for now
///   (null when it would be taken); a grid dims such keys.
/// - The selection notifies its listeners on every change.
abstract interface class PickerSelection implements Listenable {
  /// The selected keys, in order.
  List<MediaKey> get keys;

  /// The 1-based order of [key], or null when it is not selected.
  int? orderOf(MediaKey key);

  /// Selects [key] when it is not selected, deselects it when it is.
  PickerToggle toggle(MediaKey key);

  /// Gives every key of [keys] one state: [to] when set, else the state
  /// the first key takes when toggled. Answers the refusals met.
  List<(MediaKey, PickerRefusal)> toggleRange(List<MediaKey> keys, {bool? to});

  /// Why selecting [key] would be refused now, or null.
  PickerRefusal? refusalOf(MediaKey key);
}

/// A host's check of a key before it is selected: null takes it, a
/// [PickerRefusal] refuses it.
typedef PickerGate = PickerRefusal? Function(MediaKey key);

/// The default [PickerSelection]: ordered by selection, with a [cap] the
/// host sets (unbounded when null), an optional host [gate], and a [single]
/// mode in which selecting a key replaces the one before.
final class OrderedPickerSelection extends ChangeNotifier
    implements PickerSelection {
  /// Creates an empty selection.
  OrderedPickerSelection({this.cap, this.gate, this.single = false})
    : assert(cap == null || cap > 0, 'A cap is positive.');

  /// The most keys it holds; null for no limit.
  final int? cap;

  /// The host's check, run before the cap.
  final PickerGate? gate;

  /// Whether one key at most is selected, a new one replacing it.
  final bool single;

  final List<MediaKey> _keys = [];
  final Map<MediaKey, int> _index = {};

  @override
  List<MediaKey> get keys => List.unmodifiable(_keys);

  @override
  int? orderOf(MediaKey key) => switch (_index[key]) {
    final index? => index + 1,
    null => null,
  };

  @override
  PickerRefusal? refusalOf(MediaKey key) {
    if (_index.containsKey(key)) return null;
    final refused = gate?.call(key);
    if (refused != null) return refused;
    final cap = this.cap;
    if (!single && cap != null && _keys.length >= cap) return PickerRefusal.cap;
    return null;
  }

  @override
  PickerToggle toggle(MediaKey key) {
    if (_index.containsKey(key)) {
      _remove(key);
      notifyListeners();
      return const PickerToggle$Deselected();
    }
    final refused = refusalOf(key);
    if (refused != null) return PickerToggle$Refused(refused);
    if (single) _clear();
    _add(key);
    notifyListeners();
    return PickerToggle$Selected(_keys.length);
  }

  @override
  List<(MediaKey, PickerRefusal)> toggleRange(List<MediaKey> keys, {bool? to}) {
    if (keys.isEmpty) return const [];
    final selecting = to ?? !_index.containsKey(keys.first);
    final refusals = <(MediaKey, PickerRefusal)>[];
    var changed = false;
    for (final key in keys) {
      final selected = _index.containsKey(key);
      if (selected == selecting) continue;
      if (!selecting) {
        _remove(key);
        changed = true;
        continue;
      }
      final refused = refusalOf(key);
      if (refused != null) {
        refusals.add((key, refused));
        continue;
      }
      if (single) _clear();
      _add(key);
      changed = true;
    }
    if (changed) notifyListeners();
    return refusals;
  }

  /// Moves [key] to [to] (0-based) in the order, the keys between shifting
  /// by one; nothing when [key] is not selected or already there. What a
  /// selected-items preview's drag to reorder calls.
  void move(MediaKey key, int to) {
    final from = _index[key];
    if (from == null) return;
    final target = to.clamp(0, _keys.length - 1);
    if (target == from) return;
    _keys
      ..removeAt(from)
      ..insert(target, key);
    for (var i = math.min(from, target); i <= math.max(from, target); i++) {
      _index[_keys[i]] = i;
    }
    notifyListeners();
  }

  /// Deselects everything.
  void clear() {
    if (_keys.isEmpty) return;
    _clear();
    notifyListeners();
  }

  void _add(MediaKey key) {
    _index[key] = _keys.length;
    _keys.add(key);
  }

  void _remove(MediaKey key) {
    final index = _index.remove(key);
    if (index == null) return;
    _keys.removeAt(index);
    for (var i = index; i < _keys.length; i++) {
      _index[_keys[i]] = i;
    }
  }

  void _clear() {
    _keys.clear();
    _index.clear();
  }
}
