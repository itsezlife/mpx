/// Optional device media library and file intake for mpx.
///
/// `MediaLibrary` is the seam over the device's photo library: access with
/// its transitions, albums, paged assets by offset, change events and the
/// original of an asset as a file lease. `LibraryKeys` gives an asset and
/// each of its thumbnail sizes a `MediaKey`, and `LibraryFetcher` serves
/// those keys to the asset pipeline. `FileIntake` is the seam over the
/// system file dialog and the system camera.
///
/// Fakes and contract suites are in `testing.dart`.
library;

export 'src/fetch/library_fetcher.dart';
export 'src/identity/library_keys.dart';
export 'src/intake/file_intake.dart';
export 'src/library/library_access.dart';
export 'src/library/library_album.dart';
export 'src/library/library_asset.dart';
export 'src/library/library_change.dart';
export 'src/library/library_page.dart';
export 'src/library/media_library.dart';
