import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mpx_library/src/platform/save_access_codec.dart';
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
/// A platform writer calls [admit] from `SaveWriter.admit`, before it
/// writes anything.
final class PlatformSaveAccess {
  /// The access over [methods], on [platform] (null: the web).
  const PlatformSaveAccess(this._methods, {required this.platform});

  /// The access of the platform the app runs on.
  factory PlatformSaveAccess.current(MethodChannel methods) =>
      PlatformSaveAccess(
        methods,
        platform: kIsWeb ? null : defaultTargetPlatform,
      );

  final MethodChannel _methods;

  /// The plugin channel the access speaks over, which the platform writer
  /// shares.
  MethodChannel get methods => _methods;

  /// The platform whose rules apply; null on the web.
  final TargetPlatform? platform;

  static const _codec = SaveAccessCodec();

  bool get _native => switch (platform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS => true,
    _ => false,
  };

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
    if (!_native) return SaveAccessAnswer.notNeeded;
    final map = await _methods.invokeMapMethod<Object?, Object?>(method, {
      'destination': destination.name,
      'album': destination is SaveDestination$Gallery && destination.isNamed,
    });
    if (map == null) throw FormatException('no answer to $method');
    return _codec.decode(map);
  }
}
