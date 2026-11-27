/// Fakes and test support for `mpx_transfer`: an OS envelope with no native
/// part, a scripted runner in place of real transfers, a result kind, a
/// journal store in memory with the contract every journal store meets,
/// upload source copies and a page warning as the web has them, with the
/// copies' contract, the contract the reuse table meets over every store,
/// a harness that builds the engine over them, an upload source file
/// system with no files, and an upload transport with no remote end, the
/// contract every transport meets,
/// a harness that runs uploads and publish jobs through the real engine,
/// and a publisher that answers on script.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/journal/journal_store.dart';
export 'src/journal/unload_warning.dart';
export 'src/journal/upload_source_copies.dart';
export 'src/testing/fake_publisher.dart';
export 'src/testing/fake_transfer_envelope.dart';
export 'src/testing/fake_transfer_result.dart';
export 'src/testing/fake_unload_warning.dart';
export 'src/testing/fake_upload_source_copies.dart';
export 'src/testing/fake_upload_source_files.dart';
export 'src/testing/fake_upload_transport.dart';
export 'src/testing/journal_store_contract.dart';
export 'src/testing/reuse_table_contract.dart';
export 'src/testing/scripted_transfer_runner.dart';
export 'src/testing/transfers_harness.dart';
export 'src/testing/upload_source_copies_contract.dart';
export 'src/testing/upload_transport_contract.dart';
export 'src/testing/uploads_harness.dart';
export 'src/upload/upload_source_files.dart' hide platformUploadSourceFiles;
