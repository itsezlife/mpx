import 'package:flutter/foundation.dart';

/// Where a `MediaSaver` puts a batch.
@immutable
sealed class SaveDestination {
  const SaveDestination();

  /// The device's gallery: Photos on Apple, the MediaStore images and video
  /// on Android, the Pictures and Videos folders on desktop, a download on
  /// the web.
  ///
  /// [album] is optional. On Android it is the sub-folder of the gallery
  /// collection (`Pictures/<album>`) and needs nothing more. On iOS a named
  /// album needs read and write access to the library, so a host that passes
  /// one asks for it and compiles the library's read code; without an album,
  /// the add-only access is enough.
  const factory SaveDestination.gallery({String? album}) =
      SaveDestination$Gallery;

  /// The user's Downloads, in the host's [subfolder] when given: the
  /// MediaStore downloads on Android, the known folder or XDG directory on
  /// desktop, the app's Documents shown in Files on iOS (when the host
  /// declares file sharing; otherwise as [SaveDestination.ask]), a download
  /// on the web.
  const factory SaveDestination.downloads({String? subfolder}) =
      SaveDestination$Downloads;

  /// A place the user picks in the system save dialog.
  const factory SaveDestination.ask() = SaveDestination$Ask;

  /// The destination's name for diagnostics: `gallery`, `downloads` or
  /// `ask`.
  String get name;

  /// Whether the host named an album or a sub-folder.
  bool get isNamed;
}

/// [SaveDestination.gallery].
final class SaveDestination$Gallery extends SaveDestination {
  /// The gallery, in [album] when given.
  const SaveDestination$Gallery({this.album});

  /// The album (Apple) or sub-folder (Android) to save into.
  final String? album;

  @override
  String get name => 'gallery';

  @override
  bool get isNamed => album != null;

  @override
  bool operator ==(Object other) =>
      other is SaveDestination$Gallery && other.album == album;

  @override
  int get hashCode => Object.hash(SaveDestination$Gallery, album);

  // The album name is the host's text: kept out of strings logs may hold.
  @override
  String toString() => 'SaveDestination.gallery(named: $isNamed)';
}

/// [SaveDestination.downloads].
final class SaveDestination$Downloads extends SaveDestination {
  /// The Downloads, in [subfolder] when given.
  const SaveDestination$Downloads({this.subfolder});

  /// The host's sub-folder of Downloads.
  final String? subfolder;

  @override
  String get name => 'downloads';

  @override
  bool get isNamed => subfolder != null;

  @override
  bool operator ==(Object other) =>
      other is SaveDestination$Downloads && other.subfolder == subfolder;

  @override
  int get hashCode => Object.hash(SaveDestination$Downloads, subfolder);

  @override
  String toString() => 'SaveDestination.downloads(named: $isNamed)';
}

/// [SaveDestination.ask].
final class SaveDestination$Ask extends SaveDestination {
  /// The system save dialog.
  const SaveDestination$Ask();

  @override
  String get name => 'ask';

  @override
  bool get isNamed => false;

  @override
  bool operator ==(Object other) => other is SaveDestination$Ask;

  @override
  int get hashCode => (SaveDestination$Ask).hashCode;

  @override
  String toString() => 'SaveDestination.ask()';
}
