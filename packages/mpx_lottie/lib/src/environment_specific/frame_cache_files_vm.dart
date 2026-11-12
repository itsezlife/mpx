import 'package:mpx_lottie/src/cache/frame_cache_files.dart';
import 'package:mpx_lottie/src/environment_specific/directory_frame_cache_files_vm.dart';

/// The VM hook behind `FrameCache(directoryPath:)`: the files of the directory
/// at [path].
FrameCacheFiles $openFrameCacheFiles(String path) =>
    DirectoryFrameCacheFiles(path);
