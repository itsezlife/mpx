import 'package:meta/meta.dart';

/// Which files the system file dialog offers.
enum IntakeFilter {
  /// Any file.
  allFiles,

  /// Pictures only.
  images,

  /// Videos only.
  videos,

  /// Pictures and videos.
  imagesAndVideos,
}

/// What the system camera is asked to take.
enum IntakeCaptureKind {
  /// A photo.
  photo,

  /// A video.
  video,
}

/// Where an [IntakeFile]'s bytes are.
@immutable
sealed class IntakeSource {
  const IntakeSource();

  /// A file on this device at [path].
  const factory IntakeSource.path(String path) = IntakeSource$Path;

  /// A handle the platform keeps (a web `File` blob), read through the
  /// intake that produced it.
  const factory IntakeSource.blob(Object handle) = IntakeSource$Blob;
}

/// An [IntakeSource] that is a local file.
final class IntakeSource$Path extends IntakeSource {
  /// Names the file at [path].
  const IntakeSource$Path(this.path);

  /// Absolute path of the file.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is IntakeSource$Path && other.path == path;

  @override
  int get hashCode => Object.hash(IntakeSource$Path, path);

  @override
  String toString() => 'IntakeSource.path($path)';
}

/// An [IntakeSource] that is a platform handle.
final class IntakeSource$Blob extends IntakeSource {
  /// Wraps [handle].
  const IntakeSource$Blob(this.handle);

  /// The platform's handle; opaque to everything but its intake.
  final Object handle;

  @override
  bool operator ==(Object other) =>
      other is IntakeSource$Blob && identical(other.handle, handle);

  @override
  int get hashCode => identityHashCode(handle);

  @override
  String toString() => 'IntakeSource.blob(${handle.runtimeType})';
}

/// The facts that tell two intake files apart when a user adds the same
/// file twice: name, size and modification time.
@immutable
final class IntakeDedupKey {
  /// Creates the key.
  const IntakeDedupKey(this.name, this.size, this.modified);

  /// The file name.
  final String name;

  /// The size in bytes.
  final int size;

  /// The modification time, when known.
  final DateTime? modified;

  @override
  bool operator ==(Object other) =>
      other is IntakeDedupKey &&
      other.name == name &&
      other.size == size &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(name, size, modified);

  @override
  String toString() => 'IntakeDedupKey($name, $size, $modified)';
}

/// A file taken in from outside the library: picked in the system dialog,
/// taken with the system camera, dropped or pasted.
@immutable
final class IntakeFile {
  /// Describes a file.
  const IntakeFile({
    required this.source,
    required this.name,
    required this.size,
    this.mimeType,
    this.modified,
  }) : assert(size >= 0, 'A file size is not negative.');

  /// Where the bytes are.
  final IntakeSource source;

  /// The file name, with its extension.
  final String name;

  /// The size in bytes.
  final int size;

  /// The MIME type, when the platform tells.
  final String? mimeType;

  /// When the file last changed, when the platform tells.
  final DateTime? modified;

  /// The facts that tell this file apart from another one.
  IntakeDedupKey get dedupKey => IntakeDedupKey(name, size, modified);

  @override
  bool operator ==(Object other) =>
      other is IntakeFile &&
      other.source == source &&
      other.name == name &&
      other.size == size &&
      other.mimeType == mimeType &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(source, name, size, mimeType, modified);

  @override
  String toString() => 'IntakeFile($name, $size B, ${mimeType ?? '?'})';
}

/// Takes files in from outside the library: the system file dialog and the
/// system camera.
///
/// The system camera is the fallback when the in-app camera session is
/// unavailable. Implementations: the platform adapters and
/// `FakeFileIntake` in `testing.dart`; all meet `FileIntakeContract`.
///
/// ## Contract
///
/// - [pickFiles] completes with the chosen files, empty when the user
///   dismissed the dialog; at most one without [multiple].
/// - [captureWithSystemCamera] completes with the taken file, or null when
///   the user cancelled. It throws an [UnsupportedError] when
///   [canCaptureWithSystemCamera] is false.
abstract interface class FileIntake {
  /// Whether [captureWithSystemCamera] is available here.
  bool get canCaptureWithSystemCamera;

  /// Shows the system file dialog over [filter].
  Future<List<IntakeFile>> pickFiles({
    IntakeFilter filter = IntakeFilter.allFiles,
    bool multiple = true,
  });

  /// Takes a [kind] with the system camera into a local file.
  Future<IntakeFile?> captureWithSystemCamera(IntakeCaptureKind kind);
}
