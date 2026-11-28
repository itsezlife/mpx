import 'package:mpx_transfer/src/upload/upload_source_files.dart';

/// None on the web: an upload reads the page's source or the engine's copy
/// in OPFS, which nothing else rewrites, and a reload that kept neither has
/// already failed the job with its source lost.
UploadSourceFiles? $platformUploadSourceFiles() => null;
