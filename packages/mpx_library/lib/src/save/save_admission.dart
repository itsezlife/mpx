import 'package:flutter/foundation.dart';
import 'package:mpx_core/mpx_core.dart';
import 'package:mpx_library/src/save/save_access.dart';
import 'package:mpx_library/src/save/save_destination.dart';
import 'package:mpx_library/src/save/save_op.dart';
import 'package:mpx_library/src/save/save_result.dart';

/// Which grant a destination's access is: what the system prompt asks for.
enum SaveAccessScope {
  /// Nothing to ask (Android 29 and later, `ask`, the desktops, the web).
  none,

  /// Apple's add-only access to Photos.
  addOnly,

  /// Apple's read and write access to Photos, for a named album.
  readWrite,

  /// Android's storage write permission, on 28 and below.
  legacyWrite,
}

/// One reading of a destination's access: the state, the grant it is, and
/// for [SaveAccess.unavailable] the build define the host left out.
@immutable
final class SaveAccessAnswer {
  /// An answer.
  const SaveAccessAnswer(this.access, {required this.scope, this.missing});

  /// No access needed: [SaveAccess.granted] with [SaveAccessScope.none].
  static const SaveAccessAnswer notNeeded = SaveAccessAnswer(
    SaveAccess.granted,
    scope: SaveAccessScope.none,
  );

  /// The state.
  final SaveAccess access;

  /// The grant it is.
  final SaveAccessScope scope;

  /// The missing build define's name, when [access] is
  /// [SaveAccess.unavailable].
  final String? missing;

  @override
  bool operator ==(Object other) =>
      other is SaveAccessAnswer &&
      other.access == access &&
      other.scope == scope &&
      other.missing == missing;

  @override
  int get hashCode => Object.hash(access, scope, missing);
}

/// The access gate of a batch, the same for every saver: read the access,
/// ask once when not determined, and turn what is left into the failure of
/// every item, with its events.
///
/// It sits in `SaveWriter.admit`, before anything is written.
abstract final class SaveAdmission {
  /// The failure every item of job [jobId] to [destination] ends with, or
  /// null when the batch may be written. [read] reads the access without
  /// asking; [request] shows the system prompt.
  ///
  /// [SaveAccess.unavailable] is a build without the code
  /// (`SaveFailure.unavailable`, code `defineMissing`); a refusal, or a
  /// prompt the user left without answering, is
  /// `SaveFailure.accessDenied`.
  static Future<SaveResult$Failed?> admit({
    required String jobId,
    required SaveDestination destination,
    required Future<SaveAccessAnswer> Function() read,
    required Future<SaveAccessAnswer> Function() request,
  }) async {
    var answer = await read();
    if (answer.access == SaveAccess.notDetermined) {
      answer = await ask(request, jobId: jobId);
    }
    switch (answer.access) {
      case SaveAccess.granted || SaveAccess.limited:
        return null;
      case SaveAccess.unavailable:
        MpxDiagnostics.current.emit(
          MpxEventLevel.warning,
          SaveOp.defineMissing,
          jobId: jobId,
          fields: () => {
            'destination': destination.name,
            'named': destination.isNamed,
            if (answer.missing case final define?)
              'define': MpxEvent.clip(define),
          },
        );
        return const SaveResult$Failed(
          SaveFailure.unavailable,
          code: 'defineMissing',
        );
      case SaveAccess.notDetermined ||
          SaveAccess.denied ||
          SaveAccess.restricted:
        return const SaveResult$Failed(SaveFailure.accessDenied);
    }
  }

  /// Shows the system prompt through [request] and reports it
  /// (`accessRequested`), under [jobId] when a batch asked.
  static Future<SaveAccessAnswer> ask(
    Future<SaveAccessAnswer> Function() request, {
    String? jobId,
  }) async {
    final answer = await request();
    MpxDiagnostics.current.emit(
      MpxEventLevel.info,
      SaveOp.accessRequested,
      jobId: jobId,
      fields: () => {'access': answer.scope.name, 'result': answer.access.name},
    );
    return answer;
  }
}
