/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'asset/asset_cache_budget_test.dart' as asset_cache_budget_test;
import 'asset/asset_cache_demand_test.dart' as asset_cache_demand_test;
import 'asset/asset_cache_failure_test.dart' as asset_cache_failure_test;
import 'asset/asset_cache_playback_test.dart' as asset_cache_playback_test;
import 'asset/asset_cache_scope_test.dart' as asset_cache_scope_test;
import 'asset/asset_covering_decode_test.dart' as asset_covering_decode_test;
import 'asset/asset_fit_test.dart' as asset_fit_test;
import 'asset/asset_foreground_playback_test.dart'
    as asset_foreground_playback_test;
import 'asset/asset_playback_test.dart' as asset_playback_test;
import 'asset/asset_profile_test.dart' as asset_profile_test;
import 'asset/asset_sibling_stage_test.dart' as asset_sibling_stage_test;
import 'asset/asset_spec_test.dart' as asset_spec_test;
import 'asset/asset_stand_in_test.dart' as asset_stand_in_test;
import 'asset/asset_transfer_test.dart' as asset_transfer_test;
import 'asset/preview_paintable_test.dart' as preview_paintable_test;
import 'asset/svg_path_parser_test.dart' as svg_path_parser_test;
import 'benchmark/asset_cache_churn_bench_test.dart'
    as asset_cache_churn_bench_test;
import 'benchmark/asset_cache_ratio_bench_test.dart'
    as asset_cache_ratio_bench_test;
import 'diagnostics/mpx_diagnostics_test.dart' as mpx_diagnostics_test;
import 'diagnostics/recording_diagnostics_test.dart'
    as recording_diagnostics_test;
import 'feed/device_inputs_test.dart' as device_inputs_test;
import 'feed/staged_preload_test.dart' as staged_preload_test;
import 'feed/visible_fraction_test.dart' as visible_fraction_test;
import 'identity/media_descriptor_test.dart' as media_descriptor_test;
import 'identity/media_key_test.dart' as media_key_test;
import 'image/frame_counter_return_test.dart' as frame_counter_return_test;
import 'image/image_codec_decoder_test.dart' as image_codec_decoder_test;
import 'image/image_paintable_test.dart' as image_paintable_test;
import 'pipeline/cancellation_token_test.dart' as cancellation_token_test;
import 'pipeline/decoder_registry_test.dart' as decoder_registry_test;
import 'pipeline/fake_adapters_contract_test.dart'
    as fake_adapters_contract_test;
import 'pipeline/fake_media_resolver_contract_test.dart'
    as fake_media_resolver_contract_test;
import 'pipeline/pipeline_derived_preview_test.dart'
    as pipeline_derived_preview_test;
import 'pipeline/pipeline_download_test.dart' as pipeline_download_test;
import 'pipeline/pipeline_fallback_test.dart' as pipeline_fallback_test;
import 'pipeline/pipeline_flow_test.dart' as pipeline_flow_test;
import 'pipeline/pipeline_offline_test.dart' as pipeline_offline_test;
import 'pipeline/pipeline_orchestration_test.dart'
    as pipeline_orchestration_test;
import 'pipeline/pipeline_preview_test.dart' as pipeline_preview_test;
import 'pipeline/pipeline_release_test.dart' as pipeline_release_test;
import 'pipeline/pipeline_resolver_test.dart' as pipeline_resolver_test;
import 'placeholder/mini_thumbnail_test.dart' as mini_thumbnail_test;
import 'placeholder/radial_progress_test.dart' as radial_progress_test;
import 'placeholder/rect_placeholder_test.dart' as rect_placeholder_test;
import 'placeholder/soft_placeholder_test.dart' as soft_placeholder_test;
import 'playback/playback_activity_test.dart' as playback_activity_test;
import 'playback/playback_clock_test.dart' as playback_clock_test;
import 'playback/playback_lifecycle_source_contract_test.dart'
    as playback_lifecycle_source_contract_test;
import 'playback/playback_tick_source_contract_test.dart'
    as playback_tick_source_contract_test;
import 'pool/fake_frame_renderer_contract_test.dart'
    as fake_frame_renderer_contract_test;
import 'pool/frame_atlas_test.dart' as frame_atlas_test;
import 'pool/frame_atlas_visibility_test.dart' as frame_atlas_visibility_test;
import 'pool/frame_page_images_test.dart' as frame_page_images_test;
import 'pool/frame_pool_test.dart' as frame_pool_test;
import 'pool/frame_slot_allocator_test.dart' as frame_slot_allocator_test;
import 'pool/list_frame_page_memory_test.dart' as list_frame_page_memory_test;
import 'pool/pixel_upload_test.dart' as pixel_upload_test;
import 'preparation/fake_media_preparation_test.dart'
    as fake_media_preparation_test;
import 'preparation/preparation_encoding_test.dart'
    as preparation_encoding_test;
import 'preparation/preparation_fixture_test.dart'
    as preparation_fixture_test;
import 'preset/asset_presets_test.dart' as asset_presets_test;
import 'texture/fake_frame_texture_host_contract_test.dart'
    as fake_frame_texture_host_contract_test;
import 'texture/frame_texture_pool_test.dart' as frame_texture_pool_test;
import 'texture/frame_texture_scope_test.dart' as frame_texture_scope_test;
import 'texture/platform/platform_host_contract_test.dart'
    as platform_host_contract_test;
import 'texture/platform/platform_host_test.dart' as platform_host_test;
import 'texture/platform/texture_table_test.dart' as texture_table_test;
import 'texture/texture_frame_region_test.dart' as texture_frame_region_test;
import 'transfer/fake_tracked_transfers_test.dart'
    as fake_tracked_transfers_test;
import 'transfer/tracked_download_test.dart' as tracked_download_test;
import 'widget/asset_cache_provider_test.dart' as asset_cache_provider_test;
import 'widget/asset_view_round_test.dart' as asset_view_round_test;
import 'widget/asset_view_status_test.dart' as asset_view_status_test;
import 'widget/asset_view_test.dart' as asset_view_test;
import 'widget/media_badge_test.dart' as media_badge_test;
import 'widget/media_loading_style_test.dart' as media_loading_style_test;
import 'widget/media_status_control_test.dart' as media_status_control_test;
import 'widget/media_status_painting_test.dart' as media_status_painting_test;
import 'widget/viewport_visibility_test.dart' as viewport_visibility_test;

void main() {
  group('asset_cache_budget_test', asset_cache_budget_test.main);
  group('asset_cache_demand_test', asset_cache_demand_test.main);
  group('asset_cache_failure_test', asset_cache_failure_test.main);
  group('asset_cache_playback_test', asset_cache_playback_test.main);
  group('asset_cache_scope_test', asset_cache_scope_test.main);
  group('asset_covering_decode_test', asset_covering_decode_test.main);
  group('asset_fit_test', asset_fit_test.main);
  group('asset_foreground_playback_test', asset_foreground_playback_test.main);
  group('asset_playback_test', asset_playback_test.main);
  group('asset_profile_test', asset_profile_test.main);
  group('asset_sibling_stage_test', asset_sibling_stage_test.main);
  group('asset_spec_test', asset_spec_test.main);
  group('asset_stand_in_test', asset_stand_in_test.main);
  group('asset_transfer_test', asset_transfer_test.main);
  group('preview_paintable_test', preview_paintable_test.main);
  group('svg_path_parser_test', svg_path_parser_test.main);
  group('asset_cache_churn_bench_test', asset_cache_churn_bench_test.main);
  group('asset_cache_ratio_bench_test', asset_cache_ratio_bench_test.main);
  group('asset_view_round_test', asset_view_round_test.main);
  group('asset_view_status_test', asset_view_status_test.main);
  group('mpx_diagnostics_test', mpx_diagnostics_test.main);
  group('recording_diagnostics_test', recording_diagnostics_test.main);
  group('device_inputs_test', device_inputs_test.main);
  group('media_badge_test', media_badge_test.main);
  group('media_status_control_test', media_status_control_test.main);
  group('media_status_painting_test', media_status_painting_test.main);
  group('staged_preload_test', staged_preload_test.main);
  group('visible_fraction_test', visible_fraction_test.main);
  group('media_descriptor_test', media_descriptor_test.main);
  group('media_key_test', media_key_test.main);
  group('frame_counter_return_test', frame_counter_return_test.main);
  group('image_codec_decoder_test', image_codec_decoder_test.main);
  group('image_paintable_test', image_paintable_test.main);
  group('cancellation_token_test', cancellation_token_test.main);
  group('decoder_registry_test', decoder_registry_test.main);
  group('fake_adapters_contract_test', fake_adapters_contract_test.main);
  group(
    'fake_media_resolver_contract_test',
    fake_media_resolver_contract_test.main,
  );
  group('pipeline_derived_preview_test', pipeline_derived_preview_test.main);
  group('pipeline_download_test', pipeline_download_test.main);
  group('pipeline_fallback_test', pipeline_fallback_test.main);
  group('pipeline_flow_test', pipeline_flow_test.main);
  group('pipeline_offline_test', pipeline_offline_test.main);
  group('pipeline_orchestration_test', pipeline_orchestration_test.main);
  group('pipeline_preview_test', pipeline_preview_test.main);
  group('pipeline_release_test', pipeline_release_test.main);
  group('pipeline_resolver_test', pipeline_resolver_test.main);
  group('mini_thumbnail_test', mini_thumbnail_test.main);
  group('radial_progress_test', radial_progress_test.main);
  group('rect_placeholder_test', rect_placeholder_test.main);
  group('soft_placeholder_test', soft_placeholder_test.main);
  group('playback_activity_test', playback_activity_test.main);
  group('playback_clock_test', playback_clock_test.main);
  group(
    'playback_lifecycle_source_contract_test',
    playback_lifecycle_source_contract_test.main,
  );
  group(
    'playback_tick_source_contract_test',
    playback_tick_source_contract_test.main,
  );
  group(
    'fake_frame_renderer_contract_test',
    fake_frame_renderer_contract_test.main,
  );
  group('frame_atlas_test', frame_atlas_test.main);
  group('frame_atlas_visibility_test', frame_atlas_visibility_test.main);
  group('frame_page_images_test', frame_page_images_test.main);
  group('frame_pool_test', frame_pool_test.main);
  group('frame_slot_allocator_test', frame_slot_allocator_test.main);
  group('list_frame_page_memory_test', list_frame_page_memory_test.main);
  group('pixel_upload_test', pixel_upload_test.main);
  group('asset_presets_test', asset_presets_test.main);
  group(
    'fake_frame_texture_host_contract_test',
    fake_frame_texture_host_contract_test.main,
  );
  group('frame_texture_pool_test', frame_texture_pool_test.main);
  group('frame_texture_scope_test', frame_texture_scope_test.main);
  group('platform_host_contract_test', platform_host_contract_test.main);
  group('platform_host_test', platform_host_test.main);
  group('texture_table_test', texture_table_test.main);
  group('texture_frame_region_test', texture_frame_region_test.main);
  group('asset_cache_provider_test', asset_cache_provider_test.main);
  group('asset_view_test', asset_view_test.main);
  group('media_loading_style_test', media_loading_style_test.main);
  group('viewport_visibility_test', viewport_visibility_test.main);
  group('fake_media_preparation_test', fake_media_preparation_test.main);
  group('preparation_encoding_test', preparation_encoding_test.main);
  group('preparation_fixture_test', preparation_fixture_test.main);
  group('fake_tracked_transfers_test', fake_tracked_transfers_test.main);
  group('tracked_download_test', tracked_download_test.main);
}
