import 'dart:typed_data';

import 'package:mpx_capture/src/job/capture_job.dart';
import 'package:mpx_capture/src/platform/capture_channel.dart';
import 'package:mpx_capture/src/prepare/preparation_codec.dart';
import 'package:mpx_capture/src/prepare/preparation_policy.dart';
import 'package:mpx_core/mpx_core.dart';

/// The [PreparationCodec] over the platform: a downsampled `BitmapFactory`
/// decode and `Bitmap.compress` on Android, ImageIO thumbnails and
/// destinations on iOS and macOS (progressive where asked; Android writes
/// baseline JPEGs only). Video posters come from `MediaMetadataRetriever`
/// and `AVAssetImageGenerator`.
final class PlatformPreparationCodec implements PreparationCodec {
  /// Creates the codec; it holds no native resource.
  const PlatformPreparationCodec();

  static CaptureChannel get _channel => CaptureChannel.instance;

  @override
  Future<StillSource> probeStill(String path) async {
    final map = await _channel.invoke<Map<Object?, Object?>>('stillProbe', {
      'path': path,
    });
    if (map == null) throw CaptureFailed('not a still: $path');
    return StillSource(
      dimensions: MediaDimensions(map['width']! as int, map['height']! as int),
      byteSize: map['size']! as int,
      mimeType: map['mime'] as String?,
      animated: map['animated'] as bool? ?? false,
    );
  }

  @override
  Future<EncodedStill> encodeStill(
    String path, {
    required int maxSide,
    required int quality,
    bool progressive = false,
    String? outputPath,
  }) async => _encoded(
    await _channel.invoke<Map<Object?, Object?>>('stillEncode', {
      'path': path,
      'maxSide': maxSide,
      'quality': quality,
      'progressive': progressive,
      'output': outputPath,
    }),
    path,
  );

  @override
  Future<EncodedStill> videoThumbnail(String path, ThumbnailSpec spec) async =>
      _encoded(
        await _channel.invoke<Map<Object?, Object?>>('videoThumbnail', {
          'path': path,
          'maxSide': spec.side,
          'quality': spec.quality,
        }),
        path,
      );

  static EncodedStill _encoded(Map<Object?, Object?>? map, String path) {
    if (map == null) throw CaptureFailed('nothing encoded from $path');
    return EncodedStill(
      dimensions: MediaDimensions(map['width']! as int, map['height']! as int),
      byteSize: map['size']! as int,
      bytes: map['bytes'] as Uint8List?,
    );
  }
}
