import 'package:flutter/services.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_core/src/texture/platform/ffi_frame_texture_natives.dart';

/// The VM hook behind [PlatformFrameTextureHost.forPlatform]: Android, iOS
/// and macOS answer a [PlatformFrameTextureHost] once the plugin's native side
/// is in the app; every other platform answers null.
FrameTextureHost? $createPlatformFrameTextureHost() {
  const channel = MethodChannel(PlatformFrameTextureHost.channelName);
  if (FfiFrameTextureNatives.openAndroid() case final natives?) {
    return PlatformFrameTextureHost(channel: channel, natives: natives);
  }
  if (FfiFrameTextureNatives.openApple() case final natives?) {
    return PlatformFrameTextureHost(
      channel: channel,
      natives: natives,
      format: FrameTextureFormat.bgra8888,
      buffersPerTexture: PlatformFrameTextureHost.appleBuffersPerTexture,
    );
  }
  return null;
}
