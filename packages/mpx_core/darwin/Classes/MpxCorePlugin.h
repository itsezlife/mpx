#import <TargetConditionals.h>

#if TARGET_OS_OSX
#import <FlutterMacOS/FlutterMacOS.h>
#else
#import <Flutter/Flutter.h>
#endif

/// The iOS and macOS texture host: a `FlutterTexture` per texture
/// over a ring of IOSurface-backed `CVPixelBuffer`s, kept by texture id so a
/// render worker locks and posts it through `mpx_frame_texture_lock` and
/// `mpx_frame_texture_post` (the ABI of `native/include/mpx_frame_texture.h`, defined
/// in `MpxCorePlugin.m`).
///
/// The channel has two methods, both on the platform thread: `create`
/// (`{width, height}`) answers the texture id, or null when the platform
/// cannot make one; `destroy` (the id) ends it.
@interface MpxCorePlugin : NSObject <FlutterPlugin>
@end
