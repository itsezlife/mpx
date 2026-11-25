import 'package:flutter/foundation.dart';

/// Tells when the system media volume goes up.
///
/// A video unmutes when the reader presses a volume key:
/// the reader who raises the volume wants to hear it. A rise is any step up
/// of the volume the device reports, from any level (silence included); a step
/// down or the same volume again is none, and the first reading is where the
/// volume stands, not a rise.
final class VolumeRise {
  /// Calls [onRise] for every rise of [volume].
  VolumeRise(this._volume, this.onRise) : _last = _volume.value {
    _volume.addListener(_onVolume);
  }

  final ValueListenable<int?> _volume;

  /// What a rise does.
  final VoidCallback onRise;

  int? _last;

  void _onVolume() {
    final now = _volume.value;
    final before = _last;
    _last = now;
    if (now != null && before != null && now > before) onRise();
  }

  /// Stops listening.
  void dispose() => _volume.removeListener(_onVolume);
}
