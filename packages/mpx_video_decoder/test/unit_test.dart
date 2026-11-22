/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'decoder/video_decoder_native_test.dart' as video_decoder_native_test;
import 'decoder/video_decoder_test.dart' as video_decoder_test;
import 'fake_video_engine_test.dart' as fake_video_engine_test;
import 'in_process_video_engine_native_test.dart'
    as in_process_video_engine_native_test;
import 'in_process_video_engine_test.dart' as in_process_video_engine_test;
import 'isolate_video_engine_native_test.dart'
    as isolate_video_engine_native_test;
import 'isolate_video_engine_test.dart' as isolate_video_engine_test;
import 'native/barrel_native_exports_test.dart' as barrel_native_exports_test;
import 'native/fake_video_binding_contract_test.dart'
    as fake_video_binding_contract_test;
import 'native/hook_build_test.dart' as hook_build_test;
import 'native/mpx_video_status_test.dart' as mpx_video_status_test;
import 'native/native_video_binding_contract_test.dart'
    as native_video_binding_contract_test;
import 'native/native_video_binding_probe_test.dart'
    as native_video_binding_probe_test;
import 'native/native_video_binding_test.dart' as native_video_binding_test;
import 'native/native_video_sources_test.dart' as native_video_sources_test;
import 'native/video_prebuilts_test.dart' as video_prebuilts_test;
import 'paint/video_animation_paintable_test.dart'
    as video_animation_paintable_test;
import 'playback/video_frame_scheduler_test.dart' as video_frame_scheduler_test;
import 'playback/video_frame_scheduler_texture_test.dart'
    as video_frame_scheduler_texture_test;
import 'renderer/video_frame_size_test.dart' as video_frame_size_test;
import 'video_engine_texture_test.dart' as video_engine_texture_test;
import 'web/video_frame_pixels_test.dart' as video_frame_pixels_test;
import 'web/web_compile_test.dart' as web_compile_test;
import 'web/web_video_engine_test.dart' as web_video_engine_test;

void main() {
  group('native/video_prebuilts_test.dart', video_prebuilts_test.main);
  group('video_decoder_native_test', video_decoder_native_test.main);
  group('video_decoder_test', video_decoder_test.main);
  group('fake_video_engine_test', fake_video_engine_test.main);
  group(
    'in_process_video_engine_native_test',
    in_process_video_engine_native_test.main,
  );
  group('in_process_video_engine_test', in_process_video_engine_test.main);
  group(
    'isolate_video_engine_native_test',
    isolate_video_engine_native_test.main,
  );
  group('isolate_video_engine_test', isolate_video_engine_test.main);
  group('barrel_native_exports_test', barrel_native_exports_test.main);
  group(
    'fake_video_binding_contract_test',
    fake_video_binding_contract_test.main,
  );
  group('hook_build_test', hook_build_test.main);
  group('mpx_video_status_test', mpx_video_status_test.main);
  group(
    'native_video_binding_contract_test',
    native_video_binding_contract_test.main,
  );
  group(
    'native_video_binding_probe_test',
    native_video_binding_probe_test.main,
  );
  group('native_video_binding_test', native_video_binding_test.main);
  group('native_video_sources_test', native_video_sources_test.main);
  group('video_animation_paintable_test', video_animation_paintable_test.main);
  group('video_frame_scheduler_test', video_frame_scheduler_test.main);
  group(
    'video_frame_scheduler_texture_test',
    video_frame_scheduler_texture_test.main,
  );
  group('video_frame_size_test', video_frame_size_test.main);
  group('video_engine_texture_test', video_engine_texture_test.main);
  group('video_frame_pixels_test', video_frame_pixels_test.main);
  group('web_compile_test', web_compile_test.main);
  group('web_video_engine_test', web_video_engine_test.main);
}
