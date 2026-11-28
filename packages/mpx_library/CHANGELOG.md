# Changelog

## Unreleased

- `SaveAccess`, the access saving needs, apart from `LibraryAccess`:
  `MediaSaver.access(destination)` reads it, `requestAccess(destination)`
  asks ahead, and a batch asks once by itself before writing. Apple asks
  for add-only Photos access (read and write for a named album), compiled
  only under the host's `MPX_LIBRARY_SAVE` condition: without it a batch to
  the gallery fails every item `unavailable` (code `defineMissing`). Android
  28 and below asks for `WRITE_EXTERNAL_STORAGE`, which the host declares
  with `maxSdkVersion="28"`; 29 and later, the desktops and the web ask for
  nothing. A host that implements `MediaSaver` adds `access` and
  `requestAccess`. Events `accessRequested` and `defineMissing`.
- `FakeMediaSaver.saveAccess` (a `SaveAccess`, with `grantOnRequest` and
  `accessRequests`) replaces the `accessDenied` flag: a test that set
  `accessDenied = true` sets `saveAccess = SaveAccess.denied`.
- The plugin registers on macOS too, for the save access; the library
  there still answers `restricted`.
- `MediaSaver.saveContent(requests, destination)`: saves contents by
  `MediaKey` (`SaveRequest`: key, name, MIME type, kind, optional date)
  whether they are downloaded or not, through `mpx_core`'s
  `TrackedTransfers` given to the saver (`PlatformMediaSaver(transfers:)`,
  `FakeMediaSaver(transfers:)`). A content not local is downloaded as the
  user's tracked download, or joins another caller's; once complete its
  file is leased, saved and the lease released when the item ends. One
  progress: an item's download is 90 % of its share and its copy 10 %, an
  item already local is all copy. The batch is admitted (its access asked
  for) once, before any download, so a refused one downloads nothing.
  Cancel stops the downloads this job
  started and leaves others' running. A lease missing after a completed
  download downloads once more, then fails `unavailable`; a failed download
  fails `unavailable`; without `TrackedTransfers` every item fails
  `unavailable`. New `SaveOp`s: `downloadStarted`, `downloadShared`,
  `leaseMissing`, `trackedTransfersMissing`, `downloadsCancelled`; item
  events and `leaseReleased` carry the item's `mediaKey`. A host that
  implements `MediaSaver` adds `saveContent`.
- `testing.dart`: `MediaSaverContract` checks `saveContent` when the
  harness passes its `FakeTrackedTransfers` (`transfers`,
  `withoutTransfers`); `FakeMediaSaver.contentBatches`.
- `PlatformMediaSaver` saves on Windows and Linux: `gallery(album:)` into
  the Pictures or Videos folder (by kind, an animation by its MIME type),
  `downloads(subfolder:)` into Downloads, both through the Windows known
  folders or the XDG user directories; `ask` through the system save
  dialog, one per item, a dismissed one cancelling the rest of the batch.
  A taken name gets ` (1)`, ` (2)`, … and the result is `renamed`; names
  and sub-folders are made safe for the file system. The copy streams on
  a worker isolate with progress and cancel, a partial file is removed,
  and `createdAt` becomes the modification time. A file system error maps
  to `accessDenied`, `noSpace` or `unavailable` with its OS code.
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
