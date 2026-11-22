import 'dart:io';

import 'package:flutter/foundation.dart';

/// The first [length] bytes of the file at [path], or null when it cannot be
/// read.
Future<Uint8List?> readFileHead(String path, int length) async {
  try {
    final file = await File(path).open();
    try {
      return await file.read(length);
    } finally {
      await file.close();
    }
  } on FileSystemException {
    return null;
  }
}
