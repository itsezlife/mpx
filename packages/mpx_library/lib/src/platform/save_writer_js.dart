import 'package:flutter/services.dart';
import 'package:mpx_library/src/platform/save_platform.dart';
import 'package:mpx_library/src/platform/web_save_writer.dart';
import 'package:mpx_library/src/save/save_writer.dart';

/// The [SavePlatform] of a web build: always [SavePlatform.web].
SavePlatform $savePlatform() => SavePlatform.web;

/// The save writer of the web ([WebSaveWriter]), which calls no channel.
SaveWriter $createSaveWriter(SavePlatform platform, MethodChannel methods) =>
    WebSaveWriter();
