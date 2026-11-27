/// Fakes and contract suites for the seams of `mpx_core`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/asset/testing/asset_playback_contract.dart';
export 'src/asset/testing/fake_asset_paintable.dart';
export 'src/asset/testing/fake_asset_producer.dart';
export 'src/asset/testing/manual_memory_pressure.dart';
export 'src/diagnostics/testing/mpx_diagnostics_contract.dart';
export 'src/diagnostics/testing/recording_diagnostics.dart';
export 'src/pipeline/testing/asset_fetcher_contract.dart';
export 'src/pipeline/testing/decoder_contract.dart';
export 'src/pipeline/testing/fake_auto_download_policy.dart';
export 'src/pipeline/testing/fake_decoder.dart';
export 'src/pipeline/testing/fake_fetcher.dart';
export 'src/pipeline/testing/fake_media_resolver.dart';
export 'src/pipeline/testing/fake_preview_store.dart';
export 'src/pipeline/testing/manual_clock.dart';
export 'src/pipeline/testing/media_resolver_contract.dart';
export 'src/playback/testing/manual_playback_lifecycle_source.dart';
export 'src/playback/testing/manual_playback_tick_source.dart';
export 'src/playback/testing/manual_timers.dart';
export 'src/playback/testing/playback_lifecycle_source_contract.dart';
export 'src/playback/testing/playback_tick_source_contract.dart';
export 'src/pool/testing/fake_frame_renderer.dart';
export 'src/pool/testing/frame_renderer_contract.dart';
export 'src/texture/testing/fake_frame_texture_host.dart';
export 'src/texture/testing/fake_texture_frame_writer.dart';
export 'src/texture/testing/frame_texture_host_contract.dart';
