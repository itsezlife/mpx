/// The platform backend of `mpx_player`: Media3 ExoPlayer on Android and
/// AVPlayer on iOS and macOS, reading bytes through `http_bytes_cache`'s
/// native reader; and `PlatformStillDecoder`, the platform's first-frame
/// still for video codecs the software decoder cannot read. The sources it
/// reads (`PlayerSource`) are in `mpx_player.dart`, which web code may import.
///
/// Imports `dart:ffi` through the bytes cache's native reader: web code
/// must not import this library.
library;

export 'src/native/native_player_backend.dart'
    show NativePlayerBackend, PlayerSourceWatch, PreparedBuffer;
export 'src/native/platform_still.dart';
export 'src/native/platform_still_decoder.dart';
