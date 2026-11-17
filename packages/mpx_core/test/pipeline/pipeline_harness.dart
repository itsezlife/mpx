import 'dart:typed_data';

import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/testing.dart';

const profile = AssetProfile();
const spec = AssetSpec(pixelWidth: 64, pixelHeight: 64);
const firstFrameSpec = AssetSpec(
  pixelWidth: 64,
  pixelHeight: 64,
  variant: AssetVariant.firstFrame,
);

/// The descriptor of sticker [n], with a thumbnail unless [thumbnail] is off.
MediaDescriptor sticker(int n, {bool thumbnail = false}) => MediaDescriptor(
  key: MediaKey.remote('sticker-$n'),
  kind: MediaKind.still,
  thumbnail: thumbnail ? MediaThumbnailRef('thumb-$n') : null,
);

final bytes = FetchedContent.bytes(Uint8List.fromList(const [1, 2, 3]));

/// A scope over an [AssetPipeline] made of fakes.
final class PipelineHarness {
  PipelineHarness({
    bool autoFetch = true,
    bool autoDecode = true,
    bool firstFrameEarly = false,
    MediaResolver? resolver,
    AssetPipelineLimits limits = const AssetPipelineLimits(),
    Iterable<MediaDescriptor> known = const [],
    Iterable<MediaDescriptor> served = const [],
    AutoDownloadPolicy autoDownload = AutoDownloadPolicy.always,
  }) : fetcher = FakeFetcher(autoRespond: autoFetch),
       decoder = FakeDecoder(
         autoRespond: autoDecode,
         reportFirstFrame: firstFrameEarly,
       ) {
    pipeline = AssetPipeline(
      fetcher: fetcher,
      decoders: DecoderRegistry()..register(MediaKind.still, decoder),
      resolver: resolver,
      limits: limits,
    );
    scope = AssetCacheScope(
      producer: pipeline,
      clock: PlaybackClock(ticks: ManualPlaybackTickSource()),
      autoDownload: autoDownload,
    );
    for (final descriptor in [...known, ...served]) {
      fetcher.serve(descriptor.key, bytes);
      if (descriptor.thumbnail != null) {
        fetcher.serveThumbnail(descriptor.thumbnail!, bytes);
      }
    }
    known.forEach(pipeline.know);
  }

  final FakeFetcher fetcher;
  final FakeDecoder decoder;
  late final AssetPipeline pipeline;
  late final AssetCacheScope scope;

  AssetBinding attach(
    MediaDescriptor descriptor, [
    AssetSpec spec = spec,
    AutoDownloadContext? context,
  ]) => scope.attach(descriptor.key, spec, profile, downloadContext: context);

  AssetBinding attachKey(MediaKey key, [AssetSpec spec = spec]) =>
      scope.attach(key, spec, profile);

  /// Lets queued microtasks and futures run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void dispose() {
    scope.dispose();
    pipeline.dispose();
  }
}
