# Changelog

## Unreleased

- `MediaSaver` saves photos, videos and files to the gallery
  (`gallery(album:)`), Downloads (`downloads(subfolder:)`) or a place the
  user picks (`ask()`), a batch as one `SaveJob` with one progress, a
  cancel and a `SaveResult` per item. `saveContent(requests, destination)`
  saves contents by key, downloading those not local through `mpx_core`'s
  `TrackedTransfers`.
- `SaveAccess`, apart from `LibraryAccess`: `access` reads it,
  `requestAccess` asks ahead, a batch asks once by itself. Apple's add-only
  access compiles under `MPX_LIBRARY_SAVE`.
- `PlatformMediaSaver` saves on Android, iOS, macOS, Windows, Linux and the
  web; the README lists where each destination lands and what a host
  declares.
- Diagnostics under category `save` (`SaveOp`), listed in the README.
- `testing.dart`: `FakeMediaSaver`, `MediaSaverContract` and
  `MediaSaverHarness`.
- `MediaLibrary.missing`: which of some assets the library no longer
  holds, for a host checking its selection after a change.
  `LibraryAsset.byteSize` (Android). A host that implements `MediaLibrary`
  adds `missing`.
- `MediaLibrary.playable`: the URI a player reads a library video from in
  place (Android's content URI, the iOS original's file URL). A host that
  implements `MediaLibrary` adds it.
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
- Native drag and drop and paste through `super_drag_and_drop` and
  `super_clipboard` (`DropSource.wrap` puts the drop region around the
  host's widget); drop events carry the pointer position, which
  `IntakeDropRegion` hands over local to the region (`DropHover`,
  `IntakeDrop`); `DropSourceContract`, `ClipboardReaderContract`.
- The plugin declares no permission; its manifest holds only the system
  camera's file provider.

## 0.0.1

- Initial package.
