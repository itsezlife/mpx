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

final MediaLibrary library = ...; // the platform adapter, or FakeMediaLibrary

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

## Testing

`package:mpx_library/testing.dart` has `FakeMediaLibrary` (scripted access
transitions, generated assets, added albums, change events, slow cloud-held
originals), `FakeFileIntake` (scripted picks and captures), and the
`MediaLibraryContract` and `FileIntakeContract` suites every implementation
meets.

## Docs

- [Spec](../../docs/spec.md)
- [Package topology (ADR 0001)](../../docs/adr/0001-package-topology.md)
- [Library, intake, preparation and picking (ADR 0011)](../../docs/adr/0011-library-and-picking.md)
