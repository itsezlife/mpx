# Changelog

## Unreleased

- `MediaLibrary`: access with its transitions, albums, pages by offset,
  change events, thumbnails, originals as file leases.
- `LibraryKeys` and `LibraryFetcher`: library assets and their thumbnail
  sizes as `MediaKey`s, served to the asset pipeline.
- `FileIntake` and `IntakeFile`: the system file dialog and the system
  camera.
- `testing.dart`: `FakeMediaLibrary`, `FakeFileIntake`,
  `MediaLibraryContract`, `FileIntakeContract`.
- `PlatformMediaLibrary`: MediaStore on Android (partial access on 14+,
  debounced changes), PhotoKit on iOS under `MPX_LIBRARY_PHOTOS` (limited
  access, change details, iCloud originals with progress).
- `PlatformIntake`: the system file dialog everywhere, the system camera on
  Android and on iOS under `MPX_LIBRARY_CAMERA`, and on the web a file
  input, DOM drag events and the async clipboard.
- `IntakeDropRegion`, `DropTracker`, `ClipboardReader`, `IntakeFiles`,
  `IntakeKind`; `testing.dart`: `FakeDropSource`, `FakeClipboardReader`.
- The plugin declares no permission; its manifest holds only the system
  camera's file provider.

## 0.0.1

- Initial package.
