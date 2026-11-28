import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of the web. It stands in with [NoAdapterSaveWriter]
/// until the browser adapter lands.
SaveWriter $createSaveWriter() => const NoAdapterSaveWriter('web');
