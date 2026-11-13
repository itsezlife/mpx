/// Fakes and contract suites for the seams of `mpx_capture`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/fake_transcoder.dart';
export 'src/testing/transcoder_contract.dart';
