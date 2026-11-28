# Changelog

## Unreleased

- `MediaSaver`, the write side of the library: `save(items, destination)`
  saves a batch of `SaveItem`s (a host file, a leased cache file or bytes;
  photo, video, animation or file) to `SaveDestination.gallery(album:)`,
  `.downloads(subfolder:)` or `.ask()` as one `SaveJob` (an id, one
  progress, `cancel()`, a `SaveResult` per item: `saved(platformRef)`,
  `cancelled`, `failed(SaveFailure)`). A `file` sent to the gallery goes by
  its MIME type or fails `unsupportedFormat`; a `move` of a leased file is
  refused and the file copied; its lease is released when its item ends.
  `saveContent(requests, destination)` saves `SaveRequest`s (key, name,
  MIME type, kind, optional date) through `mpx_core`'s `TrackedTransfers`,
  given as `PlatformMediaSaver(transfers:)`: a content not local is
  downloaded as the user's tracked download (or joins one under way), then
  leased, saved and released, under one progress (a download is 90 % of an
  item's share, its copy 10 %; an item already local is all copy). The batch
  is admitted once, before any download. Cancel stops only the downloads
  the job started. A lease missing after a download downloads once more,
  then fails `unavailable`; without `TrackedTransfers` every item fails
  `unavailable`.
- `SaveAccess`, apart from `LibraryAccess`: `MediaSaver.access(destination)`
  reads it, `requestAccess(destination)` asks ahead, and a batch asks once
  by itself. Apple asks for add-only Photos access (read and write for a
  named album), compiled only under the host's `MPX_LIBRARY_SAVE`
  condition; without it the gallery reads `unavailable` and a batch to it
  fails every item `unavailable` (code `defineMissing`). Android 9 and
  below asks for `WRITE_EXTERNAL_STORAGE`, declared with
  `maxSdkVersion="28"`. Android 10 and later, Windows, Linux and the web ask
  for nothing. The plugin registers on macOS for it; the library there
  still answers `restricted`.
- `PlatformMediaSaver` saves on every platform. Android: the MediaStore
  from API 29 (a pending row, published when every byte is in), public
  directories on API 28 and below, the create-document dialog for `ask`.
  iOS: one native call and one atomic result per batch, gallery as one
  Photos change block, Downloads as the app's Documents when the host shows
  them in Files, else the export picker. macOS: the same Photos block;
  `~/Downloads/<subfolder>` and the save panel written from Dart item by
  item. Windows and Linux: the Pictures, Videos and Downloads folders (known
  folders, XDG user directories) and the save dialog. Web: browser downloads
  and the save picker where there is one. A taken name becomes `name (1)` on
  the desktops and iOS Documents and is reported `renamed`; `createdAt` is
  written where the platform keeps one; copies run off the UI thread with
  progress and a cancel inside a copy, and a cancelled or failed copy
  leaves nothing behind. A host adds the declarations the README lists per
  platform.
- Diagnostics under category `save` (`SaveOp`), listed in the README.
- `testing.dart`: `FakeMediaSaver` (recorded batches, scripted results,
  progress steps, cancel, a settable `saveAccess`, `transfers`),
  `MediaSaverContract` and `MediaSaverHarness` (`changeBlock`, `bytes`,
  `transfers`, `withoutTransfers`). A host that implements `MediaSaver`
  adds `access`, `requestAccess` and `saveContent`.
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
