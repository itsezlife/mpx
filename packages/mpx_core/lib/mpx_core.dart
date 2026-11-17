/// The core of mpx: media identity, the asset cache and its fetch and decode
/// pipeline, the playback clock, budgets and the platform texture hosts.
///
/// A host creates one `AssetCacheScope` and hands it to the surfaces that
/// draw media. A surface calls `attach(key, spec, profile)` with a `MediaKey`
/// and gets an `AssetBinding`: a staged readiness (`none`, `preview`,
/// `placeholder`, `firstFrame`, `full`, never a failed one), an `AssetPaintable` to draw,
/// and a pin that keeps the entry in a byte-budgeted LRU until `detach`.
/// Media is made behind the `AssetProducer` seam: `AssetPipeline` resolves
/// unknown keys through the host's `MediaResolver`, fetches through its
/// `ContentFetcher` and decodes with the `Decoder` registered for the
/// `MediaKind` (`ImageCodecDecoder` reads the engine's image formats). One
/// `PlaybackClock` advances every animation, gated per binding and by
/// host-set pause layers.
///
/// Surfaces draw through `ContentView`, with the scope handed down by
/// `AssetCacheProvider`. `AssetPresets` builds the size, spec and profile of
/// a surface; a host names its own surfaces' presets.
///
/// Playing assets may render into platform textures:
/// `PlatformFrameTextureHost.forPlatform` answers the host of Android, iOS or
/// macOS (null elsewhere), which a `FrameTexturePool` lends to the scope.
///
/// Single-threaded on the UI isolate; no static state.
library;

export 'src/asset/asset_binding.dart';
export 'src/asset/asset_cache_budgets.dart';
export 'src/asset/asset_cache_scope.dart';
export 'src/asset/asset_fit.dart';
export 'src/asset/asset_paintable.dart';
export 'src/asset/asset_playback.dart';
export 'src/asset/asset_preload.dart';
export 'src/asset/asset_preset.dart';
export 'src/asset/asset_producer.dart';
export 'src/asset/asset_profile.dart';
export 'src/asset/asset_readiness.dart';
export 'src/asset/asset_spec.dart';
export 'src/asset/asset_texture.dart';
export 'src/asset/asset_texture_layer.dart';
export 'src/asset/asset_transfer.dart';
export 'src/asset/atlas_sprite.dart';
export 'src/asset/circle_placeholder.dart';
export 'src/asset/clear_placeholder.dart';
export 'src/asset/mini_thumbnail.dart';
export 'src/asset/radial_progress.dart';
export 'src/asset/rect_placeholder.dart';
export 'src/asset/soft_placeholder.dart';
export 'src/identity/media_descriptor.dart';
export 'src/identity/media_key.dart';
export 'src/image/image_codec_decoder.dart';
export 'src/pipeline/asset_pipeline.dart';
export 'src/pipeline/auto_download.dart';
export 'src/pipeline/cancellation_token.dart';
export 'src/pipeline/content_fetcher.dart';
export 'src/pipeline/decoder.dart';
export 'src/pipeline/media_resolver.dart';
export 'src/playback/playback_activity.dart';
export 'src/playback/playback_clock.dart'
    show PlaybackClock, PlaybackSubscription;
export 'src/playback/playback_lifecycle_source.dart';
export 'src/playback/playback_policy.dart';
export 'src/playback/playback_tick_source.dart';
export 'src/playback/scheduler_playback_tick_source.dart';
export 'src/playback/widgets_playback_lifecycle_source.dart';
export 'src/texture/frame_texture_host.dart';
export 'src/texture/frame_texture_pool.dart';
export 'src/texture/platform/frame_texture_natives.dart';
export 'src/texture/platform/platform_frame_texture_host.dart';
export 'src/texture/texture_frame_writer.dart';
export 'src/widget/asset_cache_provider.dart';
export 'src/widget/content_view.dart';
export 'src/widget/media_badge.dart';
export 'src/widget/media_badge_style.dart';
export 'src/widget/media_loading_style.dart';
export 'src/widget/media_status.dart';
export 'src/widget/media_status_control.dart';
export 'src/widget/media_status_style.dart';
export 'src/widget/viewport_visibility.dart';
