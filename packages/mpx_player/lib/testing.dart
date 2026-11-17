/// Fakes and contract suites for the seams of `mpx_player`.
///
/// Opt-in: production entry points never export these, and production code
/// never imports them.
library;

export 'src/testing/audio_focus_contract.dart';
export 'src/testing/fake_platform_still_backend.dart';
export 'src/testing/fake_player_backend.dart';
export 'src/testing/picture_in_picture_contract.dart';
export 'src/testing/player_engine_contract.dart';
