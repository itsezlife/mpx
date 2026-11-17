import 'package:flutter/painting.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_player/native.dart';
import 'package:mpx_player_example/local_media.dart';

/// The platform still extractor on the device: the first frame of the clip,
/// read through the bytes cache's native reader from a loopback origin.
///
/// The clip is H.264, which the platform draws everywhere; the AV1 and HEVC
/// samples of the mpx example are the device check.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late LocalMedia media;

  setUpAll(() async => media = await LocalMedia.start());
  tearDownAll(() => media.close());

  Future<_Report> decode(MediaKey key) async {
    final report = _Report();
    PlatformStillDecoder().decode(
      DecodeRequest(
        descriptor: MediaDescriptor(key: key, kind: MediaKind.video),
        spec: const AssetSpec(pixelWidth: 160, pixelHeight: 160),
        part: FetchPart.content,
        content: await media.publish(key),
      ),
      report,
    );
    for (var i = 0; i < 200 && !report.done; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return report;
  }

  testWidgets('draws the first frame of a clip within the spec', (_) async {
    final report = await decode(LocalMedia.clip);

    expect(report.failure, isNull);
    expect(report.stage, AssetStage.firstFrame);
    final size = report.paintable!.pictureSize!;
    expect(size.longestSide, lessThanOrEqualTo(160));
    expect(size, isNot(Size.zero));
  });

  testWidgets('bytes that are no video draw nothing', (_) async {
    final report = await decode(LocalMedia.garbage);

    expect(report.failure, isA<DecodeFailure>());
    expect(report.stage, isNull);
  });
}

final class _Report implements AssetProgress {
  AssetStage? stage;
  AssetPaintable? paintable;
  Object? failure;

  bool get done => stage != null || failure != null;

  @override
  void advance(
    AssetStage stage,
    AssetPaintable paintable, {
    required int bytes,
    AssetTier tier = AssetTier.still,
  }) {
    this.stage = stage;
    this.paintable = paintable;
  }

  @override
  void fail(
    Object error, [
    StackTrace? stackTrace,
    AssetFailureKind kind = AssetFailureKind.transient,
  ]) => failure = error;

  @override
  void bestReached() {}

  @override
  void cancelled() {}

  @override
  void describe(MediaDescriptor descriptor) {}

  @override
  void waiting() {}

  @override
  void transfer(int received, int? total) {}

  @override
  void awaitingUser() {}
}
