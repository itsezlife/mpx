import 'package:mpx_capture/src/job/capture_job.dart';

/// The diagnostics-safe reason [error] stands for: `unreadable` for a file
/// the platform could not read or write, `permissionDenied`, else `failed`.
String captureFailureCode(CaptureException? error) => switch (error) {
  CaptureFailed() => 'unreadable',
  CapturePermissionDenied() => 'permissionDenied',
  _ => 'failed',
};
