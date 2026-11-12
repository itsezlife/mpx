import 'package:mpx_core/mpx_core.dart';

/// The web hook behind [PlatformFrameTextureHost.forPlatform]: the web has no
/// texture host, and its playing assets keep their frame pages.
FrameTextureHost? $createPlatformFrameTextureHost() => null;
