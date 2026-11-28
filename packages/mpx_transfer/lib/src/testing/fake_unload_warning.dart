import 'package:mpx_transfer/src/journal/unload_warning.dart';

/// An [UnloadWarning] with no page: it records what the engine asked.
final class FakeUnloadWarning implements UnloadWarning {
  int _arms = 0;
  int _disarms = 0;
  bool _armed = false;

  @override
  bool get isArmed => _armed;

  /// How many times it went from disarmed to armed.
  int get arms => _arms;

  /// How many times it went from armed to disarmed.
  int get disarms => _disarms;

  @override
  void arm() {
    if (_armed) return;
    _armed = true;
    _arms++;
  }

  @override
  void disarm() {
    if (!_armed) return;
    _armed = false;
    _disarms++;
  }
}
