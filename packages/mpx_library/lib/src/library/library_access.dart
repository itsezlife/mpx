/// How far the user lets the host read the device's media library.
///
/// The adapter re-reads it when the app resumes, since the user may change it
/// in the system settings at any time.
enum LibraryAccess {
  /// Not asked yet; `MediaLibrary.requestAccess` shows the system prompt.
  notDetermined,

  /// The user refused; only the system settings can change it.
  denied,

  /// A policy (parental controls, device management) or a host that did not
  /// opt into the library forbids it; the user cannot grant it.
  restricted,

  /// The user chose some items (iOS); `MediaLibrary.manageSelected` reopens
  /// the system choice.
  limited,

  /// The user chose some items (Android 14 and later, the user-selected
  /// visual media permission); `MediaLibrary.manageSelected` asks again so
  /// the system shows its choice.
  partial,

  /// The whole library.
  full;

  /// Whether albums and pages return anything.
  bool get canRead => switch (this) {
    limited || partial || full => true,
    notDetermined || denied || restricted => false,
  };

  /// Whether `MediaLibrary.manageSelected` does anything.
  bool get canManageSelected => this == limited || this == partial;
}
