import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Runs an integration test on a device and saves each screenshot it takes
/// as `build/screenshots/<name>.png`.
Future<void> main() => integrationDriver(
  onScreenshot: (name, bytes, [args]) async {
    final file = File('build/screenshots/$name.png');
    await file.create(recursive: true);
    await file.writeAsBytes(bytes);
    return true;
  },
);
