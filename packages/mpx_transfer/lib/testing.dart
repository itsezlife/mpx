/// Fakes and test support for `mpx_transfer`: an OS envelope with no native
/// part, a scripted runner in place of real transfers, and a harness that
/// builds the engine over both.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/fake_transfer_envelope.dart';
export 'src/testing/scripted_transfer_runner.dart';
export 'src/testing/transfers_harness.dart';
