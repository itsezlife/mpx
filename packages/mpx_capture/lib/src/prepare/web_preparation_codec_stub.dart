import 'package:mpx_capture/src/prepare/preparation_codec.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';

/// The web's preparation codec; off the web every call throws an
/// [UnsupportedError] (use `PlatformPreparationCodec`).
final class WebPreparationCodec implements PreparationCodec {
  /// Creates the codec.
  const WebPreparationCodec();

  @override
  Future<StillSource> probeStill(String path) =>
      throw UnsupportedError('WebPreparationCodec runs on the web only');

  @override
  Future<EncodedStill> encodeStill(
    String path, {
    required int maxSide,
    required int quality,
    bool progressive = false,
    String? outputPath,
  }) => throw UnsupportedError('WebPreparationCodec runs on the web only');

  @override
  Future<EncodedStill> videoThumbnail(String path, ThumbnailSpec spec) =>
      throw UnsupportedError('WebPreparationCodec runs on the web only');
}
