/// Optional media capture for mpx: compression before send against a shared
/// preset table, media preparation by a per-platform policy, a live camera
/// session with a minimal capture surface, round video recording, and
/// capture output kept in the bytes cache under a local media key.
library;

export 'src/cache/capture_cache.dart';
export 'src/camera/camera_preview.dart';
export 'src/camera/camera_session.dart';
export 'src/camera/camera_slot_preview.dart';
export 'src/camera/capture_surface.dart';
export 'src/camera/platform_camera_sessions.dart';
export 'src/job/capture_job.dart';
export 'src/prepare/media_preparer.dart';
export 'src/prepare/platform_preparation_codec.dart';
export 'src/prepare/preparation_codec.dart';
export 'src/prepare/preparation_policy.dart';
export 'src/prepare/web_preparation_codec_stub.dart'
    if (dart.library.js_interop) 'src/prepare/web_preparation_codec.dart';
export 'src/preset/compression_preset.dart';
export 'src/round/platform_round_video_recorder.dart';
export 'src/round/round_video_preview.dart';
export 'src/round/round_video_recorder.dart';
export 'src/transcode/platform_transcoder.dart';
export 'src/transcode/transcoder.dart';
