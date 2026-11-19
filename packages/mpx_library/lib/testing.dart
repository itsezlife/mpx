/// Fakes and contract suites for the seams of `mpx_library`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/fake_drop_intake.dart';
export 'src/testing/fake_file_intake.dart';
export 'src/testing/fake_media_library.dart';
export 'src/testing/file_intake_contract.dart';
export 'src/testing/media_library_contract.dart';
