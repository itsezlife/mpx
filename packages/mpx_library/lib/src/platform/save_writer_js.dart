import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';
import 'package:mpx_library/src/platform/platform_save_access.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of the web, which needs no access ([access] admits every
/// batch). It stands in with [NoAdapterSaveWriter] until the browser adapter
/// lands.
SaveWriter $createSaveWriter({required PlatformSaveAccess access}) =>
    NoAdapterSaveWriter('web', access: access);
