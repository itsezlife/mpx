import 'package:flutter/foundation.dart';
import 'package:mpx/src/signals/device_signals.dart';

/// [IDeviceSignals] a test drives by hand: set a value on [network],
/// [powerSaving], [thermal] or [batteryLevel] and its listeners hear it.
final class FakeDeviceSignals implements IDeviceSignals {
  /// Signals starting at the given values, neutral by default.
  FakeDeviceSignals({
    NetworkClass network = NetworkClass.unmetered,
    bool powerSaving = false,
    ThermalStatus thermal = ThermalStatus.nominal,
    int? batteryLevel,
  }) : network = ValueNotifier(network),
       powerSaving = ValueNotifier(powerSaving),
       thermal = ValueNotifier(thermal),
       batteryLevel = ValueNotifier(batteryLevel);

  @override
  final ValueNotifier<NetworkClass> network;

  @override
  final ValueNotifier<bool> powerSaving;

  @override
  final ValueNotifier<ThermalStatus> thermal;

  @override
  final ValueNotifier<int?> batteryLevel;

  /// Whether [dispose] ran.
  bool get isDisposed => _disposed;
  bool _disposed = false;

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    network.dispose();
    powerSaving.dispose();
    thermal.dispose();
    batteryLevel.dispose();
  }
}
