import 'package:flutter/foundation.dart';

/// No files on the web: the head of a file is never known there.
Future<Uint8List?> readFileHead(String path, int length) =>
    SynchronousFuture(null);
