import 'package:flutter/foundation.dart';
import 'package:mpx_player/src/feed/feed_item.dart';

/// The host seam through which the device's network, power, heat and ringer
/// reach the feed: plain [ValueListenable]s in, one [FeedConditions] snapshot
/// out.
///
/// The feed reads no platform state. A host passes whatever it already tracks
/// (the device signals of the `mpx` package, its own plugin, a settings
/// toggle); an input left out keeps its neutral value (unmetered, not saving,
/// nominal, not silenced). The snapshot is what the autoplay gate and the list planner
/// weigh, and [metered] and [stressed] are the inputs the core's
/// `PlaybackActivity` takes to hold staged preloads back
/// (`meteredNetwork`, `thermalStress`, with [powerSaving] as `lowPower`).
///
/// It listens to its inputs only while it has listeners itself, and disposes
/// none of them.
final class FeedSignals extends ChangeNotifier
    implements ValueListenable<FeedConditions> {
  /// Creates a seam over the given inputs.
  FeedSignals({
    ValueListenable<FeedNetwork>? network,
    ValueListenable<bool>? powerSaving,
    ValueListenable<FeedThermal>? thermal,
    ValueListenable<bool>? silenced,
    ValueListenable<int?>? batteryLevel,
  }) : _network = network,
       _powerSaving = powerSaving,
       _thermal = thermal,
       _silenced = silenced,
       _battery = batteryLevel,
       _value = _read(network, powerSaving, thermal, silenced, batteryLevel);

  /// Creates a seam over inputs of the host's own types, mapped with
  /// [toNetwork] and [toThermal]: for signals whose enums mirror these (the
  /// `mpx` device signals map by name).
  static FeedSignals adapt<N, T>({
    ValueListenable<N>? network,
    FeedNetwork Function(N value)? toNetwork,
    ValueListenable<bool>? powerSaving,
    ValueListenable<T>? thermal,
    FeedThermal Function(T value)? toThermal,
    ValueListenable<bool>? silenced,
    ValueListenable<int?>? batteryLevel,
  }) {
    assert(
      network == null || toNetwork != null,
      'A network input needs its mapping.',
    );
    assert(
      thermal == null || toThermal != null,
      'A thermal input needs its mapping.',
    );
    return FeedSignals(
      network: network == null ? null : _Mapped(network, toNetwork!),
      powerSaving: powerSaving,
      thermal: thermal == null ? null : _Mapped(thermal, toThermal!),
      silenced: silenced,
      batteryLevel: batteryLevel,
    );
  }

  final ValueListenable<FeedNetwork>? _network;
  final ValueListenable<bool>? _powerSaving;
  final ValueListenable<FeedThermal>? _thermal;
  final ValueListenable<bool>? _silenced;
  final ValueListenable<int?>? _battery;
  FeedConditions _value;
  bool _following = false;

  static FeedConditions _read(
    ValueListenable<FeedNetwork>? network,
    ValueListenable<bool>? powerSaving,
    ValueListenable<FeedThermal>? thermal,
    ValueListenable<bool>? silenced,
    ValueListenable<int?>? battery,
  ) => FeedConditions(
    network: network?.value ?? FeedNetwork.unmetered,
    powerSaving: powerSaving?.value ?? false,
    thermal: thermal?.value ?? FeedThermal.nominal,
    silenced: silenced?.value ?? false,
    batteryLevel: battery?.value,
  );

  /// The conditions now. Read fresh while nobody listens, so a snapshot taken
  /// without a listener is never stale.
  @override
  FeedConditions get value => _following
      ? _value
      : _read(_network, _powerSaving, _thermal, _silenced, _battery);

  /// Whether the network costs the user (metered or roaming), as a listenable
  /// for the core's `meteredNetwork` pause layer.
  late final ValueListenable<bool> metered = _Derived(
    this,
    (conditions) =>
        conditions.network == FeedNetwork.metered ||
        conditions.network == FeedNetwork.roaming,
  );

  /// Whether the device saves power, for the core's `lowPower` layer.
  late final ValueListenable<bool> powerSaving = _Derived(
    this,
    (conditions) => conditions.powerSaving,
  );

  /// Whether the device runs hot enough to throttle, for the core's
  /// `thermalStress` layer.
  late final ValueListenable<bool> stressed = _Derived(
    this,
    (conditions) => conditions.stressed,
  );

  @override
  void addListener(VoidCallback listener) {
    if (!hasListeners) _follow(true);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _follow(false);
  }

  void _follow(bool on) {
    if (on == _following) return;
    _following = on;
    for (final input in <Listenable?>[
      _network,
      _powerSaving,
      _thermal,
      _silenced,
      _battery,
    ]) {
      if (on) {
        input?.addListener(_changed);
      } else {
        input?.removeListener(_changed);
      }
    }
    if (on)
      _value = _read(_network, _powerSaving, _thermal, _silenced, _battery);
  }

  void _changed() {
    final next = _read(_network, _powerSaving, _thermal, _silenced, _battery);
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _follow(false);
    super.dispose();
  }
}

// A view of [source] through [map].
final class _Mapped<S, T> extends ChangeNotifier implements ValueListenable<T> {
  _Mapped(this._source, this._map);

  final ValueListenable<S> _source;
  final T Function(S value) _map;

  @override
  T get value => _map(_source.value);

  @override
  void addListener(VoidCallback listener) {
    if (!hasListeners) _source.addListener(notifyListeners);
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _source.removeListener(notifyListeners);
  }
}

// One bool of [source]'s conditions, signalled only when it changes.
final class _Derived extends ChangeNotifier implements ValueListenable<bool> {
  _Derived(this._source, this._pick);

  final ValueListenable<FeedConditions> _source;
  final bool Function(FeedConditions conditions) _pick;
  bool? _last;

  @override
  bool get value => _pick(_source.value);

  void _changed() {
    final next = value;
    if (next == _last) return;
    _last = next;
    notifyListeners();
  }

  @override
  void addListener(VoidCallback listener) {
    if (!hasListeners) {
      _source.addListener(_changed);
      _last = value;
    }
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _source.removeListener(_changed);
  }
}
