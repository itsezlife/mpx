import 'package:mpx_ui/src/viewer/viewer_actions.dart';

/// A [ViewerFile] that records its release.
final class FakeViewerFile implements ViewerFile {
  /// Creates a file at [path].
  FakeViewerFile(this.path);

  @override
  final String path;

  /// How many times [release] was called.
  int releases = 0;

  /// Whether it was released.
  bool get isReleased => releases > 0;

  @override
  void release() => releases++;
}
