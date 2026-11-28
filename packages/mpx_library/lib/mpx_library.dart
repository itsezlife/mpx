/// Optional device media library and file intake for mpx.
///
/// `MediaLibrary` is the seam over the device's photo library: access with
/// its transitions, albums, paged assets by offset, change events and the
/// original of an asset as a file lease. `LibraryKeys` gives an asset and
/// each of its thumbnail sizes a `MediaKey`, and `LibraryFetcher` serves
/// those keys to the asset pipeline. `FileIntake` is the seam over the
/// system file dialog and the system camera. `MediaSaver` saves photos,
/// videos and files into the gallery, the user's Downloads or a place the
/// user picks, a batch as one `SaveJob` with progress, cancel and a result
/// per item, asking for its own `SaveAccess` (add-only on Apple);
/// `PlatformMediaSaver` is the platform's. `saveContent` saves contents by
/// key, downloading those not local through `mpx_core`'s
/// `TrackedTransfers`.
///
/// Fakes and contract suites are in `testing.dart`.
library;

export 'src/fetch/library_fetcher.dart';
export 'src/identity/library_keys.dart';
export 'src/intake/drop_intake.dart';
export 'src/intake/file_intake.dart';
export 'src/intake/intake_files.dart';
export 'src/intake/intake_kind.dart';
export 'src/intake/platform_intake.dart';
export 'src/library/library_access.dart';
export 'src/library/library_album.dart';
export 'src/library/library_asset.dart';
export 'src/library/library_change.dart';
export 'src/library/library_page.dart';
export 'src/library/media_library.dart';
export 'src/platform/library_wire.dart';
export 'src/platform/platform_media_library.dart';
export 'src/platform/platform_media_saver.dart';
export 'src/save/media_saver.dart';
export 'src/save/save_access.dart';
export 'src/save/save_destination.dart';
export 'src/save/save_item.dart';
export 'src/save/save_op.dart';
export 'src/save/save_request.dart';
export 'src/save/save_result.dart';
