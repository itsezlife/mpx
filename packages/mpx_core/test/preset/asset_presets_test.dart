import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';

void main() {
  group('frame step', () {
    test('half rate shows every second frame of a source above 30 fps', () {
      const half = AssetPaintContext(halfFrameRate: true);

      expect(half.frameStepFor(60), 2);
      expect(half.frameStepFor(59.94), 2);
      expect(half.frameStepFor(30), 1);
      expect(half.frameStepFor(24), 1);
      expect(half.frameStepFor(0), 1);
    });

    test('full rate shows every frame', () {
      const full = AssetPaintContext();

      expect(full.frameStepFor(60), 1);
    });
  });

  group('animation', () {
    test('decodes at one size whatever the box, so a thumbnail and the '
        'fullscreen copy share one entry and one playback', () {
      const plays = AssetProfile(animate: true);
      final card = AssetPresets.animation(
        size: const Size(160, 160),
        profile: plays,
      );
      final viewer = AssetPresets.animation(
        size: const Size(400, 300),
        profile: const AssetProfile(animate: true, fit: AssetFit.cover),
      );

      expect(card.spec, viewer.spec);
      expect(
        card.spec,
        const AssetSpec(
          pixelWidth: AssetPresets.animationPixelExtent,
          pixelHeight: AssetPresets.animationPixelExtent,
        ),
      );
      expect(card.size, const Size(160, 160));
      expect(viewer.size, const Size(400, 300));
      expect(viewer.profile.fit, AssetFit.cover);
    });
  });

  group('square', () {
    test(
      'decodes an explicit extent at the density with the given profile',
      () {
        final preset = AssetPresets.square(
          extent: 40,
          devicePixelRatio: 2.5,
          profile: const AssetProfile(animate: true, loop: false),
        );

        expect(preset.size, const Size(40, 40));
        expect(preset.spec.pixelWidth, 100);
        expect(preset.spec.pixelHeight, 100);
        expect(preset.profile, const AssetProfile(animate: true, loop: false));
      },
    );
  });

  group('media', () {
    test('shows the box it is given and decodes it at the density', () {
      final preset = AssetPresets.media(
        size: const Size(160, 90),
        devicePixelRatio: 2,
        profile: const AssetProfile(animate: true),
      );

      expect(preset.size, const Size(160, 90));
      expect(preset.spec.pixelWidth, 320);
      expect(preset.spec.pixelHeight, 180);
      expect(preset.profile, const AssetProfile(animate: true));
    });

    test('caps the decode at the longer side, keeping the proportion', () {
      // A 206 dp item at density 3 is 618 px: decoded at 512.
      final square = AssetPresets.media(
        size: const Size.square(206),
        devicePixelRatio: 3,
        profile: const AssetProfile(),
        maxPixelExtent: 512,
      );
      final wide = AssetPresets.media(
        size: const Size(288, 162),
        devicePixelRatio: 3,
        profile: const AssetProfile(),
        maxPixelExtent: 512,
      );

      expect(square.size, const Size.square(206));
      expect((square.spec.pixelWidth, square.spec.pixelHeight), (512, 512));
      expect((wide.spec.pixelWidth, wide.spec.pixelHeight), (512, 288));
    });

    test('a decode under the cap is not enlarged to it', () {
      final preset = AssetPresets.media(
        size: const Size.square(112),
        devicePixelRatio: 3,
        profile: const AssetProfile(),
        maxPixelExtent: 512,
      );

      expect((preset.spec.pixelWidth, preset.spec.pixelHeight), (336, 336));
    });
  });

  group('AssetPreset', () {
    test('is equal to a preset of the same size, spec and profile', () {
      const spec = AssetSpec(pixelWidth: 4, pixelHeight: 4);
      const a = AssetPreset(
        size: Size(2, 2),
        spec: spec,
        profile: AssetProfile(),
      );
      const b = AssetPreset(
        size: Size(2, 2),
        spec: spec,
        profile: AssetProfile(),
      );
      const c = AssetPreset(
        size: Size(3, 3),
        spec: spec,
        profile: AssetProfile(),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
