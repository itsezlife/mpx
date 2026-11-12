/// Fakes and contract suites for the seams of `mpx_lottie`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/counting_lottie_engine.dart';
export 'src/testing/fake_lottie_binding.dart';
export 'src/testing/fake_lottie_frame_codec.dart';
export 'src/testing/fake_lottie_worker.dart';
export 'src/testing/fake_pixel_lottie_engine.dart';
export 'src/testing/lottie_engine_contract.dart';
export 'src/testing/lottie_frame_codec_contract.dart';
export 'src/testing/native_binding_contract.dart';
