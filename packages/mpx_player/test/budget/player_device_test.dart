import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_player/mpx_player.dart';

void main() {
  const hevc8 = PlayerDecoder(
    mimeType: 'video/hevc',
    hardware: true,
    maxInstances: 8,
  );
  const hevc4 = PlayerDecoder(
    mimeType: 'video/hevc',
    hardware: true,
    maxInstances: 4,
  );

  group('PlayerDevice', () {
    test('a high-class device with 8 HEVC instances keeps two prepared', () {
      const device = PlayerDevice(performanceClass: 31, decoders: [hevc8]);

      expect(device.isHighClass, isTrue);
      expect(device.budget, const PlayerBudget(prepared: 2));
    });

    test('fewer HEVC instances keep none prepared', () {
      const device = PlayerDevice(performanceClass: 33, decoders: [hevc4]);

      expect(device.budget, const PlayerBudget(prepared: 0));
    });

    test('a device that is not high class keeps none prepared', () {
      const device = PlayerDevice(
        cpuCount: 4,
        memoryClassMb: 128,
        decoders: [hevc8],
      );

      expect(device.isHighClass, isFalse);
      expect(device.budget, const PlayerBudget(prepared: 0));
    });

    test('eight cores and a large memory class count as high class', () {
      const device = PlayerDevice(
        cpuCount: 8,
        memoryClassMb: 256,
        decoders: [hevc8],
      );

      expect(device.isHighClass, isTrue);
    });

    test('a low-RAM device is never high class', () {
      const device = PlayerDevice(
        lowRam: true,
        performanceClass: 34,
        decoders: [hevc8],
      );

      expect(device.isHighClass, isFalse);
    });

    test('the largest instance count of a type counts', () {
      const device = PlayerDevice(decoders: [hevc4, hevc8]);

      expect(device.maxInstancesOf('video/hevc'), 8);
      expect(device.maxInstancesOf('video/av01'), 0);
    });

    test('a platform that names no instance count gates on class alone', () {
      // Apple: no documented decoder-instance limit.
      const device = PlayerDevice(
        totalMemoryBytes: 6 << 30,
        decoders: [PlayerDecoder(mimeType: 'video/hevc', hardware: true)],
        instanceCountsKnown: false,
      );

      expect(device.isHighClass, isTrue);
      expect(device.budget, const PlayerBudget(prepared: 2));
    });

    test('a codec that failed before is not decodable', () {
      const device = PlayerDevice(
        decoders: [PlayerDecoder(mimeType: 'video/av01', hardware: true)],
        failedCodecs: {'video/av01'},
      );

      expect(device.canDecode('video/av01'), isFalse);
    });

    test('a codec without a hardware decoder is not decodable', () {
      const device = PlayerDevice(
        decoders: [PlayerDecoder(mimeType: 'video/av01', hardware: false)],
      );

      expect(device.canDecode('video/av01'), isFalse);
      expect(device.canDecode('video/avc'), isFalse);
    });

    test('a container the platform does not open is not playable', () {
      const device = PlayerDevice(containers: {'video/mp4'});

      expect(device.opensContainer('video/mp4'), isTrue);
      expect(device.opensContainer('video/webm'), isFalse);
    });

    test('a platform that names no containers opens any', () {
      const device = PlayerDevice();

      expect(device.opensContainer('video/webm'), isTrue);
    });
  });
}
