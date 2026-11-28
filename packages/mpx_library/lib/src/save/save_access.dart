/// How far the user lets the host save into a destination, as
/// `MediaSaver.access` reads it.
///
/// Separate from `LibraryAccess`, the grid's read access: on Apple saving
/// asks for add-only access, a grant of its own that reads nothing. A named
/// album on Apple asks for read and write access instead. On Android 28 and
/// below it is the legacy storage write permission; Android 29 and later,
/// the desktops and the web ask for nothing and are always [granted].
enum SaveAccess {
  /// Not asked yet; the first save, or `MediaSaver.requestAccess`, shows
  /// the system prompt.
  notDetermined,

  /// The user refused; only the system settings can change it. A batch
  /// fails every item `SaveFailure.accessDenied`.
  denied,

  /// A policy (parental controls, device management), or a host that did
  /// not declare the permission, forbids it; the user cannot grant it. A
  /// batch fails every item `SaveFailure.accessDenied`.
  restricted,

  /// The user gave read and write access to some items only (Apple): saving
  /// works, but a named album can be neither found nor made.
  limited,

  /// Saving may go ahead, or needs no access at all.
  granted,

  /// The build has no code for this destination: an Apple host that did not
  /// compile the save code (or, for a named album, the library's read code).
  /// A batch fails every item `SaveFailure.unavailable`.
  unavailable;

  /// Whether a batch may be written.
  bool get canSave => this == limited || this == granted;
}
