/// Fakes and contract suites for the seams of `mpx_ui`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/fake_gallery_source.dart';
export 'src/testing/fake_origin_bridge.dart';
export 'src/testing/fake_viewer_file.dart';
export 'src/testing/origin_bridge_contract.dart';
