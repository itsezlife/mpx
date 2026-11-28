import 'dart:ffi';
import 'dart:typed_data';

import 'package:mpx_library/src/platform/desktop_save_writer.dart';

/// The user's folders on Windows: the shell's known folders, looked up with
/// `SHGetKnownFolderPath`, so a folder the user moved (Downloads on another
/// drive) is found where it is.
///
/// Through `dart:ffi` alone: one call into `shell32.dll`, its buffers from
/// `ole32.dll`'s task allocator (`CoTaskMemAlloc` / `CoTaskMemFree`, which
/// the call's result must be freed with anyway). `package:win32` would
/// bring the whole Windows API surface and its version pins (the drag and
/// drop dependency already holds one) for three lines of binding.
final class WindowsKnownFolders implements DesktopFolders {
  /// The known folders.
  const WindowsKnownFolders();

  @override
  Future<String?> pathOf(DesktopFolder folder) async =>
      _Shell.instance.knownFolderPath(guidBytes(idOf(folder)));

  /// The `KNOWNFOLDERID` of [folder] (`FOLDERID_Pictures`,
  /// `FOLDERID_Videos`, `FOLDERID_Downloads`).
  static String idOf(DesktopFolder folder) => switch (folder) {
    DesktopFolder.pictures => '33E28130-4E1E-4676-835A-98395C3BC3BB',
    DesktopFolder.videos => '18989B1D-99B5-455B-841C-AB7C74E4DDFC',
    DesktopFolder.downloads => '374DE290-123F-4565-9164-39C4925E467B',
  };

  /// The 16 bytes of the `GUID` [guid] (`xxxxxxxx-xxxx-xxxx-xxxx-
  /// xxxxxxxxxxxx`) as Windows keeps it in memory: `Data1` (4 bytes),
  /// `Data2` and `Data3` (2 each) little-endian, then `Data4`'s 8 bytes as
  /// written.
  static Uint8List guidBytes(String guid) {
    final groups = guid.split('-');
    if (groups.length != 5 ||
        groups[0].length != 8 ||
        groups[1].length != 4 ||
        groups[2].length != 4 ||
        groups[3].length != 4 ||
        groups[4].length != 12) {
      throw FormatException('not a GUID', guid);
    }
    int hex(String digits) => int.parse(digits, radix: 16);
    final bytes = ByteData(16)
      ..setUint32(0, hex(groups[0]), Endian.little)
      ..setUint16(4, hex(groups[1]), Endian.little)
      ..setUint16(6, hex(groups[2]), Endian.little);
    final tail = groups[3] + groups[4];
    for (var i = 0; i < 8; i++) {
      bytes.setUint8(8 + i, hex(tail.substring(i * 2, i * 2 + 2)));
    }
    return bytes.buffer.asUint8List();
  }
}

typedef _Alloc = Pointer<Uint8> Function(int size);
typedef _Free = void Function(Pointer<Void> block);
typedef _KnownFolderPath =
    int Function(
      Pointer<Uint8> id,
      int flags,
      int token,
      Pointer<Pointer<Uint16>> path,
    );

/// The three Windows functions, bound once on first use.
final class _Shell {
  _Shell._(DynamicLibrary ole32, DynamicLibrary shell32)
    : _alloc = ole32.lookupFunction<Pointer<Uint8> Function(IntPtr), _Alloc>(
        'CoTaskMemAlloc',
      ),
      _free = ole32.lookupFunction<Void Function(Pointer<Void>), _Free>(
        'CoTaskMemFree',
      ),
      _knownFolderPath = shell32
          .lookupFunction<
            Int32 Function(
              Pointer<Uint8>,
              Uint32,
              IntPtr,
              Pointer<Pointer<Uint16>>,
            ),
            _KnownFolderPath
          >('SHGetKnownFolderPath');

  static final _Shell instance = _Shell._(
    DynamicLibrary.open('ole32.dll'),
    DynamicLibrary.open('shell32.dll'),
  );

  final _Alloc _alloc;
  final _Free _free;
  final _KnownFolderPath _knownFolderPath;

  /// `KF_FLAG_DEFAULT`: the folder's path whether or not it exists yet; the
  /// writer makes the directory it writes into.
  static const int _defaultFlags = 0;

  /// The path of the known folder [id] (16 `GUID` bytes), or null when the
  /// shell names none (`SHGetKnownFolderPath` failed).
  String? knownFolderPath(Uint8List id) {
    // One block: the GUID at 0, the out pointer at 16 (8-aligned).
    final block = _alloc(16 + sizeOf<Pointer<Uint16>>());
    if (block == nullptr) return null;
    try {
      block.asTypedList(16).setAll(0, id);
      final out = Pointer<Pointer<Uint16>>.fromAddress(block.address + 16)
        ..value = nullptr;
      final result = _knownFolderPath(block, _defaultFlags, 0, out);
      final path = out.value;
      try {
        if (result != 0 || path == nullptr) return null;
        var length = 0;
        while (path[length] != 0) {
          length++;
        }
        return String.fromCharCodes(path.asTypedList(length));
      } finally {
        // The path is the caller's to free, failed call or not.
        if (path != nullptr) _free(path.cast());
      }
    } finally {
      _free(block.cast());
    }
  }
}
