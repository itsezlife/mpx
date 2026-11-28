import 'package:flutter/services.dart';
import 'package:mpx_library/src/platform/save_access_codec.dart';
import 'package:mpx_library/src/platform/save_platform.dart';
import 'package:mpx_library/src/save/save_access.dart';
import 'package:mpx_library/src/save/save_admission.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_result.dart';

/// The access saving needs on the platform the app runs on, over the
/// plugin's method channel ([SaveAccessCodec] is the wire).
///
/// Android and Apple ask their native side, which knows the grant a
/// destination needs (none on Android 29 and later; the legacy write
/// permission below; add-only access on Apple, read and write for a named
/// album) and whether the build has the code for it. The desktops and the
/// web need nothing and call no native code.
///
/// The saver's job runner calls [admit] once per batch, before anything is
/// written or downloaded.
final class PlatformSaveAccess {
  /// The access over [methods], on [platform].
  const PlatformSaveAccess(this._methods, {required this.platform});

  final MethodChannel _methods;

  /// The platform whose rules apply, the one its writer writes for.
  final SavePlatform platform;

  static const _codec = SaveAccessCodec();

  /// The access of [destination] now, without asking.
  Future<SaveAccess> access(SaveDestination destination) async =>
      (await _read(destination)).access;

  /// Asks for the access of [destination] when it is not determined yet,
  /// and answers what it is after.
  Future<SaveAccess> request(SaveDestination destination) async {
    final now = await _read(destination);
    if (now.access != SaveAccess.notDetermined) return now.access;
    return (await SaveAdmission.ask(() => _request(destination))).access;
  }

  /// The failure every item of job [jobId] ends with, or null when the
  /// batch to [destination] may be written; asks once when not determined
  /// (`SaveAdmission.admit`).
  Future<SaveResult$Failed?> admit(String jobId, SaveDestination destination) =>
      SaveAdmission.admit(
        jobId: jobId,
        destination: destination,
        read: () => _read(destination),
        request: () => _request(destination),
      );

  Future<SaveAccessAnswer> _read(SaveDestination destination) =>
      _call('saveAccess', destination);

  Future<SaveAccessAnswer> _request(SaveDestination destination) =>
      _call('requestSaveAccess', destination);

  Future<SaveAccessAnswer> _call(
    String method,
    SaveDestination destination,
  ) async {
    if (!platform.asksNatively) return SaveAccessAnswer.notNeeded;
    final map = await _methods.invokeMapMethod<Object?, Object?>(method, {
      'destination': destination.name,
      'album': destination is SaveDestination$Gallery && destination.isNamed,
    });
    if (map == null) throw FormatException('no answer to $method');
    return _codec.decode(map);
  }
}
