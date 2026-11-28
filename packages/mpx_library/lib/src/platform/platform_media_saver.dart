import 'package:mpx_library/src/platform/save_writer_vm.dart'
    if (dart.library.js_interop) 'package:mpx_library/src/platform/save_writer_js.dart'
    as environment_specific;
import 'package:mpx_library/src/save/media_saver.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_job_runner.dart';

/// The [MediaSaver] of the platform the app runs on.
///
/// One Dart saver over a writer per platform, picked when the build picks
/// its file, so `dart:io` never reaches a web build and `package:web` never
/// a native one. The rules every platform shares (one job per batch, routing
/// by MIME type, no move of a leased file, lease release, progress, cancel,
/// diagnostics) run in Dart above the writer.
///
/// A platform without a writer yet fails every item
/// `SaveFailure.unavailable` (code `noAdapter`).
final class PlatformMediaSaver implements MediaSaver {
  /// The saver of this platform.
  PlatformMediaSaver();

  final _writer = environment_specific.$createSaveWriter();

  @override
  SaveJob save(List<SaveItem> items, SaveDestination destination) =>
      SaveJobRunner.run(items, destination, _writer);
}
