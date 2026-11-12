/// Fakes and contract suites for the seams of `http_bytes_cache`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/bytes_store_contract.dart';
export 'src/testing/fake_bytes_ports.dart';
export 'src/testing/ranged_store_contract.dart';
