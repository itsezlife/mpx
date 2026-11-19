import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mpx_library/src/intake/drop_intake.dart';
import 'package:mpx_library/src/intake/file_intake.dart';
import 'package:mpx_library/src/intake/intake_kind.dart';

/// The native file intake.
Future<FileIntake> $createFileIntake() async {
  final camera = switch (defaultTargetPlatform) {
    TargetPlatform.android => true,
    TargetPlatform.iOS =>
      await _channel
          .invokeMethod<bool>('systemCameraAvailable')
          .catchError((Object _) => false),
    _ => false,
  };
  return NativeFileIntake(canCaptureWithSystemCamera: camera ?? false);
}

/// Native drag and drop needs a plugin the set cannot resolve yet (see the
/// package README); none here.
DropSource? $createDropSource() => null;

/// Native clipboard reading needs the same plugin; none here.
ClipboardReader? $createClipboardReader() => null;

const MethodChannel _channel = MethodChannel('dev.mpx.library/methods');

/// The [FileIntake] of Android, iOS, macOS and the other desktops: the
/// system file dialog through `file_selector`, and the system camera (the
/// camera intent on Android, the image picker's camera on iOS under the
/// host's `MPX_LIBRARY_CAMERA` condition) through the plugin.
final class NativeFileIntake implements FileIntake {
  /// Creates the intake; [canCaptureWithSystemCamera] says whether the
  /// platform has the system camera.
  const NativeFileIntake({required this.canCaptureWithSystemCamera});

  @override
  final bool canCaptureWithSystemCamera;

  @override
  Future<List<IntakeFile>> pickFiles({
    IntakeFilter filter = IntakeFilter.allFiles,
    bool multiple = true,
  }) async {
    final groups = _groups(filter);
    final files = multiple
        ? await openFiles(acceptedTypeGroups: groups)
        : [?await openFile(acceptedTypeGroups: groups)];
    return [for (final file in files) await _intakeOf(file)];
  }

  @override
  Future<IntakeFile?> captureWithSystemCamera(IntakeCaptureKind kind) async {
    if (!canCaptureWithSystemCamera) {
      throw UnsupportedError('no system camera here');
    }
    final Map<Object?, Object?>? map;
    try {
      map = await _channel.invokeMethod<Map<Object?, Object?>>('systemCamera', {
        'kind': kind.name,
      });
    } on PlatformException {
      return null;
    }
    if (map == null) return null;
    final modified = map['modifiedMs'] as int?;
    return IntakeFile(
      source: IntakeSource.path(map['path']! as String),
      name: map['name']! as String,
      size: map['size']! as int,
      mimeType: map['mime'] as String?,
      modified: modified == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(modified),
    );
  }

  static Future<IntakeFile> _intakeOf(XFile file) async => IntakeFile(
    source: IntakeSource.path(file.path),
    name: file.name,
    size: await file.length(),
    mimeType: file.mimeType ?? IntakeKind.mimeOf(file.name),
    modified: await file.lastModified(),
  );

  static const _images = (
    extensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp'],
    mime: 'image/*',
    uti: 'public.image',
  );
  static const _videos = (
    extensions: ['mp4', 'mov', 'm4v', 'webm', 'mkv', '3gp'],
    mime: 'video/*',
    uti: 'public.movie',
  );

  static List<XTypeGroup> _groups(IntakeFilter filter) {
    XTypeGroup group(
      String label,
      List<({List<String> extensions, String mime, String uti})> kinds,
    ) => XTypeGroup(
      label: label,
      extensions: [for (final kind in kinds) ...kind.extensions],
      mimeTypes: [for (final kind in kinds) kind.mime],
      uniformTypeIdentifiers: [for (final kind in kinds) kind.uti],
      webWildCards: [for (final kind in kinds) kind.mime],
    );
    return switch (filter) {
      IntakeFilter.allFiles => const [],
      IntakeFilter.images => [
        group('images', [_images]),
      ],
      IntakeFilter.videos => [
        group('videos', [_videos]),
      ],
      IntakeFilter.imagesAndVideos => [
        group('media', [_images, _videos]),
      ],
    };
  }
}
