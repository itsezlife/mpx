import 'package:flutter_test/flutter_test.dart';
import 'package:mpx_library/src/platform/desktop_save_writer.dart';
import 'package:mpx_library/src/platform/windows_known_folders.dart';

void main() {
  test('a GUID is laid out as Windows keeps it: the first three groups '
      'little-endian, the last two as written', () {
    expect(
      WindowsKnownFolders.guidBytes('374DE290-123F-4565-9164-39C4925E467B'),
      [
        0x90, 0xE2, 0x4D, 0x37, //
        0x3F, 0x12,
        0x65, 0x45,
        0x91, 0x64,
        0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B,
      ],
    );
  });

  test('each folder has its known folder id', () {
    expect(
      WindowsKnownFolders.idOf(DesktopFolder.downloads),
      '374DE290-123F-4565-9164-39C4925E467B',
    );
    expect(
      WindowsKnownFolders.idOf(DesktopFolder.pictures),
      '33E28130-4E1E-4676-835A-98395C3BC3BB',
    );
    expect(
      WindowsKnownFolders.idOf(DesktopFolder.videos),
      '18989B1D-99B5-455B-841C-AB7C74E4DDFC',
    );
  });

  test('a malformed GUID is refused', () {
    expect(
      () => WindowsKnownFolders.guidBytes('374DE290'),
      throwsFormatException,
    );
  });
}
