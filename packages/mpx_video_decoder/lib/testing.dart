/// Fakes and contract suites for the seams of `mpx_video_decoder`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/fake_video_binding.dart';
export 'src/testing/fake_video_elements.dart';
export 'src/testing/fake_video_engine.dart';
export 'src/testing/video_binding_contract.dart';
export 'src/testing/video_engine_contract.dart';
