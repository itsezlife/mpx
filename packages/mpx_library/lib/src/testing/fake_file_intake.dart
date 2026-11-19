import 'dart:collection';

import 'package:mpx_library/src/intake/file_intake.dart';

/// A [FileIntake] that answers from scripts, for tests and for hosts without
/// the system dialogs. Meets `FileIntakeContract`.
///
/// Each [pickFiles] takes the next script from [enqueuePick] (an empty list,
/// a dismissed dialog, when none is left) and keeps only the first file
/// without `multiple`; each [captureWithSystemCamera] takes the next from
/// [enqueueCapture] (null, a cancelled camera, when none is left).
final class FakeFileIntake implements FileIntake {
  /// Creates the intake; [canCaptureWithSystemCamera] says whether the
  /// system camera is there.
  FakeFileIntake({this.canCaptureWithSystemCamera = true});

  @override
  final bool canCaptureWithSystemCamera;

  final Queue<List<IntakeFile>> _picks = Queue();
  final Queue<IntakeFile?> _captures = Queue();

  /// Every pick asked for, in order.
  final List<({IntakeFilter filter, bool multiple})> pickRequests = [];

  /// Every capture asked for, in order.
  final List<IntakeCaptureKind> captureRequests = [];

  /// The next [pickFiles] answers [files].
  void enqueuePick(List<IntakeFile> files) => _picks.add(List.of(files));

  /// The next [captureWithSystemCamera] answers [file].
  void enqueueCapture(IntakeFile? file) => _captures.add(file);

  @override
  Future<List<IntakeFile>> pickFiles({
    IntakeFilter filter = IntakeFilter.allFiles,
    bool multiple = true,
  }) async {
    pickRequests.add((filter: filter, multiple: multiple));
    final files = _picks.isEmpty ? const <IntakeFile>[] : _picks.removeFirst();
    return List.unmodifiable(multiple ? files : files.take(1));
  }

  @override
  Future<IntakeFile?> captureWithSystemCamera(IntakeCaptureKind kind) async {
    if (!canCaptureWithSystemCamera) {
      throw UnsupportedError('no system camera');
    }
    captureRequests.add(kind);
    return _captures.isEmpty ? null : _captures.removeFirst();
  }
}
