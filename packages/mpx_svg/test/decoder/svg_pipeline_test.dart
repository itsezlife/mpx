import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';
import 'package:mpx_svg/mpx_svg.dart';

Uint8List _utf8(String text) => Uint8List.fromList(utf8.encode(text));

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeFetcher fetcher;
  late AssetPipeline pipeline;
  late AssetCacheScope scope;

  setUp(() {
    fetcher = FakeFetcher();
    pipeline = AssetPipeline(
      fetcher: fetcher,
      decoders: DecoderRegistry()
        ..register(MediaKind.vectorImage, SvgDecoder()),
    );
    scope = AssetCacheScope(
      producer: pipeline,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
    );
  });

  tearDown(() {
    scope.dispose();
    pipeline.dispose();
  });

  test('an SVG known as a vector image reaches the full stage in the scope, '
      'at each size it is attached at', () async {
    const icon = MediaDescriptor(
      key: MediaKey.external('https://host/icon.svg'),
      kind: MediaKind.vectorImage,
    );
    pipeline.know(icon);
    fetcher.serve(
      icon.key,
      FetchedContent.bytes(
        _utf8(
          '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"> '
          '<circle cx="12" cy="12" r="10"/></svg>',
        ),
      ),
    );

    final small = scope.attach(
      icon.key,
      const AssetSpec(pixelWidth: 24, pixelHeight: 24),
      const AssetProfile(),
    );
    final large = scope.attach(
      icon.key,
      const AssetSpec(pixelWidth: 96, pixelHeight: 96),
      const AssetProfile(),
    );
    await _until(() => small.readiness.isFinal && large.readiness.isFinal);

    expect(small.readiness.stage, AssetStage.full);
    expect(large.readiness.stage, AssetStage.full);
    small.detach();
    large.detach();
  });

  test('a refused SVG keeps the entry at its placeholder, never a failed '
      'stage', () async {
    const hostile = MediaDescriptor(
      key: MediaKey.external('https://host/hostile.svg'),
      kind: MediaKind.vectorImage,
    );
    pipeline.know(hostile);
    fetcher.serve(
      hostile.key,
      FetchedContent.bytes(
        _utf8(
          '<svg xmlns="http://www.w3.org/2000/svg" onload="steal()"> '
          '<rect width="1" height="1"/></svg>',
        ),
      ),
    );

    final binding = scope.attach(
      hostile.key,
      const AssetSpec(pixelWidth: 24, pixelHeight: 24),
      const AssetProfile(),
    );
    await _until(() => binding.lastError != null);

    expect(binding.readiness.stage, AssetStage.none);
    expect(
      (binding.lastError! as SvgRejection).reason,
      SvgRejectionReason.eventHandler,
    );
    binding.detach();
  });
}
