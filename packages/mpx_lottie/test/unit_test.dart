/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'benchmark/lottie_playback_bench_test.dart'
    as lottie_playback_bench_test;
import 'cache/frame_cache_key_test.dart' as frame_cache_key_test;
import 'cache/frame_cache_test.dart' as frame_cache_test;
import 'cache/frame_file_reader_test.dart' as frame_file_reader_test;
import 'decoder/lottie_content_hash_worker_test.dart'
    as lottie_content_hash_worker_test;
import 'in_process_lottie_engine_test.dart' as in_process_lottie_engine_test;
import 'isolate_lottie_engine_test.dart' as isolate_lottie_engine_test;
import 'lottie_decoder_pixel_engine_test.dart'
    as lottie_decoder_pixel_engine_test;
import 'lottie_decoder_test.dart' as lottie_decoder_test;
import 'lottie_engine_texture_test.dart' as lottie_engine_texture_test;
import 'lottie_frame_renderer_test.dart' as lottie_frame_renderer_test;
import 'lottie_frame_size_test.dart' as lottie_frame_size_test;
import 'native/android_ndk_test.dart' as android_ndk_test;
import 'native/artifact_check_test.dart' as artifact_check_test;
import 'native/assemble_manifest_test.dart' as assemble_manifest_test;
import 'native/barrel_native_exports_test.dart' as barrel_native_exports_test;
import 'native/build_environment_test.dart' as build_environment_test;
import 'native/cross_compile_test.dart' as cross_compile_test;
import 'native/delivery_plan_test.dart' as delivery_plan_test;
import 'native/fake_lottie_binding_contract_test.dart'
    as fake_lottie_binding_contract_test;
import 'native/fake_lottie_binding_test.dart' as fake_lottie_binding_test;
import 'native/fake_lottie_frame_codec_contract_test.dart'
    as fake_lottie_frame_codec_contract_test;
import 'native/fake_lottie_frame_codec_test.dart'
    as fake_lottie_frame_codec_test;
import 'native/hook_build_test.dart' as hook_build_test;
import 'native/lottie_features_test.dart' as lottie_features_test;
import 'native/lottie_frame_codec_contract_test.dart'
    as lottie_frame_codec_contract_test;
import 'native/lottie_native_target_test.dart' as lottie_native_target_test;
import 'native/lottie_native_version_test.dart' as lottie_native_version_test;
import 'native/manifest_entry_test.dart' as manifest_entry_test;
import 'native/native_binding_contract_test.dart'
    as native_binding_contract_test;
import 'native/native_lottie_binding_test.dart' as native_lottie_binding_test;
import 'native/native_lottie_frame_codec_test.dart'
    as native_lottie_frame_codec_test;
import 'native/native_web_compile_test.dart' as native_web_compile_test;
import 'native/prebuilt_download_test.dart' as prebuilt_download_test;
import 'native/prebuilt_manifest_test.dart' as prebuilt_manifest_test;
import 'native/rebuild_inputs_test.dart' as rebuild_inputs_test;
import 'native/source_hash_test.dart' as source_hash_test;
import 'native/verify_artifact_test.dart' as verify_artifact_test;
import 'native_frame_page_memory_test.dart' as native_frame_page_memory_test;
import 'paint/lottie_paintable_test.dart' as lottie_paintable_test;
import 'playback/lottie_frame_scheduler_test.dart'
    as lottie_frame_scheduler_test;
import 'playback/lottie_frame_scheduler_texture_test.dart'
    as lottie_frame_scheduler_texture_test;
import 'playback/lottie_kept_panel_texture_test.dart'
    as lottie_kept_panel_texture_test;
import 'playback/lottie_lease_turnover_test.dart' as lottie_lease_turnover_test;
import 'renderer/lottie_frame_renderer_texture_test.dart'
    as lottie_frame_renderer_texture_test;
import 'renderer/lottie_source_test.dart' as lottie_source_test;
import 'renderer/pixel_copy_frame_renderer_test.dart'
    as pixel_copy_frame_renderer_test;
import 'testing/fake_pixel_lottie_engine_test.dart'
    as fake_pixel_lottie_engine_test;
import 'web_compile_test.dart' as web_compile_test;
import 'web_worker/lottie_decoder_web_worker_test.dart'
    as lottie_decoder_web_worker_test;
import 'web_worker/lottie_worker_status_test.dart' as lottie_worker_status_test;
import 'web_worker/web_worker_lottie_engine_test.dart'
    as web_worker_lottie_engine_test;

void main() {
  group('lottie_playback_bench_test', lottie_playback_bench_test.main);
  group('frame_cache_key_test', frame_cache_key_test.main);
  group('frame_cache_test', frame_cache_test.main);
  group('frame_file_reader_test', frame_file_reader_test.main);
  group(
    'lottie_content_hash_worker_test',
    lottie_content_hash_worker_test.main,
  );
  group('in_process_lottie_engine_test', in_process_lottie_engine_test.main);
  group('isolate_lottie_engine_test', isolate_lottie_engine_test.main);
  group(
    'lottie_decoder_pixel_engine_test',
    lottie_decoder_pixel_engine_test.main,
  );
  group('lottie_decoder_test', lottie_decoder_test.main);
  group('lottie_engine_texture_test', lottie_engine_texture_test.main);
  group('lottie_frame_renderer_test', lottie_frame_renderer_test.main);
  group('lottie_frame_size_test', lottie_frame_size_test.main);
  group('android_ndk_test', android_ndk_test.main);
  group('artifact_check_test', artifact_check_test.main);
  group('assemble_manifest_test', assemble_manifest_test.main);
  group('barrel_native_exports_test', barrel_native_exports_test.main);
  group('build_environment_test', build_environment_test.main);
  group('cross_compile_test', cross_compile_test.main);
  group('delivery_plan_test', delivery_plan_test.main);
  group(
    'fake_lottie_binding_contract_test',
    fake_lottie_binding_contract_test.main,
  );
  group('fake_lottie_binding_test', fake_lottie_binding_test.main);
  group(
    'fake_lottie_frame_codec_contract_test',
    fake_lottie_frame_codec_contract_test.main,
  );
  group('fake_lottie_frame_codec_test', fake_lottie_frame_codec_test.main);
  group('hook_build_test', hook_build_test.main);
  group('lottie_features_test', lottie_features_test.main);
  group(
    'lottie_frame_codec_contract_test',
    lottie_frame_codec_contract_test.main,
  );
  group('lottie_native_target_test', lottie_native_target_test.main);
  group('lottie_native_version_test', lottie_native_version_test.main);
  group('manifest_entry_test', manifest_entry_test.main);
  group('native_binding_contract_test', native_binding_contract_test.main);
  group('native_lottie_binding_test', native_lottie_binding_test.main);
  group('native_lottie_frame_codec_test', native_lottie_frame_codec_test.main);
  group('native_web_compile_test', native_web_compile_test.main);
  group('prebuilt_download_test', prebuilt_download_test.main);
  group('prebuilt_manifest_test', prebuilt_manifest_test.main);
  group('rebuild_inputs_test', rebuild_inputs_test.main);
  group('source_hash_test', source_hash_test.main);
  group('verify_artifact_test', verify_artifact_test.main);
  group('native_frame_page_memory_test', native_frame_page_memory_test.main);
  group('lottie_paintable_test', lottie_paintable_test.main);
  group('lottie_frame_scheduler_test', lottie_frame_scheduler_test.main);
  group(
    'lottie_frame_scheduler_texture_test',
    lottie_frame_scheduler_texture_test.main,
  );
  group('lottie_kept_panel_texture_test', lottie_kept_panel_texture_test.main);
  group('lottie_lease_turnover_test', lottie_lease_turnover_test.main);
  group(
    'lottie_frame_renderer_texture_test',
    lottie_frame_renderer_texture_test.main,
  );
  group('lottie_source_test', lottie_source_test.main);
  group('pixel_copy_frame_renderer_test', pixel_copy_frame_renderer_test.main);
  group('fake_pixel_lottie_engine_test', fake_pixel_lottie_engine_test.main);
  group('web_compile_test', web_compile_test.main);
  group('lottie_decoder_web_worker_test', lottie_decoder_web_worker_test.main);
  group('lottie_worker_status_test', lottie_worker_status_test.main);
  group('web_worker_lottie_engine_test', web_worker_lottie_engine_test.main);
}
