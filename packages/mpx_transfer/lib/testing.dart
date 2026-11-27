/// Fakes and test support for `mpx_transfer`: an OS envelope with no native
/// part, a scripted runner in place of real transfers, a result kind, a
/// journal store in memory with the contract every journal store meets,
/// and a harness that builds the engine over them.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/journal/journal_store.dart';
export 'src/testing/fake_transfer_envelope.dart';
export 'src/testing/fake_transfer_result.dart';
export 'src/testing/journal_store_contract.dart';
export 'src/testing/scripted_transfer_runner.dart';
export 'src/testing/transfers_harness.dart';
