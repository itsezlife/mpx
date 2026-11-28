import 'package:flutter/services.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/platform/platform_media_library.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/src/platform/save_writer_vm.dart'
    if (dart.library.js_interop) 'package:mpx_library/src/platform/save_writer_js.dart'
    as environment_specific;
import 'package:mpx_library/src/save/media_saver.dart';
import 'package:mpx_library/src/save/save_access.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_item.dart';
import 'package:mpx_library/src/save/save_job_runner.dart';
import 'package:mpx_library/src/save/save_request.dart';

/// The [MediaSaver] of the platform the app runs on.
///
/// One Dart saver over a writer per platform, picked when the build picks
/// its file, so `dart:io` never reaches a web build and `package:web` never
/// a native one. The rules every platform shares (one job per batch, routing
/// by MIME type, no move of a leased file, lease release, progress, cancel,
/// diagnostics) run in Dart above the writer.
///
/// Access ([SaveAccess]) is read and asked for over the plugin's method
/// channel on Android and Apple: none on Android 29 and later, the legacy
/// write permission below, add-only Photos access on Apple (read and write
/// for a named album), compiled only under the host's `MPX_LIBRARY_SAVE`
/// condition; without it the gallery is [SaveAccess.unavailable]. The
/// desktops and the web ask for nothing.
///
/// A platform without a writer yet fails every item
/// `SaveFailure.unavailable` (code `noAdapter`), after the access check.
final class PlatformMediaSaver implements MediaSaver {
  /// The saver of this platform, over the plugin's [methods] channel; a
  /// test passes its own. [transfers] is the composition's tracked
  /// transfers, through which `saveContent` makes content local; without
  /// it every `saveContent` item fails `SaveFailure.unavailable`.
  PlatformMediaSaver({
    MethodChannel methods = PlatformMediaLibrary.methodsChannel,
    TrackedTransfers? transfers,
  }) : _access = PlatformSaveAccess.current(methods),
       _transfers = transfers;

  final TrackedTransfers? _transfers;

  final PlatformSaveAccess _access;

  late final _writer = environment_specific.$createSaveWriter(access: _access);

  @override
  SaveJob save(List<SaveItem> items, SaveDestination destination) =>
      SaveJobRunner.run(items, destination, _writer);

  @override
  Future<SaveAccess> access(SaveDestination destination) =>
      _access.access(destination);

  @override
  Future<SaveAccess> requestAccess(SaveDestination destination) =>
      _access.request(destination);

  @override
  SaveJob saveContent(
    List<SaveRequest> requests,
    SaveDestination destination,
  ) => SaveJobRunner.runContent(requests, destination, _writer, _transfers);
}
