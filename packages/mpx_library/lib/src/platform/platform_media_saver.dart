import 'package:flutter/foundation.dart';
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
import 'package:mpx_library/src/save/save_writer.dart';

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
/// Android writes into the MediaStore (pending until complete; public
/// directories on API 28 and below) or the create-document dialog. Windows
/// and Linux write files into the user's folders or where the save dialog
/// says. A platform without a writer yet fails every item
/// `SaveFailure.unavailable` (code `noAdapter`), after the access check.
final class PlatformMediaSaver implements MediaSaver {
  /// The saver of this platform, over the plugin's [methods] channel; a
  /// test passes its own. [transfers] is the composition's tracked
  /// transfers, through which `saveContent` makes content local; without
  /// it every `saveContent` item fails `SaveFailure.unavailable`.
  PlatformMediaSaver({
    MethodChannel methods = PlatformMediaLibrary.methodsChannel,
    TrackedTransfers? transfers,
  }) : this._(PlatformSaveAccess.current(methods), transfers);

  PlatformMediaSaver._(this._access, this._transfers)
    : _writer = environment_specific.$createSaveWriter(access: _access);

  /// The saver over [writer], for a test that runs an adapter with its
  /// system lookups faked; [access] answers over [methods] as above.
  @visibleForTesting
  PlatformMediaSaver.over(
    SaveWriter writer, {
    MethodChannel methods = PlatformMediaLibrary.methodsChannel,
    TrackedTransfers? transfers,
  }) : _access = PlatformSaveAccess.current(methods),
       _transfers = transfers,
       _writer = writer;

  final PlatformSaveAccess _access;

  final TrackedTransfers? _transfers;

  final SaveWriter _writer;

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
