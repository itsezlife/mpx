import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  test('copyWith changes only what it is given', () {
    const profile = AssetProfile(
      animate: true,
      loop: false,
      restFrame: AssetRestFrame.last,
      autoplayFirstFrame: false,
      cornerRadius: 8,
      fit: AssetFit.cover,
      halfFrameRate: true,
      foreground: true,
      advanceFloor: 0.25,
    );

    expect(
      profile.copyWith(animate: false),
      const AssetProfile(
        loop: false,
        restFrame: AssetRestFrame.last,
        autoplayFirstFrame: false,
        cornerRadius: 8,
        fit: AssetFit.cover,
        halfFrameRate: true,
        foreground: true,
        advanceFloor: 0.25,
      ),
    );
    expect(profile.copyWith(), profile);
  });
}
