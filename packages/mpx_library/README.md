# mpx_library

Optional device media library and file intake for mpx: access with its transitions, albums, paged assets, change events, the original of an asset as a file, and a fetcher that serves library thumbnails to the asset pipeline.

## Install

Not published yet. Depend on it from git:

```yaml
dependencies:
  mpx_library:
    git:
      url: https://github.com/itsezlife/mpx.git
      path: packages/mpx_library
```

## Usage

```dart
import 'package:mpx_library/mpx_library.dart';

final MediaLibrary library = PlatformMediaLibrary(); // or FakeMediaLibrary

if (library.access.value == LibraryAccess.notDetermined) {
  await library.requestAccess();
}
final albums = await library.albums();           // all-media first
final page = await library.page(albums.first.id, offset: 0, limit: 60);

for (final asset in page.assets) {
  // A grid cell draws the thumbnail key through the asset cache.
  final thumb = LibraryKeys.thumbnailDescriptorOf(asset, 256);
}

library.changes.listen((change) {
  // LibraryChange.album(...) or LibraryChange.reload(): read pages again.
});

// The host's fetcher routes library keys here, ahead of its network one.
final fetcher = LibraryFetcher(library);
```

Saving into the gallery, Downloads or a place the user picks:

```dart
final MediaSaver saver = PlatformMediaSaver(); // or FakeMediaSaver

final job = saver.save([
  SaveItem.file(path, name: 'photo.jpg', mimeType: 'image/jpeg',
      kind: SaveItemKind.photo),
], const SaveDestination.gallery());

job.progress.addListener(() => showProgress(job.progress.value));
final results = await job.results; // one SaveResult per item
```

Saving content by its key, downloaded first when it is not local, through
the composition's `TrackedTransfers`:

```dart
final saver = PlatformMediaSaver(transfers: transfers);

final job = saver.saveContent([
  SaveRequest(key, name: 'clip.mp4', mimeType: 'video/mp4',
      kind: SaveItemKind.video),
], const SaveDestination.gallery());
```

## Features

- `MediaLibrary`: `access` as a `ValueListenable<LibraryAccess>`
  (`notDetermined`, `denied`, `restricted`, `limited`, `partial`, `full`),
  `requestAccess`, `manageSelected` (limited and partial access only),
  `openSettings`, `albums`, `page(album, offset, limit)`, `changes`,
  `thumbnail`, `original` (a `LibraryFileLease`) and `isCloudHeld`.
- `LibraryAsset`: platform id, kind (photo or video), subtypes (live, slow
  motion, time-lapse, favourite, screenshot, animated), dimensions,
  duration, created and modified dates, MIME type.
- `LibraryKeys`: an asset is `MediaKey.external('device-library:<id>')`; a
  thumbnail is a key of its own with its pixel size in it, so the asset
  cache keeps sizes apart. Descriptors for both.
- `LibraryFetcher`, a `ContentFetcher` over the library's thumbnails and
  originals; only a cloud-held original needs a download.
- `FileIntake`: the system file dialog (`pickFiles(filter, multiple)`) and
  the system camera (`captureWithSystemCamera(kind)`), answering
  `IntakeFile`s with a de-duplication key.
- `IntakeDropRegion` over a `DropSource` (enter / over / leave / drop,
  nested enters counted, a 500 ms watchdog, files only, a size ceiling;
  the pointer's position local to the region while hovering and at the
  drop, so a host can split the region into zones),
  `ClipboardReader`, `IntakeFiles.fromPath` / `fromBytes` for a host field
  that already reads pasted media, and `IntakeKind.classify` (photo, video,
  animation, audio, file).
- `MediaSaver`: a batch of photos, videos, animations and files saved as
  one `SaveJob` (progress over the batch, cancel, a result per item). A
  file sent to the gallery goes by its MIME type; a leased cache file is
  copied, never moved, and its lease released when its item ends. The
  saver knows no rights: the caller decides before it calls. It asks for
  its own `SaveAccess` (`access`, `requestAccess`; a batch asks once by
  itself), apart from the library's read access. `PlatformMediaSaver` saves
  on Windows, Linux and the web; a platform whose adapter has not landed answers
  `unavailable` past the access check.
- `MediaSaver.saveContent`: `SaveRequest`s (key, name, MIME type, kind) as
  one `SaveJob` over `mpx_core`'s `TrackedTransfers`: a content not local
  is downloaded as the user's tracked download (or joins one under way),
  leased, saved and released; one progress (download 90 %, copy 10 %, an
  item already local all copy); cancel stops only the downloads the job
  started. Without `TrackedTransfers` every item fails `unavailable`.

## Platforms

| Route | Android | iOS | macOS, other desktops | Web |
| --- | --- | --- | --- | --- |
| `PlatformMediaLibrary` | MediaStore (API 24+), partial access on 14+ | PhotoKit, limited access (opt-in) | none yet | none |
| `PlatformIntake.fileIntake()` | system dialog, camera intent | system dialog, image picker camera (opt-in) | system dialog | hidden file input |
| `PlatformIntake.dropSource()` | drop region | drop region | drop region | DOM drag events |
| `PlatformIntake.clipboardReader()` | system clipboard | system clipboard | system clipboard | async clipboard |

Android: albums are All media, All photos, All videos, the Camera folder,
then the other folders by their newest item; pages are newest first by
modified date (taken date on API 28 and below); MediaStore's change
notifications are collected for 2 s into one `LibraryChange.reload()`.
`manageSelected` asks again, so Android 14 shows its choice of items.
Originals are copied into the app's cache folder for the lease.

iOS: albums are Recents (newest first), Favorites, the non-empty smart
albums, then user albums, newest created first; albums other than Recents
are oldest first and `startsAtEnd`. Changes come out per album from
PhotoKit's change details. Originals download from iCloud with progress.

Saving on Windows and Linux: there is no gallery, so a save is a file in a
folder. `gallery(album:)` is the Pictures folder (photos, GIFs) or the
Videos folder (videos, video animations), with the album as a sub-folder;
`downloads(subfolder:)` is Downloads; `ask` opens the system save dialog
per item, and dismissing it cancels the rest of the batch. The folders are
the Windows known folders (a moved Downloads is found where it is) and the
XDG user directories (`user-dirs.dirs`, the home when a folder is not
set). A taken name gets ` (1)`, ` (2)`, … before its extension. The copy
streams on a worker isolate with progress and cancel; `createdAt` becomes
the file's modification time. Nothing to declare: no access is asked.

On the web a pick that answers nothing within a second of the window
getting its focus back ends empty (browsers say nothing when the dialog is
dismissed), and files are blob handles (`IntakeSource.blob`).

On the web every save is a download: `gallery` and `downloads` hand each
item to the browser (`<a download>`; the browser decides whether to ask
where, and an album or a sub-folder has no meaning there). `ask` opens the
browser's save picker for each item where it has one (Chromium) and writes
the item into the picked file; a dismissed picker is `cancelled`. Without
a picker, or for an item the page has no user gesture left to open one
for, `ask` is a download too. A saved item is `saved(null)`: the browser
confirms nothing. Items are `SaveItem.bytes`, or a file in the origin's
private file system at the item's path. The web needs no access and the
host declares nothing.

Native drag and drop and paste go through `super_drag_and_drop` and
`super_clipboard` 0.9: a dropped or pasted file URI comes back as its file,
pasted image data is written to a file. Their native core pins `win32` 5
(through `device_info_plus` < 12), so a host takes `share_plus` 12, not
13.

## Permissions

The package declares no permission, so a host that only links it pays none.
A host that reads the library declares them itself.

**Android** (`AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.READ_MEDIA_IMAGES" />
<uses-permission android:name="android.permission.READ_MEDIA_VIDEO" />
<uses-permission android:name="android.permission.READ_MEDIA_VISUAL_USER_SELECTED" />
<uses-permission
    android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32" />
```

**iOS**: PhotoKit and the system camera compile only when the host opts in
with the Swift conditions `MPX_LIBRARY_PHOTOS` and `MPX_LIBRARY_CAMERA`;
without them the library reports `restricted` and the camera intake is
unavailable. With CocoaPods, in the app's `Podfile`:

```ruby
post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
    next unless target.name == 'mpx_library'
    target.build_configurations.each do |config|
      config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
        '$(inherited) MPX_LIBRARY_PHOTOS MPX_LIBRARY_CAMERA'
    end
  end
end
```

The host that opts in adds the usage strings to `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Lets you pick photos and videos to share.</string>
<key>NSCameraUsageDescription</key>
<string>Lets you take a photo or a video to share.</string>
```

### Saving

`MediaSaver` asks for its own access, never the library's. What the host
adds, per platform:

| Platform | Access asked | The host adds |
| --- | --- | --- |
| Android 10 (API 29) and later | none | nothing |
| Android 9 (API 28) and below | `WRITE_EXTERNAL_STORAGE`, for the gallery and Downloads | the permission with `android:maxSdkVersion="28"` |
| iOS, macOS: gallery | Photos add-only access | `NSPhotoLibraryAddUsageDescription` and the `MPX_LIBRARY_SAVE` condition |
| iOS, macOS: gallery with an album | Photos read and write access | also `NSPhotoLibraryUsageDescription` and `MPX_LIBRARY_PHOTOS` |
| macOS sandbox | | `com.apple.security.personal-information.photos-library` for the gallery, `com.apple.security.files.downloads.read-write` for Downloads |
| iOS, macOS: Downloads, the save dialog; Windows, Linux, web | none | nothing |

**Android** (`AndroidManifest.xml`):

```xml
<uses-permission
    android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="28" />
```

From API 29 an app adds media and downloads it owns to the MediaStore
without a permission, so the declaration stops at 28. A permission the host
did not declare reads `SaveAccess.restricted`.

**iOS and macOS**: the save code compiles only under the Swift condition
`MPX_LIBRARY_SAVE`, beside `MPX_LIBRARY_PHOTOS` and `MPX_LIBRARY_CAMERA`.
Without it the gallery reads `SaveAccess.unavailable` and a batch to it
fails every item `unavailable` (code `defineMissing`); Downloads and the save
dialog need no Photos code. Add-only access reads nothing, so a host that
only saves links no library reading. A named album needs read and write
access, so it also needs `MPX_LIBRARY_PHOTOS`; without it an album save is
`unavailable` too. In the `Podfile`'s `post_install`, as above:

```ruby
config.build_settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] =
  '$(inherited) MPX_LIBRARY_SAVE'
```

and in `Info.plist`:

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>Saves photos and videos to your library.</string>
```

A sandboxed macOS host adds to its entitlements:

```xml
<key>com.apple.security.personal-information.photos-library</key>
<true/>
<key>com.apple.security.files.downloads.read-write</key>
<true/>
```

## Testing

`package:mpx_library/testing.dart` has `FakeMediaLibrary` (scripted access
transitions, generated assets, added albums, change events, slow cloud-held
originals), `FakeFileIntake` (scripted picks and captures),
`FakeDropSource`, `FakeClipboardReader`, `FakeMediaSaver` (a settable
`SaveAccess`), and the `MediaLibraryContract`, `FileIntakeContract`,
`DropSourceContract`, `ClipboardReaderContract` and `MediaSaverContract`
suites every implementation meets. The web routes have
browser tests: `flutter test --platform chrome test/web`.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [Library, intake, preparation and picking (ADR 0011)](../../docs/adr/0011-library-and-picking.md)
