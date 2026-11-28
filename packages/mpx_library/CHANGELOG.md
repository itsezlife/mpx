# Changelog

## Unreleased

- `PlatformMediaSaver` on the web: `gallery` and `downloads` are browser
  downloads; `ask` writes into the file the user picks in the browser's
  save picker where there is one, else downloads (`SaveOp.fallbackToAsk`).
  A saved item is `saved(null)`, a dismissed picker `cancelled`. Items are
  `SaveItem.bytes` or a file in the origin's private file system.
- `MediaSaverHarness.bytes`: the contract saves `SaveItem.bytes` items, for
  a saver over content without files.
- `MediaSaver.save(items, destination)`: a batch of `SaveItem`s (a host
  file, a leased cache file or bytes; photo, video, animation or file) to
  `SaveDestination.gallery(album:)`, `.downloads(subfolder:)` or `.ask()`,
  as one `SaveJob` with an id, one progress, `cancel()` and a `SaveResult`
  per item (`saved(platformRef)`, `cancelled`, `failed(SaveFailure)`). A
  file sent to the gallery goes by its MIME type or fails
  `unsupportedFormat`; a leased file is never moved and its lease is
  released when its item ends. `PlatformMediaSaver` has no platform adapter
  yet: every item fails `unavailable`. Diagnostics events under category
  `save` (`SaveOp`).
- `testing.dart`: `FakeMediaSaver` (recorded batches and writes, scripted
  results, progress steps, cancel, denied access, one change block) and
  `MediaSaverContract`.
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
