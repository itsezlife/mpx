/// Every test file of the package, run as one: one compile and one process
/// instead of one per file. A new `*_test.dart` is imported here and its
/// `main` called inside a group of its own; the files share the process, so a
/// test that changes global state restores it.
library;

import 'package:flutter_test/flutter_test.dart';

import 'cache/capture_cache_test.dart' as capture_cache_test;
import 'camera/camera_preview_test.dart' as camera_preview_test;
import 'camera/camera_slot_preview_test.dart' as camera_slot_preview_test;
import 'camera/capture_surface_test.dart' as capture_surface_test;
import 'camera/fake_camera_ownership_contract_test.dart'
    as fake_camera_ownership_contract_test;
import 'camera/fake_camera_session_contract_test.dart'
    as fake_camera_session_contract_test;
import 'prepare/fake_preparation_codec_contract_test.dart'
    as fake_preparation_codec_contract_test;
import 'prepare/media_preparer_test.dart' as media_preparer_test;
import 'prepare/preparation_policy_test.dart' as preparation_policy_test;
import 'preset/compression_preset_test.dart' as compression_preset_test;
import 'round/fake_round_video_recorder_contract_test.dart'
    as fake_round_video_recorder_contract_test;
import 'round/round_video_preview_test.dart' as round_video_preview_test;
import 'transcode/fake_transcoder_contract_test.dart'
    as fake_transcoder_contract_test;

void main() {
  group('capture_cache_test', capture_cache_test.main);
  group('camera_preview_test', camera_preview_test.main);
  group('camera_slot_preview_test', camera_slot_preview_test.main);
  group('capture_surface_test', capture_surface_test.main);
  group(
    'fake_camera_ownership_contract_test',
    fake_camera_ownership_contract_test.main,
  );
  group(
    'fake_camera_session_contract_test',
    fake_camera_session_contract_test.main,
  );
  group('compression_preset_test', compression_preset_test.main);
  group('preparation_policy_test', preparation_policy_test.main);
  group(
    'fake_preparation_codec_contract_test',
    fake_preparation_codec_contract_test.main,
  );
  group('media_preparer_test', media_preparer_test.main);
  group(
    'fake_round_video_recorder_contract_test',
    fake_round_video_recorder_contract_test.main,
  );
  group('round_video_preview_test', round_video_preview_test.main);
  group('fake_transcoder_contract_test', fake_transcoder_contract_test.main);
}
