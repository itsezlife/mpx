/// The platform whose save rules a `PlatformMediaSaver` follows, resolved
/// once (`$savePlatform`) and given to both its access and its writer, so
/// the two never disagree.
///
/// The target platform picks it. A desktop is taken only when the process
/// also runs on that OS, since its writer binds the OS's own folders and
/// dialogs: a test that overrides the target platform on another host gets
/// [other], and writes into no one's folders. Android and iOS speak only
/// the plugin's channel, so a test drives them on any host over a fake
/// channel.
enum SavePlatform {
  /// Android: the native saver and its access over the channel.
  android,

  /// iOS: one native block per batch and Photos access over the channel.
  ios,

  /// macOS: Photos over the channel, files from Dart.
  macos,

  /// Windows: files from Dart, no access.
  windows,

  /// Linux: files from Dart, no access.
  linux,

  /// The web: downloads and the save picker, no access.
  web,

  /// A platform with no save adapter: no access, every item fails
  /// `noAdapter`.
  other;

  /// Whether the access is asked over the plugin's channel; the others need
  /// none.
  bool get asksNatively => switch (this) {
    android || ios || macos => true,
    windows || linux || web || other => false,
  };
}
