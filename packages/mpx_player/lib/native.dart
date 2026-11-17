/// The platform backend of `mpx_player`: Media3 ExoPlayer on Android and
/// AVPlayer on iOS and macOS, reading bytes through `http_bytes_cache`'s
/// native reader; and `PlatformStillDecoder`, the platform's first-frame
/// still for video codecs the software decoder cannot read.
///
/// Imports `dart:ffi` through the bytes cache's native reader: web code
/// must not import this library.
library;

export 'src/native/native_player_backend.dart'
    show NativePlayerBackend, PlayerSourceBytes, PreparedBuffer;
export 'src/native/platform_still.dart';
export 'src/native/platform_still_decoder.dart';
export 'src/native/player_source.dart';
