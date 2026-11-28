import 'package:flutter/foundation.dart';
import 'package:mpx_library/src/platform/no_adapter_save_writer.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The save writer of the native platform the app runs on. Every platform
/// stands in with [NoAdapterSaveWriter] until its adapter lands.
SaveWriter $createSaveWriter() =>
    NoAdapterSaveWriter(defaultTargetPlatform.name);
