import 'package:meta/meta.dart';
import 'package:mpx_core/src/asset/asset_binding.dart';
import 'package:mpx_core/src/asset/asset_readiness.dart';

/// The fades of one surface's binding: each stage that rises after the
/// attach goes from transparent to opaque over a length the surface picks
/// per rise ([opacityAt]), from the first frame it is drawn in. A stage there
/// at the attach (a memory hit) shows at once, so going back over loaded
/// media never flickers, and a rise of length zero swaps at once.
///
/// A stage that rises while another fades starts its own fade from that
/// frame.
///
/// Internal to the package: a surface keeps one per binding and reads
/// [opacityAt] when it paints.
@internal
final class AssetFade {
  /// The fades of the binding a surface just attached.
  AssetFade(this._binding) : _shown = _binding.readiness.stage;

  /// The default length of a fade.
  static const Duration duration = Duration(milliseconds: 150);

  final AssetBinding _binding;
  // The highest stage drawn opaque.
  AssetStage _shown;
  // The stage fading in, with when and over how long.
  AssetStage? _rising;
  Duration _start = Duration.zero;
  Duration _length = Duration.zero;

  /// The stage the fade is bringing in, or null when none fades.
  AssetStage? get rising => _rising;

  /// Takes the binding's stage as shown, with no fade: a stage that arrived
  /// while no surface showed the binding playing (its frame held) has no
  /// rise to show, and fading it in later would bring back the stand-in it
  /// replaced.
  void settle() {
    final stage = _binding.readiness.stage;
    if (stage.index <= _shown.index) return;
    _shown = stage;
    _rising = null;
  }

  /// The opacity to draw the binding's stage at in the frame at
  /// [frameTime]: 1 once its fade has run or when it swaps, else rising from
  /// 0 over the length [lengthOf] gives the rise from the stage shown before
  /// to the one now.
  double opacityAt(
    Duration frameTime,
    Duration Function(AssetStage from, AssetStage to) lengthOf,
  ) {
    final stage = _binding.readiness.stage;
    if (stage.index <= _shown.index) {
      _shown = stage;
      _rising = null;
      return 1;
    }
    if (_rising != stage) {
      final length = lengthOf(_shown, stage);
      if (length <= Duration.zero) {
        _shown = stage;
        _rising = null;
        return 1;
      }
      _rising = stage;
      _start = frameTime;
      _length = length;
    }
    final t = (frameTime - _start).inMicroseconds / _length.inMicroseconds;
    if (t >= 1) {
      _shown = stage;
      _rising = null;
      return 1;
    }
    return t.clamp(0.0, 1.0);
  }
}
